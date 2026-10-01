--[[
一次流式 chat completions 请求的状态机, 在游戏主线程每帧推进.

用法:
  local Client = assert(SMODS.load_file("agent/llm/client.lua"))()
  Client.init({ mod_path = SMODS.current_mod.path })  -- 加载 bbnet, 失败时退回 SMODS.https
  local req = Client.start(cfg, messages, tools, callbacks)
  -- love.update 里: req:update()

状态 req.state:
  "connecting" 已发出, 还没收到状态行 | "streaming" 收到 2xx, 正在接收 | "waiting" 等待重试
  "done" 完成 | "error" 失败 (不可重试或重试用完) | "cancelled" 已取消

回调 (都可省略):
  on_delta(kind, text)  kind 为 "reasoning" 或 "content"; 工具调用参数不推送
  on_reset()            本次尝试已推送过增量, 但要整个重发 (或最终失败), 流式条应清空已显示的内容
  on_retry(attempt, max, reason, wait_seconds)  进入等待; 等待期间 req:retry_remaining() 给出剩余秒数
  on_done(message, usage)  message 可直接追加进历史, usage 已规范化 (可能为 nil)
  on_error(reason, detail)  reason 为中文短语, detail 为服务端描述 (已去掉 key)
取消 (req:cancel()) 不触发任何回调.

重试: 429, 5xx, 超时, 连接断开 (含流在中途断开, 以及 200 响应里无法识别的 error) 按 2, 4, 8, 16, 30 秒
退避, 最多 5 次, 用墙钟计时. 流中途断开时丢弃半截结果, 整个请求重发.
]]

local M = {}

local MOD_ID = "balatrobot"
local LOGGER = "BB.LLM"

--- 传给 bbnet 的超时. 0 表示用库的默认值 (连接 15 秒, 两次读之间空闲 120 秒);
--- 非 0 时连接与空闲超时都取这个值. 退路 SMODS.https 另有整体时限, 见 bbnet.lua.
M.DEFAULT_TIMEOUT_MS = 0

local Bbnet, Chat, Sse, json
local now

local function default_log(level, msg)
  local f
  if level == "error" then
    f = sendErrorMessage
  elseif level == "warn" then
    f = sendWarnMessage
  else
    f = sendInfoMessage
  end
  if f then
    f(msg, LOGGER)
  end
end

local log = default_log

--- 加载依赖与原生库. 返回 bbnet 是否可用 (不可用时请求走 SMODS.https 退路, 不能流式).
---@param options {mod_path: string?, bbnet: table?, chat: table?, sse: table?, text: table?, json: table?, log: fun(level: string, msg: string)?, now: (fun(): number)?}?
---@return boolean streaming
---@return string? err bbnet 加载失败的原因
function M.init(options)
  options = options or {}
  Bbnet = options.bbnet or assert(SMODS.load_file("agent/net/bbnet.lua", MOD_ID))()
  Chat = options.chat or assert(SMODS.load_file("agent/llm/chat.lua", MOD_ID))()
  Sse = options.sse or assert(SMODS.load_file("agent/llm/sse.lua", MOD_ID))()
  local text = options.text or assert(SMODS.load_file("agent/text.lua", MOD_ID))()
  -- 请求体拼装时用它把非法 UTF-8 字节修掉 (见 agent/text.lua): 一个坏字节会让服务端拒掉整个请求.
  Chat.text = text
  json = options.json or require("json")
  now = options.now or love.timer.getTime
  log = options.log or default_log
  M.Bbnet, M.Chat, M.Sse = Bbnet, Chat, Sse

  Bbnet.set_logger(log)
  Bbnet.set_sse(Sse)
  local mod_path = options.mod_path
  if not mod_path and type(SMODS) == "table" and SMODS.Mods and SMODS.Mods[MOD_ID] then
    mod_path = SMODS.Mods[MOD_ID].path
  end
  local ok, err = Bbnet.load(mod_path)
  if not ok then
    log("warn", "streaming disabled, backend=" .. Bbnet.backend())
  end
  return ok, err
end

--- 能否流式 (bbnet 已加载). 为 false 时流式条只能显示 "思考中" 加计时.
---@return boolean
function M.streaming()
  return Bbnet ~= nil and Bbnet.available()
end

--- 当前网络后端: "bbnet" | "smods" | "none". "none" 时内置模式不可用.
---@return string
function M.backend()
  return Bbnet and Bbnet.backend() or "none"
end

---@class BBLlmCallbacks
---@field on_delta fun(kind: "reasoning"|"content", text: string)?
---@field on_reset fun()?
---@field on_retry fun(attempt: integer, max: integer, reason: string, wait: number)?
---@field on_done fun(message: table, usage: BBLlmUsage?)?
---@field on_error fun(reason: string, detail: string?)?

