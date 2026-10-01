-- 本仓库新增: 在游戏内显示一条 agent 消息 (原版成就通知的样式), 录制时也写入时间线.
-- 默认立刻返回: 消息交给通知排队显示 (见 runtime/toast.lua), 调用方不用干等.
-- 后面的操作会等这条退去再执行 (dispatcher 的门槛), 所以观众总是先看到文字再看到动作.
-- 需要让这次请求自己等读完时传 wait: true (回放用).

---@class Request.Endpoint.Notify.Params
---@field message string 消息正文
---@field title string? 标题, 默认 "Agent"
---@field duration number? 阅读时长秒数, 默认按字数估算
---@field wait boolean? 是否等这条读完再返回, 默认 false (立刻返回)

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
      description = "Wait until this message has been read before returning; defaults to false (return at once)",
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
    -- 录制时间线记录这条消息.
    BB_ACTIVITY.emit("message", title, args.message, args.duration, "notify")
    -- 显示交给通知: 它自己排队并按阅读时长停留, 所以这里默认立刻返回, 调用方接着干活.
    -- gated: 这条算讲解, 后面的改状态的操作要等它退去才执行 (见 dispatcher 的门槛).
    local wait = args.wait == true
    local shown = BB_TOAST.push(title, args.message, args.duration, wait and function()
      send_response({ success = true })
    end or nil, { gated = true })
    if not (wait and shown) then
      send_response({ success = true })
    end
  end,
}
