--[[
回放期间锁定用户输入: 丢弃鼠标, 键盘, 手柄, 触摸事件, 光标位置固定在屏幕左上角的空白处,
避免真实光标经过牌时触发悬停效果并录进视频. 点在右上角 HUD 上的鼠标和触摸放行,
并且 getPosition 在 HUD 上回报真实坐标 (HUD 自己点按钮, 不经过停在左上角的假光标).

中止:
- 桌面: 按住 Esc 1 秒.
- 触摸: 长按屏幕 1.5 秒. 触摸事件照旧被丢弃, 手指移动不取消 (手会抖).
  按下不能靠 love.touchpressed: 游戏的主循环 (game/main.lua 的 love.run) 收到 touchpressed 只记一个标记,
  不交给 love.handlers, 改由 mousepressed 带上 "是触摸" 传下去, 所以 love.touchpressed 从来不会被调用.
  这里改为每帧查 love.touch.getTouches(): 它由 love.event.pump 维护, 与主循环分发哪个事件无关.
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

--- 固定的光标位置 (像素): 左上角空白处. 右上角是 HUD 按钮, 停在那里会一直悬停在按钮上.
local function parked()
  return 4, 4
end

---@param x any
---@param y any
---@return boolean
local function hud_hit(x, y)
  return BB_HUD and BB_HUD.hit and BB_HUD.hit(x, y) == true
end

---@param name string
---@param a any
---@param b any
---@param c any
---@return boolean
local function pass_hud(name, a, b, c)
  if name == "touchpressed" or name == "touchreleased" or name == "touchmoved" then
    return hud_hit(b, c)
  end
  if name == "mousepressed" or name == "mousereleased" or name == "mousemoved" then
    return hud_hit(a, b)
  end
  return false
end

--- 装在所有其它输入钩子之外, 被丢弃的事件不会被录制算作手动操作. 钩子只装一次, 之后的调用只重新上锁.
function M.install()
  M.active = true
  -- release 会把系统光标显示出来, 每次上锁都要再藏起来.
  love.mouse.setVisible(false)
  if installed then
    return
  end
  installed = true
  for _, name in ipairs(DROPPED) do
    originals[name] = love[name]
    love[name] = function(a, b, c, ...)
      if not M.active then
        local original = originals[name]
        return original and original(a, b, c, ...)
      end
      -- 右上角 HUD 的暂停/中止要能点到, 点在框上的鼠标和触摸放行.
      if pass_hud(name, a, b, c) then
        local original = originals[name]
        return original and original(a, b, c, ...)
      end
      -- 触摸的按住时长由 abort_progress 每帧查 love.touch 得出, 这里不处理.
      if name == "keypressed" and a == "escape" then
        escape_down_at = love.timer.getTime()
      elseif name == "keyreleased" and a == "escape" then
        escape_down_at = nil
      end
    end
  end

  local get_position = love.mouse.getPosition
  love.mouse.getPosition = function()
    local x, y = get_position()
    -- 停在左上角避开牌的悬停; 光标在 HUD 上时仍回报真实位置, 否则 HUD 自己也拿不到点.
    if M.active and not hud_hit(x, y) then
      return parked()
    end
    return x, y
  end
  love.mouse.getX = function()
    return (select(1, love.mouse.getPosition()))
  end
  love.mouse.getY = function()
    return (select(2, love.mouse.getPosition()))
  end
end

--- 屏幕上是否有手指. 没有触摸模块 (桌面上通常也有, 只是总为空) 时为 false.
---@return boolean
local function touching()
  local touch = love.touch
  return touch ~= nil and touch.getTouches ~= nil and next(touch.getTouches()) ~= nil
end

--- 中止键按住的进度: 按住时长与要求时长的比例, 取键盘与触摸里较大的一个, 限制在 0~1. 到 1 即请求中止.
--- 每帧调用一次 (player.update), 触摸的按下与松开也在这里按 love.touch 的当前状态更新.
---@return number
function M.abort_progress()
  if not M.active then
    return 0
  end
  local now = love.timer.getTime()
  if touching() then
    touch_down_at = touch_down_at or now
  else
    touch_down_at = nil
  end
  local best = 0
  if escape_down_at then
    best = (now - escape_down_at) / ESC_HOLD
  end
  if touch_down_at then
    best = math.max(best, (now - touch_down_at) / TOUCH_HOLD)
  end
  return math.min(1, best)
end

function M.release()
  M.active = false
  escape_down_at = nil
  touch_down_at = nil
  love.mouse.setVisible(true)
end

return M