---@class BBLlmRequest
---@field state "connecting"|"streaming"|"waiting"|"done"|"error"|"cancelled"
---@field attempt integer 已进行的重试次数
---@field max_retries integer
---@field retry_at number? 等待重试时, 下次发出的墙钟时刻
---@field retry_reason string? 等待重试的原因
---@field started_at number 首次发出的墙钟时刻
---@field first_token_at number? 本次尝试首个增量到达的时刻
---@field status integer? 本次尝试的 HTTP 状态码
---@field message table? 完成后的 assistant 消息
---@field usage BBLlmUsage?
---@field error_reason string?
---@field error_detail string?
local Req = {}
Req.__index = Req

local TERMINAL = { done = true, error = true, cancelled = true }

--- 把文本里出现的 key 换成 ***, 防止服务端回显的 key 进日志或画面.
function Req:redact(s)
  if type(s) ~= "string" then
    return s
  end
  local key = self.secret
  if not key or #key < 4 then
    return s
  end
  local out, pos = {}, 1
  while true do
    local a, b = s:find(key, pos, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(pos, a - 1)
    out[#out + 1] = "***"
    pos = b + 1
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

function Req:emit(name, ...)
  local cb = self.callbacks[name]
  if cb then
    cb(...)
  end
end

function Req:close_handle()
  if self.handle then
    self.handle:close()
    self.handle = nil
  end
end

function Req:send()
  self.acc = Chat.accumulator()
  self.status, self.resp_headers = nil, nil
  self.err_parts, self.body_parts = {}, {}
  self.first_token_at = nil
  self.retry_at, self.retry_reason = nil, nil
  self.attempt_started = now()
  local handle, err = Bbnet.request({
    method = "POST",
    url = self.url,
    headers = self.headers,
    body = self.body,
    timeout_ms = self.timeout_ms,
  })
  self.state = "connecting"
  if not handle then
    -- 不在这里直接回调, 免得 start 里同步触发 on_error; 下一次 update 再报.
    self.pending_error = { "请求参数错误", err }
    return
  end
  self.handle = handle
  log("info", string.format("request start: model=%s url=%s attempt=%d backend=%s bytes=%d",
    self.model, Chat.log_url(self.url), self.attempt + 1, Bbnet.backend(), #self.body))
end

function Req:finish_error(reason, detail)
  self:close_handle()
  self.state = "error"
  self.error_reason = reason
  self.error_detail = self:redact(detail)
  log("error", string.format("request failed: %s%s (%.1fs, %d retries)", reason,
    self.error_detail and (": " .. self.error_detail) or "", now() - self.started_at, self.attempt))
  self:emit("on_error", reason, self.error_detail)
end

--- 本次尝试失败: 可重试且还有次数时进入等待, 否则整个请求失败.
function Req:fail_attempt(action, reason, detail)
  self:close_handle()
  if action == "cancel" then
    self.state = "cancelled"
    return
  end
  if self.acc and self.acc:has_output() then
    self:emit("on_reset")
  end
  if action == "retry" and self.attempt < self.max_retries then
    self.attempt = self.attempt + 1
    local wait = Chat.backoff(self.attempt, Chat.retry_after(self.resp_headers))
    self.state = "waiting"
    self.retry_at = now() + wait
    self.retry_reason = reason
    local shown = self:redact(detail)
    log("warn", string.format("request retry %d/%d in %.0fs: %s%s", self.attempt, self.max_retries, wait, reason,
      shown and (": " .. shown) or ""))
    self:emit("on_retry", self.attempt, self.max_retries, reason, wait)
    return
  end
  self:finish_error(reason, detail)
end

function Req:complete()
  local message, usage = self.acc:finish()
  self:close_handle()
  self.state = "done"
  self.message, self.usage = message, usage
  local u = usage or {}
  log("info", string.format("request done: %.1fs, first token %s, prompt=%d cached=%d completion=%d reasoning=%d, tool_calls=%d, finish=%s, retries=%d",
    now() - self.started_at,
    self.first_token_at and string.format("%.1fs", self.first_token_at - self.attempt_started) or "-",
    u.prompt_tokens or 0, u.cached or 0, u.completion_tokens or 0, u.reasoning_tokens or 0,
    self.acc:tool_call_count(), tostring(self.acc.finish_reason), self.attempt))
  self:emit("on_done", message, usage)
end

local function decode(text)
  local ok, v = pcall(json.decode, text)
  if ok then
    return v
  end
  return nil
end

--- 处理一条 SSE 事件 (2xx 响应).
function Req:handle_event(raw)
  local data = Sse.parse(raw)
  if data == nil or data == "" then
    return -- 注释或 keep-alive
  end
  if Sse.is_done(data) then
    self.acc:mark_done()
    self:complete()
    return
  end
  local chunk = decode(data)
  if type(chunk) ~= "table" then
    self.bad_chunks = (self.bad_chunks or 0) + 1
    if self.bad_chunks == 1 then
      log("warn", "skip malformed stream chunk: " .. self:redact(data:sub(1, 120)))
    end
    return
  end
  local deltas = self.acc:feed(chunk)
  if self.acc.error ~= nil then
    self:fail_attempt(Chat.classify(self.status, self.acc.error))
    return
  end
  for _, d in ipairs(deltas) do
    if not self.first_token_at then
      self.first_token_at = now()
    end
    self:emit("on_delta", d.kind, d.text)
    if TERMINAL[self.state] then
      return -- 回调里取消了请求
    end
  end
end

--- 连接正常结束.
function Req:handle_done()
  local ok = self.status and self.status >= 200 and self.status < 300
  if not ok then
    local text = table.concat(self.err_parts)
    local decoded = decode(text)
    self:fail_attempt(Chat.classify(self.status, decoded ~= nil and decoded or text))
    return
  end
  if #self.body_parts > 0 then
    local text = table.concat(self.body_parts)
    if text:match("^%s*data:") then
      -- Content-Type 不对但内容是 SSE.
      self.body_parts = {}
      local events, rest = Sse.split(text)
      if rest:match("%S") then
        events[#events + 1] = rest
      end
      for _, ev in ipairs(events) do
        self:handle_event(ev)
        if self.state ~= "streaming" then
          return
        end
      end
    else
      -- 非流式响应 (服务端忽略了 stream=true).
      local decoded = decode(text)
      if type(decoded) ~= "table" then
        self:fail_attempt("fatal", "响应格式错误", text:sub(1, 300))
        return
      end
      local deltas = self.acc:feed(decoded)
      if self.acc.error ~= nil then
        self:fail_attempt(Chat.classify(self.status, self.acc.error))
        return
      end
      for _, d in ipairs(deltas) do
        self:emit("on_delta", d.kind, d.text)
        if TERMINAL[self.state] then
          return
        end
      end
      self:complete()
      return
    end
  end
  if self.acc.done then
    self:complete()
  else
    -- 既没有 finish_reason 也没有 [DONE]: 流被截断.
    self:fail_attempt(Chat.classify(nil, nil, "stream ended early"))
  end
end

function Req:handle_item(item)
  local kind = item.kind
  if kind == "status" then
    self.status = item.status
    self.resp_headers = item.text
    if self.status and self.status >= 200 and self.status < 300 then
      self.state = "streaming"
    end
  elseif kind == "event" or kind == "body" then
    local ok = self.status and self.status >= 200 and self.status < 300
    if not ok then
      self.err_parts[#self.err_parts + 1] = item.text or ""
    elseif kind == "event" then
      self:handle_event(item.text or "")
    else
      self.body_parts[#self.body_parts + 1] = item.text or ""
    end
  elseif kind == "done" then
    self:handle_done()
  elseif kind == "error" then
    self:fail_attempt(Chat.classify(self.status, nil, item.text or "error"))
  end
end

--- 每帧调用.
function Req:update()
  if self.pending_error then
    local reason, detail = self.pending_error[1], self.pending_error[2]
    self.pending_error = nil
    self:finish_error(reason, detail)
    return
  end
  if self.state == "waiting" then
    if now() >= self.retry_at then
      self:send()
    end
    return
  end
  if TERMINAL[self.state] or not self.handle then
    return
  end
  local handle = self.handle
  for _, item in ipairs(handle:poll()) do
    self:handle_item(item)
    -- 完成, 失败或进入重试后, 旧句柄已关闭, 剩下的项丢弃.
    if self.handle ~= handle then
      return
    end
  end
end

--- 取消请求, 不触发回调. 已结束时无操作.
function Req:cancel()
  if TERMINAL[self.state] then
    return
  end
  self:close_handle()
  self.pending_error = nil
  self.state = "cancelled"
  log("info", string.format("request cancelled after %.1fs", now() - self.started_at))
end

--- 等待重试时剩余的秒数, 其他状态为 nil.
---@return number?
function Req:retry_remaining()
  if self.state ~= "waiting" or not self.retry_at then
    return nil
  end
  return math.max(0, self.retry_at - now())
end

---@return boolean
function Req:finished()
  return TERMINAL[self.state] == true
end

--- 发起一次流式请求. 配置错误也返回 req, 在第一次 update 时触发 on_error.
---@param cfg BBLlmConfig
---@param messages table[]
---@param tools table[]?
---@param callbacks BBLlmCallbacks?
---@param opts (BBLlmRequestOpts|{timeout_ms: integer?, max_retries: integer?})?
---@return BBLlmRequest
function M.start(cfg, messages, tools, callbacks, opts)
  assert(Chat, "client.init 尚未调用")
  opts = opts or {}
  local self = setmetatable({
    callbacks = callbacks or {},
    attempt = 0,
    max_retries = opts.max_retries or Chat.MAX_RETRIES,
    timeout_ms = opts.timeout_ms or M.DEFAULT_TIMEOUT_MS,
    started_at = now(),
    state = "connecting",
    model = tostring(cfg and cfg.model or "?"),
    secret = cfg and type(cfg.api_key) == "string" and cfg.api_key:match("^%s*(.-)%s*$") or nil,
  }, Req)
  local url, headers, body = Chat.build_request(cfg, messages, tools, opts)
  if not url then
    self.pending_error = { "配置错误", headers }
    return self
  end
  if Bbnet.backend() == "none" then
    self.pending_error = { "网络库不可用", select(3, Bbnet.info()) }
    return self
  end
  self.url, self.headers, self.body = url, headers, body
  self:send()
  return self
end

return M
