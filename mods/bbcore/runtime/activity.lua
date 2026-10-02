--[[
agent 请求的活动追踪 (BB_ACTIVITY). 包装 upstream 的 dispatch 与 BB_TRANSPORT.send_response, 不修改 upstream 文件.
请求从哪来 (HTTP, 内置 loop 的本地调用, 回放) 都一样经过这里.

- 任何请求的 params 都可以带 reason 字符串: 作为决策消息显示并写入时间线, 交给端点前去掉.
- 被动方法 (查询状态, 截图) 不算 agent 活动, 录制不会因它们而保留等待时间.

事件 (M.on 订阅):
- call(method, params, reason): 端点真正开始执行时发, 含被动方法 (只读查询). 左侧的工具调用弹窗用它.
  请求到达时可能还在等讲解退去, 所以由 dispatcher 在 execute 里发, 不要在到达时发.
  改动 request 的发出位置会把只读查询也写进录像时间线, 所以单开一个事件.
- request(method, params, reason): 会改状态或消耗资源的请求 (被动方法不发).
- response(method, ok, error_message, response): response 为端点返回的原表
- message(title, text, duration, source): source 为 "reason" (请求附带) 或 "notify"
]]

local M = {
  ---@type {method: string, params: table, started: number}?
  inflight = nil,
  last_response = nil, -- love.timer 时间
}

-- 客户端断开等原因可能导致收不到响应, 超过这个时长的请求不再视为进行中.
local STALE_SECONDS = 120

-- 被动方法: 只读, 不算活动, 弹窗打开时也放行, 也不会清掉弹窗期间挂起的原请求 (见 overlay.lua).
-- 别的 mod 注册的只读方法 (balatrobot 的手册查询) 由它自己登记进来.
M.PASSIVE = {
  ["health"] = true,
  ["gamestate"] = true,
  ["rpc.discover"] = true,
  ["screenshot"] = true,
  -- 当前局的动态值 (本回合认的花色点数, 小丑成长值), 只读
  ["dynamics"] = true,
}

---@type table<string, function[]>
local listeners = {}

---@param event string
---@param fn function
function M.on(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

---@param event string
function M.emit(event, ...)
  for _, fn in ipairs(listeners[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then
      sendWarnMessage("Listener for " .. event .. " failed: " .. tostring(err), "BB.AGENT.ACTIVITY")
    end
  end
end

--- agent 是否有请求正在处理.
---@param now number love.timer 时间
---@return boolean
function M.busy(now)
  local inflight = M.inflight
  return inflight ~= nil and now - inflight.started < STALE_SECONDS
end

---@param dispatcher table BB_DISPATCHER
---@param server table BB_TRANSPORT (端点结果的公共出口, 见 transport.lua)
function M.install(dispatcher, server)
  local dispatch = dispatcher.dispatch
  dispatcher.dispatch = function(request)
    local method = type(request) == "table" and request.method or nil
    if type(method) ~= "string" then
      return dispatch(request)
    end

    local params = type(request.params) == "table" and request.params or {}
    local reason = params.reason
    if params.reason ~= nil then
      params.reason = nil
    end
    if type(reason) ~= "string" or reason == "" then
      reason = nil
    end

    -- 左侧工具调用弹窗不在这里发: 请求可能还要等讲解退去, 由 dispatcher 在真正 execute 时发 call.

    if M.PASSIVE[method] then
      return dispatch(request)
    end

    M.inflight = { method = method, params = params, started = love.timer.getTime() }
    M.emit("request", method, params, reason)
    if reason then
      M.emit("message", method, reason, nil, "reason")
    end
    return dispatch(request)
  end

  local send_response = server.send_response
  server.send_response = function(response)
    local inflight = M.inflight
    local sent = send_response(response)
    if inflight then
      M.inflight = nil
      M.last_response = love.timer.getTime()
      local is_error = type(response) == "table" and response.message ~= nil
      M.emit("response", inflight.method, not is_error, is_error and response.message or nil, response)
    end
    return sent
  end
end

return M
