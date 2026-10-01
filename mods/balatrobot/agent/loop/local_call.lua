--[[
在进程内调用端点, 不经过 HTTP. 内置 agent loop 用它执行动作.

端点通过 BB_DISPATCHER.Server.send_response (bbcore 的 BB_TRANSPORT) 交回结果. 这里包一层: 有本地调用在等时,
把结果交给它的回调; HTTP 服务此时不监听 (内置模式与外部模式互斥), 它的 writer 因没有客户端直接返回.
overlay.lua 可能先把请求挂起, 在弹窗关掉后再用同一个 send_response 交回结果, 这里照样能收到.

一次只允许一个本地调用, 与 HTTP 服务一次只处理一个请求的约束一致.

过期响应: 端点的回复可能比调用活得久 (overlay 把请求挂到弹窗关闭, 或者在等动画). 中途 stop 或暂停时
调用被 abandon, 之后再开新调用, 旧回复会顺着同一条 send_response 回来, 和新调用的回复分不出来
(响应表里没有能识别调用的字段). 所以给端点的 execute 套一层常驻的闸门: execute 被调用时记下当时
待处理的那次调用 (代号), 回复到达时这次调用已被 abandon 就丢掉并计数. 闸门只套一次且不再拆:
dispatch 期间 overlay 会在它外面再包一层, 拆掉会把 overlay 的包装一起丢掉.

必须在 BB_OVERLAY.install 与 BB_ACTIVITY.install 之后安装, 让本地调用同样经过弹窗拦截与活动追踪.
]]

local M = {}

local pending = nil -- {method, cb, abandoned}
local next_id = 0
local dropped = 0

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

--- 给端点套上闸门, 每个端点只套一次. 不在本地调用中的 execute (HTTP 请求) 原样放行.
---@param endpoint table
local function gate(endpoint)
  if endpoint.__bb_local_call_gated then
    return
  end
  endpoint.__bb_local_call_gated = true
  local execute = endpoint.execute
  endpoint.execute = function(args, send_response)
    local call = pending
    if not call then
      return execute(args, send_response)
    end
    return execute(args, function(response)
      if call.abandoned then
        dropped = dropped + 1
        sendDebugMessage("丢弃过期响应 (已放弃的 " .. call.method .. " 调用)", "BB.AGENT.LOOP")
      else
        send_response(response)
      end
    end)
  end
end

---@return boolean
function M.busy()
  return pending ~= nil
end

--- 被丢弃的过期响应次数, 供测试与排查用.
---@return integer
function M.dropped()
  return dropped
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
  local endpoint = dispatcher.endpoints[method]
  if endpoint then
    gate(endpoint)
  end
  next_id = next_id + 1
  pending = { method = method, cb = cb, abandoned = false }
  local ok, err = pcall(dispatcher.dispatch, { jsonrpc = "2.0", method = method, params = request_params, id = next_id })
  if not ok then
    M.abandon()
    return false, tostring(err)
  end
  return true
end

--- 放弃等待 (停止或暂停 loop 时). 端点之后交回的结果会被丢弃.
function M.abandon()
  if pending then
    pending.abandoned = true
  end
  pending = nil
end

return M
