--[[
在进程内调用端点, 不经过 HTTP. 内置 agent loop 用它执行动作.

端点通过 BB_DISPATCHER.Server.send_response 交回结果. 这里包一层: 有本地调用在等时, 把结果交给
它的回调; HTTP 服务此时不监听 (内置模式与外部模式互斥), 原函数因没有客户端直接返回.
overlay.lua 可能先把请求挂起, 在弹窗关掉后再用同一个 send_response 交回结果, 这里照样能收到.

一次只允许一个本地调用, 与 HTTP 服务一次只处理一个请求的约束一致.
必须在 BB_OVERLAY.install 与 BB_ACTIVITY.install 之后安装, 让本地调用同样经过弹窗拦截与活动追踪.
]]

local M = {}

local pending = nil -- {method, cb, started}
local next_id = 0

---@param server table BB_SERVER
function M.install(server)
  local send_response = server.send_response
  server.send_response = function(response)
    local call = pending
    local sent = send_response(response)
    if call then
      pending = nil
      local ok, err = pcall(call.cb, response)
      if not ok then
        sendErrorMessage("Local call callback for " .. call.method .. " failed: " .. tostring(err), "BB.AGENT.LOOP")
      end
    end
    return sent
  end
end

---@return boolean
function M.busy()
  return pending ~= nil
end

--- 发起一次本地调用. response 为端点返回的原表: 成功时是结果, 失败时带 message 与 name.
---@param dispatcher table BB_DISPATCHER
---@param method string
---@param params table?
---@param reason string?
---@param cb fun(response: table)
---@return boolean started, string? err
function M.call(dispatcher, method, params, reason, cb)
  if pending then
    return false, "上一个调用还没完成"
  end
  local request_params = {}
  for k, v in pairs(params or {}) do
    request_params[k] = v
  end
  if reason then
    request_params.reason = reason
  end
  next_id = next_id + 1
  pending = { method = method, cb = cb, started = love.timer.getTime() }
  local ok, err = pcall(dispatcher.dispatch, { jsonrpc = "2.0", method = method, params = request_params, id = next_id })
  if not ok then
    pending = nil
    return false, tostring(err)
  end
  return true
end

--- 放弃等待 (停止 loop 时). 端点之后交回的结果会被丢弃.
function M.abandon()
  pending = nil
end

return M
