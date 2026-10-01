--[[
在进程内调用端点, 不经过 HTTP. 内置 agent loop 用它执行动作.

端点通过 BB_DISPATCHER.Server.send_response 交回结果. 这里包一层: 有本地调用在等时, 把结果交给
它的回调; HTTP 服务此时不监听 (内置模式与外部模式互斥), 原函数因没有客户端直接返回.
overlay.lua 可能先把请求挂起, 在弹窗关掉后再用同一个 send_response 交回结果, 这里照样能收到.

一次只允许一个本地调用, 与 HTTP 服务一次只处理一个请求的约束一致.

过期响应: 端点的回复可能比调用活得久 (overlay 把请求挂到弹窗关闭, 或者在等动画). 如果中途 stop 或
暂停, 调用被 abandon, 之后又开了新的一次调用, 旧的那份回复会顺着同一条 send_response 回来, 看上去
和新调用一模一样. 所以调用期间把目标端点的 execute 换成一个带代号的包装: 回复到达时先看代号是不是
仍然等于当前待处理的那一次, 不是就丢掉并记一次数. 代号在包装里捕获, 不依赖响应内容 (响应表里没有
可以识别调用的字段).

必须在 BB_OVERLAY.install 与 BB_ACTIVITY.install 之后安装, 让本地调用同样经过弹窗拦截与活动追踪.
]]

local M = {}

local pending = nil -- {id, method, cb, started}
local next_id = 0
local dropped = 0
local installed_server = nil

local function log_drop(method, id, current)
  dropped = dropped + 1
  sendDebugMessage(
    string.format("丢弃过期响应 (第 %d 次调用 %s; 当前 %s)", id, method, current or "无待处理调用"),
    "BB.AGENT.LOOP"
  )
end

---@param server table BB_SERVER
function M.install(server)
  if installed_server == server then
    return
  end
  installed_server = server
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
  next_id = next_id + 1
  local id = next_id
  pending = { id = id, method = method, cb = cb, started = love.timer.getTime() }

  -- 端点可能在本次 dispatch 之后很久才回复, 回复时它手上拿着的还是这里包出来的函数.
  local endpoint = dispatcher.endpoints and dispatcher.endpoints[method]
  local orig_execute = endpoint and endpoint.execute
  if orig_execute then
    endpoint.execute = function(args, send_response)
      return orig_execute(args, function(response)
        if pending and pending.id == id then
          send_response(response)
        else
          log_drop(method, id, pending and pending.method or nil)
        end
      end)
    end
  end

  local ok, err = pcall(dispatcher.dispatch, { jsonrpc = "2.0", method = method, params = request_params, id = id })
  if orig_execute then
    endpoint.execute = orig_execute
  end
  if not ok then
    pending = nil
    return false, tostring(err)
  end
  return true
end

--- 放弃等待 (停止或暂停 loop 时). 端点之后交回的结果会被丢弃.
function M.abandon()
  pending = nil
end

return M
