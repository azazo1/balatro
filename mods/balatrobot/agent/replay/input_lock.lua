--[[
回放期间锁定用户输入: 丢弃鼠标, 键盘, 手柄, 触摸事件, 光标位置固定在屏幕右上角的空白处,
避免真实光标经过牌时触发悬停效果并录进视频. 按住 Esc 1 秒中止回放.
]]

local M = {
  active = false,
}

local ABORT_HOLD = 1

local escape_down_at = nil
local originals = {}

local DROPPED = {
  "mousepressed",
  "mousereleased",
  "mousemoved",
  "wheelmoved",
  "keypressed",
  "keyreleased",
  "textinput",
  "gamepadpressed",
  "gamepadreleased",
  "gamepadaxis",
  "joystickpressed",
  "joystickreleased",
  "joystickaxis",
  "touchpressed",
  "touchreleased",
  "touchmoved",
}

--- 固定的光标位置 (像素): 右上角, 小丑和消耗牌槽的上方.
local function parked()
  local w = love.graphics.getWidth()
  return w - 4, 4
end

--- 装在所有其它输入钩子之外, 被丢弃的事件不会被录制算作手动操作.
function M.install()
  M.active = true
  for _, name in ipairs(DROPPED) do
    originals[name] = love[name]
    love[name] = function(a, ...)
      if not M.active then
        local original = originals[name]
        return original and original(a, ...)
      end
      if name == "keypressed" and a == "escape" then
        escape_down_at = love.timer.getTime()
      elseif name == "keyreleased" and a == "escape" then
        escape_down_at = nil
      end
    end
  end

  local get_position = love.mouse.getPosition
  love.mouse.getPosition = function()
    if M.active then
      return parked()
    end
    return get_position()
  end
  local get_x, get_y = love.mouse.getX, love.mouse.getY
  love.mouse.getX = function()
    return M.active and (parked()) or get_x()
  end
  love.mouse.getY = function()
    return M.active and select(2, parked()) or get_y()
  end
  love.mouse.setVisible(false)
end

--- 是否按住 Esc 超过 ABORT_HOLD 秒.
---@return boolean
function M.abort_requested()
  return escape_down_at ~= nil and love.timer.getTime() - escape_down_at >= ABORT_HOLD
end

function M.release()
  M.active = false
  love.mouse.setVisible(true)
end

return M
