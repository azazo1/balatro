--[[
回放期间锁定用户输入: 丢弃鼠标, 键盘, 手柄, 触摸事件, 光标位置固定在屏幕右上角的空白处,
避免真实光标经过牌时触发悬停效果并录进视频.

中止:
- 桌面: 按住 Esc 1 秒.
- 触摸: 长按屏幕 1.5 秒. 触摸事件照旧被丢弃, 这里只额外记住按下的时刻, 手指移动不取消 (手会抖).
按住期间把进度报给调用方显示, 松手就清零.
]]

local M = {
  active = false,
}

local ESC_HOLD = 1
local TOUCH_HOLD = 1.5

local escape_down_at = nil
local touch_down_at = nil
local installed = false
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

--- 装在所有其它输入钩子之外, 被丢弃的事件不会被录制算作手动操作. 重复调用只生效一次.
function M.install()
  M.active = true
  if installed then
    return
  end
  installed = true
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
      elseif name == "touchpressed" then
        touch_down_at = love.timer.getTime()
      elseif name == "touchreleased" then
        touch_down_at = nil
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

--- 按住时长与要求时长的比例, 取键盘与触摸里较大的一个, 限制在 0~1.
---@return number
function M.abort_progress()
  if not M.active then
    return 0
  end
  local now = love.timer.getTime()
  local best = 0
  if escape_down_at then
    best = math.max(best, (now - escape_down_at) / ESC_HOLD)
  end
  if touch_down_at then
    best = math.max(best, (now - touch_down_at) / TOUCH_HOLD)
  end
  return math.min(1, math.max(0, best))
end

--- 是否按够时长: 桌面按住 Esc 1 秒, 触摸长按 1.5 秒.
---@return boolean
function M.abort_requested()
  return M.abort_progress() >= 1
end

function M.release()
  M.active = false
  escape_down_at = nil
  touch_down_at = nil
  love.mouse.setVisible(true)
end

return M
