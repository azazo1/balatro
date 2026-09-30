-- 本仓库新增: 关掉解锁通知弹窗, 等同点击 "继续".
-- 如果之前的请求因这个弹窗先返回了, 等它完成后返回它的结果, 否则返回当前状态.

---@type Endpoint
return {
  name = "continue",

  description = "Close the unlock notification, like clicking Continue",

  schema = {},

  requires_state = nil,

  ---@param _ table
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    if BB_OVERLAY.kind() ~= "unlock" then
      send_response({ message = "No unlock notification is open", name = BB_ERROR_NAMES.INVALID_STATE })
      return
    end
    BB_OVERLAY.continue(send_response)
  end,
}
