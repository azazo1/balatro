--[[
内置 agent 的对话历史. 纯逻辑, 不依赖游戏.

- messages 按 chat completions 的格式存放, 第一条是系统提示.
- 一次 assistant 回复里的 tool_calls 必须紧跟对应的 tool 消息, 所以只在 "一轮完整结束" 的边界上切分:
  切点总在 assistant 或 user 消息之前, 不会把 tool 结果和它的调用拆开.
- 压缩 (由 driver 触发):
  - split 从后往前留出最近的原文 (按估算 token), 返回切点; 较早的部分由 render_older 渲染成文字交给模型写摘要.
  - apply_summary 用摘要替换较早的部分, 最近的原文保留.
  - compact 是退路 (写摘要失败时): 丢掉全部旧消息, 只留系统提示和一条用户消息 (每步一行的记录 + 当前状态).
- digest 记录每一步做了什么和结果 (一行), 给 compact 用.
]]

local M = {}

local DIGEST_KEEP = 40 -- 退路压缩后保留的记录条数
local CHARS_PER_TOKEN = 2 -- 估算用: 中文约 1~1.5 字一个 token, 取偏保守的值

--- 粗略估算一条消息的 token 数.
---@param m table
---@return integer
local function message_tokens(m)
  local chars = 0
  if type(m.content) == "string" then
    chars = chars + #m.content
  end
  if type(m.reasoning_content) == "string" then
    chars = chars + #m.reasoning_content
  end
  for _, call in ipairs(m.tool_calls or {}) do
    chars = chars + #(call["function"] and call["function"].arguments or "")
  end
  -- #s 是字节数, 中文一个字 3 字节
  return math.floor(chars / 3 / CHARS_PER_TOKEN * 2)
end

---@param system string 系统提示
---@return table
function M.new(system)
  local self = {
    system = system,
    messages = { { role = "system", content = system } },
    digest = {},
  }

  ---@param message table
  function self:add(message)
    self.messages[#self.messages + 1] = message
  end

  ---@param line string
  function self:note(line)
    self.digest[#self.digest + 1] = line
    while #self.digest > DIGEST_KEEP * 2 do
      table.remove(self.digest, 1)
    end
  end

  --- 粗略估算当前历史的 token 数 (服务端没报用量时的退路).
  ---@param without_system boolean? 只算系统提示之后的对话 (切分只在这部分里进行)
  ---@return integer
  function self:estimate(without_system)
    local total = 0
    for i, m in ipairs(self.messages) do
      if not (without_system and i == 1) then
        total = total + message_tokens(m)
      end
    end
    return total
  end

  --- 最后一条 assistant 的 tool_calls 是否都已经有了 tool 结果.
  ---@return boolean
  function self:settled()
    local open = {}
    for _, m in ipairs(self.messages) do
      if m.role == "assistant" then
        open = {}
        for _, call in ipairs(m.tool_calls or {}) do
          open[call.id] = true
        end
      elseif m.role == "tool" and m.tool_call_id then
        open[m.tool_call_id] = nil
      end
    end
    return next(open) == nil
  end

  --- 压缩的切点: 从后往前累计估算 token, 留下不超过 keep_tokens 的最近原文; 最后一轮再长也整轮留下.
  --- 切点总在 assistant 或 user 消息之前. 没有可以交给摘要的较早部分时返回 nil.
  ---@param keep_tokens integer
  ---@return integer? cut 最近原文从 messages[cut] 开始, messages[2..cut-1] 是较早的部分
  function self:split(keep_tokens)
    local total = 0
    local cut = nil
    for i = #self.messages, 2, -1 do
      local m = self.messages[i]
      total = total + message_tokens(m)
      local boundary = m.role == "assistant" or m.role == "user"
      if boundary then
        if cut and total > keep_tokens then
          break
        end
        cut = i
      end
    end
    if not cut or cut <= 2 then
      return nil
    end
    return cut
  end

  --- 较早的部分渲染成给摘要用的文字. 思考过程不带, 只留看到的状态, 说的话和做的操作.
  ---@param cut integer split 的返回值
  ---@param encode fun(value: any): string
  ---@return string
  function self:render_older(cut, encode)
    local lines = {}
    for i = 2, cut - 1 do
      local m = self.messages[i]
      if m.role == "user" then
        lines[#lines + 1] = "[状态/说明]\n" .. tostring(m.content or "")
      elseif m.role == "assistant" then
        if type(m.content) == "string" and m.content:find("%S") then
          lines[#lines + 1] = "[agent]\n" .. m.content
        end
        for _, call in ipairs(m.tool_calls or {}) do
          local fn = call["function"] or {}
          local args = fn.arguments
          if type(args) ~= "string" then
            local ok, text = pcall(encode, args or {})
            args = ok and text or ""
          end
          lines[#lines + 1] = string.format("[调用] %s %s", tostring(fn.name), args)
        end
      elseif m.role == "tool" then
        lines[#lines + 1] = "[结果]\n" .. tostring(m.content or "")
      end
    end
    return table.concat(lines, "\n\n")
  end

  --- 用摘要替换较早的部分 (messages[2..cut-1]), 最近的原文原样保留.
  --- 最近原文以 user 消息开头时把摘要并进去, 免得出现连续两条 user.
  ---@param cut integer
  ---@param text string 已经带好标题的摘要
  function self:apply_summary(cut, text)
    local kept = { { role = "system", content = self.system } }
    local first = self.messages[cut]
    if first and first.role == "user" then
      kept[2] = { role = "user", content = text .. "\n\n" .. tostring(first.content or "") }
      cut = cut + 1
    else
      kept[2] = { role = "user", content = text }
    end
    for i = cut, #self.messages do
      kept[#kept + 1] = self.messages[i]
    end
    self.messages = kept
  end

  --- 退路压缩: 丢掉旧消息, 用记录和当前状态重新开始. 必须在 settled() 为真时调用.
  ---@param current string 当前状态的用户消息
  ---@param recap fun(digest: string): string
  function self:compact(current, recap)
    local start = math.max(1, #self.digest - DIGEST_KEEP + 1)
    local lines = {}
    for i = start, #self.digest do
      lines[#lines + 1] = self.digest[i]
    end
    self.messages = { { role = "system", content = self.system } }
    local content = current
    if #lines > 0 then
      content = recap(table.concat(lines, "\n")) .. "\n\n" .. current
    end
    self.messages[2] = { role = "user", content = content }
  end

  --- 清空, 重新开始 (停止 loop 或开新局).
  function self:reset()
    self.messages = { { role = "system", content = self.system } }
    self.digest = {}
  end

  return self
end

return M
