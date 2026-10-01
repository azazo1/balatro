--[[
内置 agent 的对话历史. 纯逻辑, 不依赖游戏.

- messages 按 chat completions 的格式存放, 第一条是系统提示.
- 一次 assistant 回复里的 tool_calls 必须紧跟对应的 tool 消息, 所以只在 "一轮完整结束" 的边界上压缩:
  压缩时整体丢掉旧消息, 只留系统提示和一条用户消息 (之前各步的简要记录 + 当前状态).
- digest 记录每一步做了什么和结果 (一行), 压缩后作为记录交给模型.
]]

local M = {}

local DIGEST_KEEP = 40 -- 压缩后保留的记录条数
local CHARS_PER_TOKEN = 2 -- 估算用: 中文约 1~1.5 字一个 token, 取偏保守的值

---@param system string 系统提示
---@param opts {budget: integer?}? budget: 估算的 token 超过它时建议压缩, 默认 60000
---@return table
function M.new(system, opts)
  opts = opts or {}
  local self = {
    system = system,
    messages = { { role = "system", content = system } },
    digest = {},
    budget = opts.budget or 60000,
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

  --- 粗略估算当前历史的 token 数.
  ---@return integer
  function self:estimate()
    local chars = 0
    for _, m in ipairs(self.messages) do
      if type(m.content) == "string" then
        chars = chars + #m.content
      end
      if type(m.reasoning_content) == "string" then
        chars = chars + #m.reasoning_content
      end
      for _, call in ipairs(m.tool_calls or {}) do
        chars = chars + #(call["function"] and call["function"].arguments or "")
      end
    end
    -- #s 是字节数, 中文一个字 3 字节
    return math.floor(chars / 3 / CHARS_PER_TOKEN * 2)
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

  ---@return boolean
  function self:over_budget()
    return self:estimate() > self.budget
  end

  --- 压缩: 丢掉旧消息, 用记录和当前状态重新开始. 必须在 settled() 为真时调用.
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
