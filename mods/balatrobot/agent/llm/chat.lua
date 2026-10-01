--[[
chat completions 协议层的纯逻辑部分, 不依赖游戏, 单测直接加载.

- build_request: 由配置, 历史和工具生成流式请求的 url, 请求头和请求体.
- Accumulator: 逐个 chunk 累积推理, 正文和 tool_calls, 最后组装成可回填历史的 assistant 消息.
- normalize_usage: 各家 usage 字段统一成同一组字段.
- classify / backoff: 错误分类 (重试或放弃) 与退避间隔, 流式条据此显示红字.

请求体用本模块自带的 JSON 编码器生成, 不用 Steamodded 的 json:
- 它把 nil 字段直接丢掉, 表达不了 "content": null. 这里用 M.NULL 表示 null.
- 它把空表编码成 [], 工具 schema 里的 "properties": {} 会变成数组. 这里对 schema 类字段按对象处理,
  也可以用 M.object(t) 显式标记.
- 对象的键按字典序输出, 同样的历史每次编码结果一致, 便于命中服务端的前缀缓存.
]]

local M = {}

M.MAX_RETRIES = 5

-- 第 n 次重试前的等待秒数.
local BACKOFF = { 2, 4, 8, 16, 30 }
-- 服务端给出 Retry-After 时的上限, 防止等太久看起来像卡死.
local RETRY_AFTER_CAP = 60

-------------------------------------------------------------------------------
-- JSON 编码
-------------------------------------------------------------------------------

--- JSON null 的占位值. 解码时 null 会变成 nil, 编码时用它显式写出 null.
M.NULL = setmetatable({}, {
  __tostring = function()
    return "null"
  end,
})

local OBJECT_MT = { __bb_json = "object" }

--- 把表标记为 JSON 对象, 为空时编码为 {} 而不是 [].
---@param t table?
---@return table
function M.object(t)
  return setmetatable(t or {}, OBJECT_MT)
end

-- 这些键下的空表一定是对象 (JSON Schema 与工具定义).
local OBJECT_KEYS = {
  properties = true,
  parameters = true,
  patternProperties = true,
  definitions = true,
  ["$defs"] = true,
}

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape_char(c)
  return ESCAPES[c] or string.format("\\u%04x", c:byte())
end

-- 请求体的兜底: 非 ASCII 字符串原样写进请求体, 一个非法字节就会让服务端拒掉整个请求
-- (400: invalid unicode code point) 并让 agent 停下. 模块由 client.init 注入 (见 agent/text.lua);
-- 单独加载本模块的测试没有它, 那就只做原来的转义.
M.text = nil

local function encode_string(s)
  if M.text then
    s = M.text.sanitize_utf8(s)
  end
  return '"' .. s:gsub('[%z\1-\31"\\]', escape_char) .. '"'
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("json: 不能编码 " .. tostring(n))
  end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
    return string.format("%d", n)
  end
  return string.format("%.14g", n)
end

local encode_value

---@param t table
---@return boolean is_array
local function classify_table(t, key)
  if getmetatable(t) == OBJECT_MT then
    return false
  end
  local n = #t
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
      return false
    end
    count = count + 1
  end
  if count ~= n then
    return false
  end
  if n == 0 and OBJECT_KEYS[key] then
    return false
  end
  return true
end

