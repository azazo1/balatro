--[[
回放期间的输入锁, 经 bbcore 的输入门 (BB_INPUT) 生效, 自己不包 love.* 回调.

策略 (install 到 release 之间, 含收尾的停留):
- 丢弃对游戏的全部操作 (鼠标, 键盘, 手柄, 触摸都以这些事件进来). 点在右上角 HUD 上的由输入门交给 HUD.
- 游戏读到的光标停在左上角空白处 (park), 真实光标经过牌时不会触发悬停并录进视频; 光标在 HUD 上时
  仍回报真实位置, HUD 才能悬停.
- 放行移动: 原版只用它切换系统光标的显隐 (鼠标显示, 触摸藏起), 游戏里的光标位置每帧读停放后的值.
  系统光标照常显示在真实位置 (录像读回的是游戏画布, 不含它), 看得到指针但点了没反应.
- 摇杆与扳机不轮询.

中止 (按住时长, 每帧由 abort_progress 算):
- 桌面: 按住 Esc 1 秒. 手柄: 按住 back 或 start 1 秒.
  按下与松开由输入门的观察者看到 (事件虽被丢弃, 观察者照样收到). 窗口失去焦点时清零,
  免得收不到松开而自己中止.
- 触摸: 长按屏幕 1.5 秒. 按在 HUD 上的手指不算, 否则点一下暂停也会闪中止进度.
  按下不能靠 love.touchpressed: 原版主循环收到它只记一个标记, 改以 mousepressed 交出,
  所以每帧查 love.touch.getTouches(), 与主循环分发哪个事件无关.
]]

local M = {
  active = false,
}

local HOLD = 1 -- Esc 与手柄键
local TOUCH_HOLD = 1.5

local ABORT_KEYS = { escape = true }
local ABORT_PAD = { back = true, start = true }

---@class BBReplayInputDeps
---@field input table bbcore 的 BB_INPUT

---@type BBReplayInputDeps
local deps
local initialized = false

-- 正在按住的中止键 (键盘与手柄), 值是按下的时刻.
---@type table<string, number>
local held = {}
local touch_down_at = nil

local POLICY = {
  pass = function(ev)
    return ev.kind == "move"
  end,
  park = true,
  block_axis = true,
}

---@param ev table
---@return string?
local function abort_key(ev)
  if (ev.kind == "key_press" or ev.kind == "key_release") and ABORT_KEYS[ev.key] then
    return "key:" .. ev.key
  end
  if (ev.kind == "pad_press" or ev.kind == "pad_release") and ev.source == "gamepad" and ABORT_PAD[ev.button] then
    return "pad:" .. tostring(ev.joystick) .. ":" .. ev.button
  end
  return nil
end

---@param ev table
local function observe(ev)
  if not M.active then
    return
  end
  local key = abort_key(ev)
  if not key then
    return
  end
  if ev.kind == "key_press" or ev.kind == "pad_press" then
    held[key] = held[key] or love.timer.getTime()
  else
    held[key] = nil
  end
end

---@param options BBReplayInputDeps
function M.init(options)
  deps = options
  if initialized then
    return
  end
  initialized = true
  deps.input.add_policy("replay", function()
    return M.active and POLICY or nil
  end)
  deps.input.observe("replay", observe)
end

--- 系统光标按最近一次的输入方式显示: 用鼠标时显示, 触摸或手柄时藏起来, 与原版 set_HID_flags 一致.
--- 命令行回放开局时还没动过鼠标, 原版的光标仍是藏着的, 所以上锁时设一次; 之后移动照常放行, 由原版切换.
local function show_system_cursor()
  local hid = G and G.CONTROLLER and G.CONTROLLER.HID
  love.mouse.setVisible(not hid or hid.mouse ~= false)
end

--- 上锁. 可以重复调用.
function M.install()
  M.active = true
  held = {}
  touch_down_at = nil
  show_system_cursor()
end

--- 屏幕上有没有不在 HUD 上的手指. 没有触摸模块 (桌面上通常也有, 只是总为空) 时为 false.
---@return boolean
local function touching_outside_hud()
  local touch = love.touch
  if not (touch and touch.getTouches) then
    return false
  end
  for _, id in ipairs(touch.getTouches()) do
    local x, y
    if touch.getPosition then
      x, y = touch.getPosition(id)
    end
    if not (deps and deps.input.hud_hit(x, y)) then
      return true
    end
  end
  return false
end

--- 中止键按住的进度: 按住时长与要求时长的比例, 取键盘, 手柄与触摸里最大的一个, 限制在 0~1. 到 1 即请求中止.
--- 每帧调用一次 (player.update), 触摸的按下与松开也在这里按 love.touch 的当前状态更新.
---@return number
function M.abort_progress()
  if not M.active then
    return 0
  end
  local now = love.timer.getTime()
  if love.window and love.window.hasFocus and not love.window.hasFocus() then
    held = {}
  end
  if touching_outside_hud() then
    touch_down_at = touch_down_at or now
  else
    touch_down_at = nil
  end
  local best = 0
  for _, since in pairs(held) do
    best = math.max(best, (now - since) / HOLD)
  end
  if touch_down_at then
    best = math.max(best, (now - touch_down_at) / TOUCH_HOLD)
  end
  return math.min(1, best)
end

function M.release()
  M.active = false
  held = {}
  touch_down_at = nil
  love.mouse.setVisible(true)
end

return M
