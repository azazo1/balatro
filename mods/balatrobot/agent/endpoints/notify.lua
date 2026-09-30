-- 本仓库新增: 在游戏内显示一条 agent 消息 (原版成就通知的样式), 录制时也写入时间线.

---@class Request.Endpoint.Notify.Params
---@field message string 消息正文
---@field title string? 标题, 默认 "Agent"
---@field duration number? 停留秒数, 默认按长度 3~8s

---@type Endpoint
return {
  name = "notify",

  description = "Show a short agent message in game (vanilla notification style)",

  schema = {
    message = { type = "string", required = true, description = "Message text, up to 200 characters" },
    title = { type = "string", required = false, description = "Title line, defaults to 'Agent'" },
    duration = { type = "number", required = false, description = "Seconds to stay on screen, 3~8 by length when omitted" },
  },

  requires_state = nil,

  ---@param args Request.Endpoint.Notify.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    if args.message == "" then
      send_response({ message = "Field 'message' must not be empty", name = BB_ERROR_NAMES.BAD_REQUEST })
      return
    end
    if args.duration ~= nil and (args.duration <= 0 or args.duration > 30) then
      send_response({ message = "Field 'duration' must be in (0, 30]", name = BB_ERROR_NAMES.BAD_REQUEST })
      return
    end
    BB_ACTIVITY.emit("message", args.title or "Agent", args.message, args.duration, "notify")
    send_response({ success = true })
  end,
}