---@param out string[]
function encode_value(v, out, key, depth)
  local t = type(v)
  if v == nil or v == M.NULL then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    out[#out + 1] = encode_number(v)
  elseif t == "string" then
    out[#out + 1] = encode_string(v)
  elseif t == "table" then
    if depth > 64 then
      error("json: 嵌套过深或存在循环引用")
    end
    if classify_table(v, key) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then
          out[#out + 1] = ","
        end
        encode_value(v[i], out, nil, depth + 1)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then
          error("json: 对象的键只能是字符串")
        end
        keys[#keys + 1] = tostring(k)
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        local item = v[k]
        if item == nil then
          item = v[tonumber(k)]
        end
        if i > 1 then
          out[#out + 1] = ","
        end
        out[#out + 1] = encode_string(k)
        out[#out + 1] = ":"
        encode_value(item, out, k, depth + 1)
      end
      out[#out + 1] = "}"
    end
  else
    error("json: 不能编码类型 " .. t)
  end
end

--- 编码成 JSON 文本. M.NULL 写成 null, 键按字典序.
---@param v any
---@return string
function M.encode(v)
  local out = {}
  encode_value(v, out, nil, 0)
  return table.concat(out)
end

-------------------------------------------------------------------------------
-- 请求
-------------------------------------------------------------------------------

---@class BBLlmConfig
---@field endpoint string 完整的 chat completions 地址, 或 API 根地址 (如 https://api.deepseek.com/v1)
---@field model string
---@field api_key string?
---@field auth ("bearer"|"x-api-key")? 默认 bearer

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 由配置的 endpoint 得到请求地址.
--- 规则: 去掉首尾空白和末尾的 "/"; 路径已以 /chat/completions 结尾时原样使用,
--- 否则视为 API 根地址并补上 /chat/completions (如 .../v1, .../api/v3, 或不带版本的根地址).
--- 查询串 (如 ?api-version=...) 原样保留在末尾.
---@param endpoint string
---@return string? url
---@return string? err
function M.resolve_url(endpoint)
  local url = trim(endpoint)
  if not url:match("^[Hh][Tt][Tt][Pp][Ss]?://[^/]") then
    return nil, "endpoint 必须以 http:// 或 https:// 开头"
  end
  local base, query = url:match("^([^?#]*)(.*)$")
  base = base:gsub("/+$", "")
  if not base:find("/chat/completions$") then
    base = base .. "/chat/completions"
  end
  return base .. query
end

--- 写日志用的地址: 去掉查询串, 部分服务把 key 放在查询串里.
---@param url string
---@return string
function M.log_url(url)
  return (tostring(url or ""):gsub("[?#].*$", ""))
end

---@class BBLlmRequestOpts
---@field stream boolean? 默认 true
---@field tool_choice any? 原样写进请求体
---@field max_tokens integer?
---@field temperature number?
---@field extra table? 额外合并进请求体的字段, 如 reasoning_effort

--- 生成一次 chat completions 请求.
---@param cfg BBLlmConfig
---@param messages table[] 历史消息, assistant 消息可直接用 Accumulator:finish 的结果
---@param tools table[]? OpenAI 格式的工具列表, 为空时不写 tools 字段
---@param opts BBLlmRequestOpts?
---@return string? url 失败时为 nil
---@return table|string headers 请求头表; 失败时为错误描述
---@return string? body
function M.build_request(cfg, messages, tools, opts)
  opts = opts or {}
  if type(cfg) ~= "table" then
    return nil, "缺少配置"
  end
  local url, err = M.resolve_url(cfg.endpoint)
  if not url then
    return nil, err
  end
  local model = trim(cfg.model)
  if model == "" then
    return nil, "缺少模型名"
  end
  if type(messages) ~= "table" or #messages == 0 then
    return nil, "消息列表为空"
  end

  local stream = opts.stream ~= false
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = stream and "text/event-stream" or "application/json",
  }
  local key = trim(cfg.api_key)
  if key ~= "" then
    if cfg.auth == "x-api-key" then
      headers["x-api-key"] = key
    else
      headers["Authorization"] = "Bearer " .. key
    end
  end

  local body = {}
  if type(opts.extra) == "table" then
    for k, v in pairs(opts.extra) do
      body[k] = v
    end
  end
  body.model = model
  body.messages = messages
  body.stream = stream
  if stream then
    body.stream_options = { include_usage = true }
  end
  if type(tools) == "table" and #tools > 0 then
    body.tools = tools
    if opts.tool_choice ~= nil then
      body.tool_choice = opts.tool_choice
    end
  end
  if opts.max_tokens then
    body.max_tokens = opts.max_tokens
  end
  if opts.temperature then
    body.temperature = opts.temperature
  end

  local ok, encoded = pcall(M.encode, body)
  if not ok then
    return nil, "请求体编码失败: " .. tostring(encoded)
  end
  return url, headers, encoded
end

-------------------------------------------------------------------------------
-- 流式累积
-------------------------------------------------------------------------------

--- 一个 delta 里的推理文本, 按 reasoning_content -> reasoning -> reasoning_details[] 的顺序取第一个非空的.
---@param delta table
---@return string?
local function reasoning_of(delta)
  local v = delta.reasoning_content
  if type(v) == "string" and v ~= "" then
    return v
  end
  v = delta.reasoning
  if type(v) == "string" and v ~= "" then
    return v
  end
  local details = delta.reasoning_details
  if type(details) == "table" then
    local parts = {}
    for _, d in ipairs(details) do
      if type(d) == "table" then
        -- 加密的推理 (reasoning.encrypted) 没有可显示的文本, 自然跳过.
        local text = d.text
        if type(text) ~= "string" or text == "" then
          text = d.content
        end
        if type(text) ~= "string" or text == "" then
          text = d.summary
        end
        if type(text) == "string" and text ~= "" then
          parts[#parts + 1] = text
        end
      end
    end
    if #parts > 0 then
      return table.concat(parts)
    end
  end
  return nil
end

---@class BBLlmDelta
---@field kind "reasoning"|"content"
---@field text string

---@class BBLlmAccumulator
---@field error any 流中出现的 error 对象, 有值时本次请求失败
---@field finish_reason string?
---@field done boolean 已收到 finish_reason 或 [DONE]
---@field usage_raw table?
local Accumulator = {}
Accumulator.__index = Accumulator

local id_seq = 0

---@return BBLlmAccumulator
function M.accumulator()
  return setmetatable({
    reasoning_parts = {},
    content_parts = {},
    slots = {}, -- 按首次出现排列的 tool call
    by_index = {},
    error = nil,
    finish_reason = nil,
    done = false,
    usage_raw = nil,
    emitted = false,
  }, Accumulator)
end

--- 找到一个 tool call 增量对应的累积槽位.
--- 一般按 index 对应; 部分兼容实现把所有调用都报成同一个 index, 这时靠新出现的 id 区分.
function Accumulator:slot_for(tc)
  local id = type(tc.id) == "string" and tc.id ~= "" and tc.id or nil
  local index = tonumber(tc.index)
  local slot
  if index then
    slot = self.by_index[index]
    if slot and id and slot.id and slot.id ~= id then
      slot = nil
    end
  elseif id then
    for _, s in ipairs(self.slots) do
      if s.id == id then
        slot = s
        break
      end
    end
  else
    slot = self.slots[#self.slots]
  end
  if not slot then
    slot = { index = index, seq = #self.slots + 1, name = {}, args = {} }
    self.slots[#self.slots + 1] = slot
    if index then
      self.by_index[index] = slot
    end
  end
  if id and not slot.id then
    slot.id = id
  end
  return slot
end

--- 喂入一个已解码的 chunk (data 的 JSON). 返回本 chunk 里要显示的增量, 按出现顺序.
---@param chunk table
---@return BBLlmDelta[]
function Accumulator:feed(chunk)
  local out = {}
  if type(chunk) ~= "table" then
    return out
  end
  if chunk.error ~= nil then
    self.error = chunk.error
    return out
  end
  if type(chunk.usage) == "table" then
    self.usage_raw = chunk.usage
  end
  local choices = chunk.choices
  if type(choices) ~= "table" then
    return out
  end
  for _, choice in ipairs(choices) do
    -- 只取第一个候选 (n=1), 其余候选的增量忽略.
    if type(choice) == "table" and (choice.index == nil or tonumber(choice.index) == 0) then
      local delta = choice.delta
      if type(delta) ~= "table" then
        delta = choice.message -- 非流式响应
      end
      if type(delta) == "table" then
        local reasoning = reasoning_of(delta)
        if reasoning then
          self.reasoning_parts[#self.reasoning_parts + 1] = reasoning
          out[#out + 1] = { kind = "reasoning", text = reasoning }
        end
        local content = delta.content
        if type(content) == "string" and content ~= "" then
          self.content_parts[#self.content_parts + 1] = content
          out[#out + 1] = { kind = "content", text = content }
        end
        if type(delta.tool_calls) == "table" then
          for _, tc in ipairs(delta.tool_calls) do
            if type(tc) == "table" then
              local slot = self:slot_for(tc)
              if type(tc.type) == "string" and tc.type ~= "" then
                slot.type = slot.type or tc.type
              end
              local fn = tc["function"]
              if type(fn) == "table" then
                if type(fn.name) == "string" and fn.name ~= "" then
                  slot.name[#slot.name + 1] = fn.name
                end
                if type(fn.arguments) == "string" and fn.arguments ~= "" then
                  slot.args[#slot.args + 1] = fn.arguments
                elseif type(fn.arguments) == "table" then
                  -- 少数实现直接给出对象而不是字符串.
                  slot.args[#slot.args + 1] = M.encode(fn.arguments)
                end
              end
            end
          end
        end
      end
      if type(choice.finish_reason) == "string" and choice.finish_reason ~= "" then
        self.finish_reason = choice.finish_reason
        self.done = true
      end
    end
  end
  if #out > 0 then
    self.emitted = true
  end
  return out
end

--- 标记收到 [DONE].
function Accumulator:mark_done()
  self.done = true
end

--- 是否已经交出过可显示的增量 (中途断开重发时, 调用方据此决定要不要清空流式条).
---@return boolean
function Accumulator:has_output()
  return self.emitted or #self.slots > 0
end

---@return integer
function Accumulator:tool_call_count()
  return #self.slots
end

--- 组装完整的 assistant 消息与规范化后的 usage.
--- reasoning_content 与 tool_calls 放在同一条消息里; 只有工具调用时 content 为 M.NULL (编码成 null).
---@return table message
---@return table? usage
function Accumulator:finish()
  local content = table.concat(self.content_parts)
  local reasoning = table.concat(self.reasoning_parts)
  local slots = {}
  for i, s in ipairs(self.slots) do
    slots[i] = s
  end
  table.sort(slots, function(a, b)
    local ai, bi = a.index or math.huge, b.index or math.huge
    if ai ~= bi then
      return ai < bi
    end
    return a.seq < b.seq
  end)
  local calls = {}
  for _, s in ipairs(slots) do
    local id = s.id
    if not id then
      id_seq = id_seq + 1
      id = string.format("call_bb_%d_%d", os.time(), id_seq)
    end
    local args = table.concat(s.args)
    calls[#calls + 1] = {
      id = id,
      type = s.type or "function",
      ["function"] = { name = table.concat(s.name), arguments = args ~= "" and args or "{}" },
    }
  end

  local message = { role = "assistant" }
  if content ~= "" then
    message.content = content
  elseif #calls > 0 then
    message.content = M.NULL
  else
    message.content = ""
  end
  if reasoning ~= "" then
    message.reasoning_content = reasoning
  end
  if #calls > 0 then
    message.tool_calls = calls
  end
  return message, M.normalize_usage(self.usage_raw)
end

-------------------------------------------------------------------------------
-- usage
-------------------------------------------------------------------------------

---@class BBLlmUsage
---@field prompt_tokens integer
---@field completion_tokens integer
---@field total_tokens integer
---@field cached integer 命中缓存的输入 token
---@field reasoning_tokens integer

local function num(v)
  local n = tonumber(v)
  if n and n == n then
    return n
  end
  return nil
end

local function sub(t, key)
  local v = type(t) == "table" and t[key]
  return type(v) == "table" and v or {}
end

--- 规范化 usage. 缓存命中取 prompt_tokens_details.cached_tokens 与 prompt_cache_hit_tokens (DeepSeek)
--- 中较大的一个; 也认 Anthropic 风格的 input_tokens/output_tokens/cache_read_input_tokens.
---@param raw table?
---@return BBLlmUsage?
function M.normalize_usage(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local prompt = num(raw.prompt_tokens) or num(raw.input_tokens) or 0
  local completion = num(raw.completion_tokens) or num(raw.output_tokens) or 0
  local cached = math.max(
    num(sub(raw, "prompt_tokens_details").cached_tokens) or 0,
    num(raw.prompt_cache_hit_tokens) or 0,
    num(raw.cache_read_input_tokens) or 0
  )
  local reasoning = num(sub(raw, "completion_tokens_details").reasoning_tokens) or num(raw.reasoning_tokens) or 0
  return {
    prompt_tokens = prompt,
    completion_tokens = completion,
    total_tokens = num(raw.total_tokens) or (prompt + completion),
    cached = cached,
    reasoning_tokens = reasoning,
  }
end

--- 两份 usage 相加, 用于统计单局总量. a 为 nil 时返回 b 的副本.
---@param a BBLlmUsage?
---@param b BBLlmUsage?
---@return BBLlmUsage?
function M.add_usage(a, b)
  if not b then
    return a
  end
  local sum = {}
  for _, k in ipairs({ "prompt_tokens", "completion_tokens", "total_tokens", "cached", "reasoning_tokens" }) do
    sum[k] = (a and a[k] or 0) + (b[k] or 0)
  end
  return sum
end

-------------------------------------------------------------------------------
-- 错误分类与退避
-------------------------------------------------------------------------------

-- 错误对象里 code/type/status 的取值 -> 动作与原因.
local FATAL_CODES = {
  insufficient_quota = "额度用尽",
  billing_hard_limit_reached = "额度用尽",
  insufficient_balance = "额度用尽",
  context_length_exceeded = "上下文超长",
  invalid_api_key = "鉴权失败",
  authentication_error = "鉴权失败",
  unauthenticated = "鉴权失败",
  permission_error = "无权限",
  permission_denied = "无权限",
  model_not_found = "模型不存在",
}
local RETRY_CODES = {
  server_is_overloaded = "服务器过载",
  overloaded_error = "服务器过载",
  slow_down = "限流",
  rate_limit_exceeded = "限流",
  rate_limit_error = "限流",
  resource_exhausted = "限流",
  unavailable = "服务不可用",
  server_error = "服务器错误",
  api_error = "服务器错误",
}

--- 从响应体或流中的 error 取出错误码 (小写字符串列表), 描述和数字码.
---@param err any 解码后的响应体 ({error = ...}), error 对象本身, 或原始文本
---@return string[] codes
---@return string? message
---@return number? numeric
local function error_fields(err)
  local codes = {}
  if type(err) == "table" and err.error ~= nil then
    err = err.error
  end
  if type(err) == "string" then
    return codes, err, nil
  end
  if type(err) ~= "table" then
    return codes, nil, nil
  end
  local numeric
  for _, k in ipairs({ "code", "type", "status" }) do
    local v = err[k]
    if type(v) == "string" and v ~= "" then
      codes[#codes + 1] = v:lower()
    elseif type(v) == "number" and not numeric then
      numeric = v
    end
  end
  local message = type(err.message) == "string" and err.message or nil
  return codes, message, numeric
end

-- 没有错误码时按描述文字匹配, 模式都是小写.
local TEXT_RULES = {
  { "context_length_exceeded", "fatal", "上下文超长" },
  { "context length", "fatal", "上下文超长" },
  { "maximum context", "fatal", "上下文超长" },
  { "insufficient_quota", "fatal", "额度用尽" },
  { "insufficient balance", "fatal", "额度用尽" },
  { "server_is_overloaded", "retry", "服务器过载" },
  { "overloaded", "retry", "服务器过载" },
  { "slow_down", "retry", "限流" },
  { "rate limit", "retry", "限流" },
  { "rate_limit", "retry", "限流" },
}

local function truncate(s, n)
  s = tostring(s or "")
  if #s <= n then
    return s
  end
  -- 服务端返回的错误文本也会写进转录 (JSONL), 截断要落在字符边界上, 免得切出半个汉字.
  local head = M.text and M.text.cut(s, n) or s:sub(1, n)
  return head .. "..."
end

local function prefixed(status, phrase)
  if status and status > 0 and (status < 200 or status >= 300) then
    return string.format("%d %s", status, phrase)
  end
  return phrase
end

--- 错误分类.
--- - 可重试: 429, 5xx, 传输错误 (超时, 连接断开), 错误码 server_is_overloaded/slow_down/rate_limit_exceeded 等.
--- - 不可重试: 401/403, 额度用尽, 上下文超长, 其余 4xx.
--- - transport_error 为 "cancelled" 时返回 "cancel": 主动取消, 既不重试也不算错误.
--- 错误码优先于状态码判断, 例如 OpenAI 的额度用尽也是 429.
---@param status integer? HTTP 状态码, 传输错误时可为 nil 或 0
---@param err any 解码后的响应体, error 对象或原始文本
---@param transport_error string? bbnet 的 ERROR 描述
---@return "retry"|"fatal"|"cancel" action
---@return string reason 中文短语, 用于流式条红字
---@return string? detail 服务端给出的描述, 截断到 300 字节
function M.classify(status, err, transport_error)
  if type(transport_error) == "string" and transport_error ~= "" then
    local t = transport_error:lower()
    if t == "cancelled" or t == "canceled" then
      return "cancel", "已取消", nil
    end
    if t:find("^unavailable") then
      return "fatal", "网络库不可用", truncate(transport_error, 300)
    end
    if t:find("timeout") or t:find("timed out") then
      return "retry", "请求超时", truncate(transport_error, 300)
    end
    return "retry", "连接断开", truncate(transport_error, 300)
  end

  status = tonumber(status) or 0
  local codes, message, numeric = error_fields(err)
  local detail = message or (type(err) == "string" and err) or nil
  detail = detail and truncate(detail, 300) or nil

  -- 流里的 error 常常带数字码 (如 OpenRouter 的 {"error": {"code": 502}}), 此时按它判断.
  if numeric and (status == 0 or (status >= 200 and status < 300)) then
    status = numeric
  end

  for _, code in ipairs(codes) do
    if FATAL_CODES[code] then
      return "fatal", prefixed(status, FATAL_CODES[code]), detail
    end
  end
  for _, code in ipairs(codes) do
    if RETRY_CODES[code] then
      return "retry", prefixed(status, RETRY_CODES[code]), detail
    end
  end
  local text = (message or (type(err) == "string" and err) or ""):lower()
  if text ~= "" then
    for _, rule in ipairs(TEXT_RULES) do
      if text:find(rule[1], 1, true) then
        return rule[2], prefixed(status, rule[3]), detail
      end
    end
  end

  if status == 429 then
    return "retry", "429 限流", detail
  elseif status == 408 then
    return "retry", "408 请求超时", detail
  elseif status == 401 then
    return "fatal", "401 鉴权失败", detail
  elseif status == 403 then
    return "fatal", "403 无权限", detail
  elseif status == 402 then
    return "fatal", "402 额度用尽", detail
  elseif status == 404 then
    return "fatal", "404 地址或模型不存在", detail
  elseif status == 503 or status == 529 then
    return "retry", prefixed(status, "服务器过载"), detail
  elseif status >= 500 and status < 600 then
    return "retry", prefixed(status, "服务器错误"), detail
  elseif status >= 400 and status < 500 then
    return "fatal", prefixed(status, "请求错误"), detail
  end
  if err ~= nil then
    -- 200 响应的流里出现了无法识别的 error, 多半是上游临时故障.
    return "retry", "服务端返回错误", detail
  end
  return "fatal", prefixed(status, "未知错误"), detail
end

--- 第 attempt 次重试 (从 1 开始) 前的等待秒数: 2, 4, 8, 16, 30.
--- 给出 retry_after (服务端的 Retry-After 秒数) 时取两者较大者, 上限 60 秒.
---@param attempt integer
---@param retry_after number?
---@return number
function M.backoff(attempt, retry_after)
  local base = BACKOFF[attempt] or BACKOFF[#BACKOFF]
  if type(retry_after) == "number" and retry_after > base then
    return math.min(retry_after, RETRY_AFTER_CAP)
  end
  return base
end

--- 从原始响应头文本里取 Retry-After 秒数. 只认数字形式.
---@param headers string?
---@return number?
function M.retry_after(headers)
  if type(headers) ~= "string" then
    return nil
  end
  for line in (headers .. "\n"):gmatch("([^\n]*)\n") do
    local name, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
    if name and name:lower() == "retry-after" then
      return tonumber(value)
    end
  end
  return nil
end

--- 从原始响应头文本里取 Content-Type (小写).
---@param headers string?
---@return string?
function M.content_type(headers)
  if type(headers) ~= "string" then
    return nil
  end
  for line in (headers .. "\n"):gmatch("([^\n]*)\n") do
    local name, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
    if name and name:lower() == "content-type" then
      return value:lower()
    end
  end
  return nil
end

return M
