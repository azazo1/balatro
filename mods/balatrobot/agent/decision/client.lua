-- System One 的异步 JSON 请求. 网络和时钟可注入, 不依赖游戏.
local M = {}
local TERMINAL = { done = true, error = true, cancelled = true }

function M.new(deps)
  local client = {}
  local clock, chat, protocol, net = deps.now, deps.chat, deps.protocol, deps.net
  local Req = {}
  Req.__index = Req

  function Req:emit(name, ...)
    local callback = self.callbacks[name]
    if callback then callback(...) end
  end

  function Req:redact(value)
    if type(value) ~= "string" then return value end
    local key, out, pos = self.secret, {}, 1
    if not key or key == "" then return value end
    while true do
      local a, b = value:find(key, pos, true)
      if not a then break end
      out[#out + 1] = value:sub(pos, a - 1); out[#out + 1] = "***"; pos = b + 1
    end
    out[#out + 1] = value:sub(pos)
    return table.concat(out)
  end

  function Req:log(level, text)
    if deps.log then deps.log(level, self:redact(text)) end
  end

  function Req:close()
    if self.handle then self.handle:close(); self.handle = nil end
  end

  function Req:cancel()
    if TERMINAL[self.state] then return end
    if self.handle then self.handle:cancel() end
    self:close(); self.state = "cancelled"
    self:log("info", "Decision 请求已取消")
  end

  function Req:error(reason, detail)
    self:close(); self.state = "error"
    self.error_reason, self.error_detail = self:redact(reason), self:redact(detail)
    self:log("error", "Decision 请求失败: " .. self.error_reason .. (self.error_detail and (": " .. self.error_detail) or ""))
    self:emit("on_error", self.error_reason, self.error_detail)
  end

  function Req:fail(status, value, transport_error)
    local action, reason, detail = chat.classify(status, value, transport_error)
    self:close()
    if action == "cancel" then self.state = "cancelled"; return end
    if action == "retry" and self.attempt < self.max_retries then
      self.attempt = self.attempt + 1
      local wait = chat.backoff(self.attempt, chat.retry_after(self.response_headers))
      self.retry_at, self.state = clock() + wait, "waiting"
      self:log("warn", string.format("Decision 请求重试 %d/%d, %.0f 秒后: %s", self.attempt, self.max_retries, wait, reason))
      self:emit("on_retry", self.attempt, self.max_retries, self:redact(reason), wait)
    else self:error("Decision " .. reason, detail) end
  end

  function Req:send()
    self.status, self.response_headers = nil, nil
    self.parts, self.bytes, self.state, self.attempt_started = {}, 0, "connecting", clock()
    local handle, err = net.request({ method = "POST", url = self.request.url,
      headers = self.request.headers, body = self.request.body, timeout_ms = 120000 })
    if not handle then self.pending_error = { "Decision 网络请求无法开始", err }; return end
    self.handle = handle
    self:log("info", string.format("Decision 请求开始: model=%s, url=%s, attempt=%d, bytes=%d",
      self.request.model, chat.log_url(self.request.url), self.attempt + 1, #self.request.body))
  end

  function Req:decode(text)
    local ok, value = pcall(deps.json.decode, text)
    if ok then return value end
  end

  function Req:complete()
    local raw = table.concat(self.parts)
    local value = self:decode(raw)
    if not self.status or self.status < 200 or self.status >= 300 then
      self:fail(self.status, value or raw); return
    end
    if type(value) == "table" and value.error ~= nil then self:fail(self.status, value); return end
    local result, usage = protocol.response(value, self.questions)
    if not result then self:error("Decision 响应格式错误", usage); return end
    self:close(); self.state, self.result, self.usage = "done", result, usage
    self:log("info", string.format("Decision 请求完成: %.2f 秒, input=%d, output=%d, retries=%d",
      clock() - self.started_at, usage.prompt_tokens, usage.completion_tokens, self.attempt))
    self:emit("on_done", result, usage)
  end

  function Req:update()
    if TERMINAL[self.state] then return end
    if self.pending_error then
      local err = self.pending_error; self.pending_error = nil; self:error(err[1], err[2]); return
    end
    if self.state == "waiting" then
      if clock() >= self.retry_at then self:send() end
      return
    end
    if clock() - self.attempt_started > 125 then self:fail(nil, nil, "timeout"); return end
    if not self.handle then return end
    local items = self.handle:poll()
    for _, item in ipairs(items) do
      if item.kind == "status" then self.status, self.response_headers = item.status, item.text
      elseif item.kind == "body" then
        self.bytes = self.bytes + #(item.text or "")
        if self.bytes > 2 * 1024 * 1024 then self:error("Decision 响应过大"); return end
        self.parts[#self.parts + 1] = item.text or ""
      elseif item.kind == "event" then self:error("Decision 返回了不支持的流式响应"); return
      elseif item.kind == "error" then self:fail(self.status, self:decode(table.concat(self.parts)), item.text); return
      elseif item.kind == "done" then self:complete(); return end
      if TERMINAL[self.state] then return end
    end
  end

  function client.start(cfg, state, questions, callbacks)
    local request, err = protocol.request(cfg, state, questions)
    local self = setmetatable({ state = "connecting", callbacks = callbacks or {}, request = request,
      questions = questions, secret = cfg and cfg.api_key, attempt = 0, max_retries = 5,
      started_at = clock(), parts = {}, bytes = 0 }, Req)
    if not request then self.pending_error = { "Decision 配置或问题错误", err }
    elseif not net then self.pending_error = { "Decision 网络库不可用" }
    else self:send() end
    return self
  end

  function client.test(cfg, callbacks)
    return client.start(cfg, "这是连接测试, 不执行任何游戏动作.", {
      connection = { type = "choice", instructions = "该输入是什么用途?",
        criteria = { test = "测试 API 连接", game = "执行游戏动作" } },
    }, callbacks)
  end

  return client
end

return M
