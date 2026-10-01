-- 本仓库新增: 在游戏内显示一条 agent 消息 (原版成就通知的样式), 录制时也写入时间线.
-- 默认等观众读完 (按字数估算的阅读时长) 再返回, 连续调用时消息一条接一条出现.

---@class Request.Endpoint.Notify.Params
---@field message string 消息正文
---@field title string? 标题, 默认 "Agent"
---@field duration number? 阅读时长秒数, 默认按字数估算
---@field wait boolean? 是否等读完再返回, 默认 true

---@type Endpoint
return {
  name = "notify",

  description = "Show a short agent message in game (vanilla notification style)",

  schema = {
    message = {
      type = "string",
      required = true,
      description = "Message text, shown in up to 12 lines (about 180 Chinese or 300 ASCII characters), longer text is cut off",
    },
    title = { type = "string", required = false, description = "Title line, defaults to 'Agent'" },
    duration = {
      type = "number",
      required = false,
      description = "Reading time in seconds, estimated from the text length when omitted",
    },
    wait = {
      type = "boolean",
      required = false,
      description = "Return after the reading time so consecutive messages appear one by one, defaults to true",
    },
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
    local title = args.title or "Agent"
    -- 录制时间线记录这条消息; 显示由这里直接调用, 以便拿到读完的回调.
    BB_ACTIVITY.emit("message", title, args.message, args.duration, "notify")
    local wait = args.wait ~= false
    local shown = BB_TOAST.push(title, args.message, args.duration, wait and function()
      send_response({ success = true })
    end or nil)
    if not (wait and shown) then
      send_response({ success = true })
    end
  end,
}
