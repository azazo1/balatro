--[[
agent 模式的消息节奏: 阅读 / 快速. 阅读用 toast 的 normal (等讲解读完),
快速用 fast (不拦操作, 框仍停留一小会儿). 设置页与 HUD 共用.
回放进行时只记下 home_pace, 不覆盖回放自己的档位.
]]

local M = {}

local PACES = { "normal", "fast" }
local LABELS = { normal = "阅读", fast = "快速" }

---@class BBAgentPaceDeps
---@field config fun(): table
---@field save fun()
---@field toast table
---@field replaying fun(): boolean
local deps

---@param options BBAgentPaceDeps
function M.init(options)
  deps = options
end

---@param value any
---@return boolean
function M.valid(value)
  return LABELS[value] ~= nil
end

---@param value any
---@return string
function M.label(value)
  return LABELS[M.valid(value) and value or "normal"]
end

---@return "normal"|"fast"
function M.current()
  local pace = deps.config().message_pace
  return M.valid(pace) and pace or "normal"
end

--- 写入 toast 的 home. 回放中不立刻套到屏幕上, 回放结束会 apply_home.
---@param pace string
function M.apply(pace)
  if not M.valid(pace) then
    pace = "normal"
  end
  deps.toast.home_pace = pace
  if not deps.replaying() then
    deps.toast.apply_home()
  end
end

---@param pace string
---@return boolean
function M.set(pace)
  if not M.valid(pace) or pace == M.current() then
    return false
  end
  deps.config().message_pace = pace
  deps.save()
  M.apply(pace)
  return true
end

--- HUD 按钮: 阅读 <-> 快速.
---@return boolean
function M.cycle()
  local current = M.current()
  for i, pace in ipairs(PACES) do
    if pace == current then
      return M.set(PACES[i % #PACES + 1])
    end
  end
  return M.set(PACES[1])
end

return M
