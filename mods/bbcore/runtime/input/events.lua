--[[
输入事件的归一化 (纯逻辑, 不碰全局). 由 runtime/input/gate.lua 使用.

LÖVE 回调名 -> 统一的事件表 { name, kind, ... }:
- 指针: press / release / move, 带 x, y (窗口像素), button (1 左键 2 右键), touch (是不是触摸).
  触摸不会以 touch* 的形式到这里: 原版主循环 (game/main.lua 的 love.run) 收到 touchpressed 只记一个标记,
  再以 mousepressed(x, y, 1, true) 交出; 松开与移动由 SDL 合成的 mousereleased / mousemoved 带上 istouch.
  所以不包 touch* 回调, 按住的手指要看 love.touch.getTouches().
- 滚轮 wheel; 键盘 key_press / key_release, 带 key, isrepeat; 文字 text.
- 手柄: pad_press / pad_release, 带 joystick, button (原始键名, 未经 G.button_mapping); pad_axis.
  gamepad* 与 joystick* 都归到这里, 用 source 区分. 摇杆与扳机由原版每帧轮询, 不经过这些回调, 见 gate 的 update_axis.
]]

local M = {}

--- gate 要包装的 LÖVE 回调. 只此一份.
M.NAMES = {
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
}

local PAD = {
  gamepadpressed = { kind = "pad_press", source = "gamepad" },
  gamepadreleased = { kind = "pad_release", source = "gamepad" },
  joystickpressed = { kind = "pad_press", source = "joystick" },
  joystickreleased = { kind = "pad_release", source = "joystick" },
}

--- 把一次回调的参数归一成事件表. 不认识的名字返回 nil.
---@param name string LÖVE 回调名
---@param a any
---@param b any
---@param c any
---@param d any
---@param e any
---@return table?
function M.classify(name, a, b, c, d, e)
  if name == "mousepressed" or name == "mousereleased" then
    return { name = name, kind = name == "mousepressed" and "press" or "release", x = a, y = b, button = c, touch = d == true }
  elseif name == "mousemoved" then
    return { name = name, kind = "move", x = a, y = b, touch = e == true }
  elseif name == "wheelmoved" then
    return { name = name, kind = "wheel", x = a, y = b }
  elseif name == "keypressed" then
    return { name = name, kind = "key_press", key = a, isrepeat = c == true }
  elseif name == "keyreleased" then
    return { name = name, kind = "key_release", key = a }
  elseif name == "textinput" then
    return { name = name, kind = "text", text = a }
  elseif PAD[name] then
    return { name = name, kind = PAD[name].kind, source = PAD[name].source, joystick = a, button = b }
  elseif name == "gamepadaxis" or name == "joystickaxis" then
    return { name = name, kind = "pad_axis", joystick = a, axis = b, value = c }
  end
  return nil
end

-- 按下对应的松开, 用于成对处理.
local RELEASE_OF = { press = "release", key_press = "key_release", pad_press = "pad_release" }
local PRESS_OF = { release = "press", key_release = "key_press", pad_release = "pad_press" }

---@param ev table
---@return boolean
function M.is_press(ev)
  return RELEASE_OF[ev.kind] ~= nil
end

---@param ev table
---@return boolean
function M.is_release(ev)
  return PRESS_OF[ev.kind] ~= nil
end

--- 一次按下与它的松开共用的键: 同一个指针键, 同一个键盘键, 同一个手柄的同一个键.
--- 不是按下/松开时返回 nil.
---@param ev table
---@return string?
function M.capture_key(ev)
  local kind = ev.kind
  if kind == "press" or kind == "release" then
    return "pointer:" .. tostring(ev.button)
  elseif kind == "key_press" or kind == "key_release" then
    return "key:" .. tostring(ev.key)
  elseif kind == "pad_press" or kind == "pad_release" then
    return "pad:" .. tostring(ev.source) .. ":" .. tostring(ev.joystick) .. ":" .. tostring(ev.button)
  end
  return nil
end

--- 事件是否带窗口坐标 (可能点在 HUD 上).
---@param ev table
---@return boolean
function M.has_point(ev)
  return (ev.kind == "press" or ev.kind == "release" or ev.kind == "move")
    and type(ev.x) == "number"
    and type(ev.y) == "number"
end

return M
