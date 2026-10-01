--[[
端点响应的公共出口 (BB_TRANSPORT), 交给 BB_DISPATCHER.init 作为 Server.

upstream 里端点的结果直接写进 HTTP 服务 (BB_SERVER.send_response). 拆成 bbcore 之后, 没装 balatrobot 时
也要能在进程内执行端点 (回放), 所以端点只把结果交到这里, 由注册的 writer 各自取走:
- balatrobot 的 HTTP 服务注册一个 writer, 把结果写给连着的客户端;
- 活动追踪 (runtime/activity.lua), 内置 loop 的本地调用 (balatrobot 的 agent/loop/local_call.lua) 照旧包装
  send_response 字段, 在结果经过时取走.

send_response 返回是否有 writer 写出了结果, 与 upstream 的 BB_SERVER.send_response 一致 (没有客户端时为 false).
]]

local M = {
  -- rpc.discover 的返回内容, 由 balatrobot 在 HTTP 服务启动后填入 (OpenRPC JSON 字符串).
  ---@type string?
  openrpc_spec = nil,
}

---@type (fun(response: table): boolean)[]
local writers = {}

--- 注册一个 writer. 返回注销函数.
---@param fn fun(response: table): boolean
---@return fun()
function M.add_writer(fn)
  writers[#writers + 1] = fn
  return function()
    for i, w in ipairs(writers) do
      if w == fn then
        table.remove(writers, i)
        return
      end
    end
  end
end

---@param response table
---@return boolean sent 是否有 writer 写出了结果
function M.send_response(response)
  local sent = false
  for _, fn in ipairs(writers) do
    local ok, result = pcall(fn, response)
    if not ok then
      sendErrorMessage("Response writer failed: " .. tostring(result), "BB.TRANSPORT")
    elseif result then
      sent = true
    end
  end
  return sent
end

return M
