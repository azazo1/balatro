--[[
唯一的输入门 (BB_INPUT). 各 mod 不再自己包 love.* 输入回调, 都经过这里, 顺序固定:

1. 归一化 (runtime/input/events.lua): 事件名单只此一份, 触摸以 mouse*(istouch) 进来.
2. HUD: 点在右上角 HUD 上的按下由 HUD 自己处理 (set_hud 登记), 不交给游戏, 也不看策略.
3. 策略: 当前操作方登记的策略决定交给游戏还是丢弃 (add_policy). 没有生效的策略时全部交给游戏.
   - agent (balatrobot): 锁操作开着时丢弃游戏操作, 放行移动, Esc, F9 与手柄 start.
   - 回放 (bbreplay): 全部丢弃, 游戏读到的光标停在左上角, 摇杆也拦.
4. 原版 (或更内层的其它 mod 钩子).
5. 观察者 (observe): 每个事件连同去向 ("hud" / "game" / "drop") 交给观察者, 例如录像的活动判断,
   回放的中止计时, agent 的 F9 与手动操作检测. 观察者不改变去向.

按下与松开成对: 松开跟着它的按下走 (HUD / 游戏 / 丢弃), 不看松开那一刻的策略和落点.
拖着牌移到 HUD 上松手, 或按住期间锁操作切换, 游戏都能收到松开, 拖动和按键不会卡住.

原版不经过回调的两处也在这里接管:
- love.mouse.getPosition (原版每帧读它定光标): 策略要求停放时回报固定位置, 光标在 HUD 上时仍回报真实值.
- Controller:update_axis (摇杆, 扳机每帧轮询转成按键): 策略拦摇杆时不轮询, 已按下的轴按键先松开.

安装: bbcore 在第一帧 update 里装一次 (所有 mod 已加载完), 所以总在其它 mod 的输入钩子之外.
]]

local LOGGER = "BB.INPUT"

-- 停放的光标位置 (窗口像素): 左上角空白处. 右上角是 HUD, 停在那里会一直悬停在按钮上.
local PARK_X, PARK_Y = 4, 4

local M = {
  PARK_X = PARK_X,
  PARK_Y = PARK_Y,
}

---@type table runtime/input/events.lua
local Events

---@class BBInputPolicy
---@field pass fun(ev: table): boolean? 返回 true 时交给游戏, 否则丢弃. 缺省全部丢弃
---@field park boolean? 游戏读到的光标停在左上角
---@field block_axis boolean? 不轮询摇杆与扳机

---@type {id: string, fn: fun(): BBInputPolicy?}[]
local policies = {}
---@type {id: string, fn: fun(ev: table, outcome: string)}[]
local observers = {}
---@type {hit: fun(x: number, y: number): boolean, press: fun(ev: table), release: fun(ev: table)}?
local hud = nil

-- 按下的去向, 键见 Events.capture_key. 松开跟着它走.
---@type table<string, string>
local captured = {}

local installed = false
local raw_get_position = nil
local last_policy_id = false -- 上一次生效的策略, 只在变化时记日志
local failed = {} -- 报过错的策略或观察者, 每个只记一次

---@param options {events: table}
function M.init(options)
  Events = options.events
end

---@param list table
---@param id string
---@param field string
---@param value any
local function upsert(list, id, field, value)
  for _, entry in ipairs(list) do
    if entry.id == id then
      entry[field] = value
      return
    end
  end
  list[#list + 1] = { id = id, [field] = value }
end

--- 登记一个操作方的策略. fn 每次被问时返回生效的策略, 不生效时返回 nil. 先登记的先问.
---@param id string
---@param fn fun(): BBInputPolicy?
function M.add_policy(id, fn)
  upsert(policies, id, "fn", fn)
end

--- 登记观察者: fn(ev, outcome) 在事件处理之后调用, outcome 为 "hud" / "game" / "drop".
---@param id string
---@param fn fun(ev: table, outcome: string)
function M.observe(id, fn)
  upsert(observers, id, "fn", fn)
end

--- 登记 HUD 的命中与按下/松开处理 (bbcore 的 ui/hud.lua).
---@param handler {hit: fun(x: number, y: number): boolean, press: fun(ev: table), release: fun(ev: table)}
function M.set_hud(handler)
  hud = handler
end

---@param id string
---@param err any
local function report_once(id, err)
  if failed[id] then
    return
  end
  failed[id] = true
  sendErrorMessage("Input " .. id .. " failed: " .. tostring(err), LOGGER)
end

--- 当前生效的策略, 没有时为 nil.
---@return BBInputPolicy?
---@return string? id
function M.policy()
  local found, found_id = nil, nil
  for _, entry in ipairs(policies) do
    local ok, policy = pcall(entry.fn)
    if not ok then
      report_once("policy " .. entry.id, policy)
    elseif policy then
      found, found_id = policy, entry.id
      break
    end
  end
  local now_id = found_id or false
  if now_id ~= last_policy_id then
    sendDebugMessage("Input policy: " .. tostring(found_id or "none"), LOGGER)
    last_policy_id = now_id
  end
  return found, found_id
end

---@param x any
---@param y any
---@return boolean
function M.hud_hit(x, y)
  if not hud or type(x) ~= "number" or type(y) ~= "number" then
    return false
  end
  local ok, hit = pcall(hud.hit, x, y)
  return ok and hit == true
end

---@param policy BBInputPolicy
---@param ev table
---@return boolean
local function passes(policy, ev)
  if not policy.pass then
    return false
  end
  local ok, result = pcall(policy.pass, ev)
  if not ok then
    report_once("policy pass", result)
    return false
  end
  return result == true
end

--- 决定事件的去向. 按下记下去向, 松开取走它.
---@param ev table
---@return string outcome "hud" / "game" / "drop"
local function decide(ev)
  local key = Events.capture_key(ev)
  if key and Events.is_release(ev) then
    local outcome = captured[key]
    captured[key] = nil
    if outcome then
      return outcome
    end
    -- 按下发生在装上之前 (或已被同一个键的下一次按下覆盖): 按当前策略决定, 宁可多交给游戏也不让它卡住.
    local policy = M.policy()
    return (not policy or passes(policy, ev)) and "game" or "drop"
  end
  local outcome
  if ev.kind == "press" and M.hud_hit(ev.x, ev.y) then
    outcome = "hud"
  else
    local policy = M.policy()
    outcome = (not policy or passes(policy, ev)) and "game" or "drop"
  end
  if key then
    captured[key] = outcome
  end
  return outcome
end

--- 处理一次回调. 返回原函数的返回值 (交给游戏时).
---@param name string
---@param original function?
---@return any
local function route(name, original, a, b, c, d, e, f)
  local ev = Events.classify(name, a, b, c, d, e)
  if not ev then
    return original and original(a, b, c, d, e, f)
  end
  local outcome = decide(ev)
  local result
  if outcome == "hud" then
    local handler = ev.kind == "press" and hud.press or hud.release
    local ok, err = pcall(handler, ev)
    if not ok then
      report_once("hud " .. ev.kind, err)
    end
  elseif outcome == "game" and original then
    result = original(a, b, c, d, e, f)
  end
  for _, entry in ipairs(observers) do
    local ok, err = pcall(entry.fn, ev, outcome)
    if not ok then
      report_once("observer " .. entry.id, err)
    end
  end
  return result
end
M._route = route -- 只给测试用

--- 游戏读到的光标位置. 策略要求停放且光标不在 HUD 上时回报左上角.
---@return number x
---@return number y
local function get_position()
  local x, y = raw_get_position()
  local policy = M.policy()
  if policy and policy.park and not M.hud_hit(x, y) then
    return PARK_X, PARK_Y
  end
  return x, y
end

--- 真实的光标位置, 不经停放 (HUD 自己用).
---@return number? x
---@return number? y
function M.real_position()
  local fn = raw_get_position or (love and love.mouse and love.mouse.getPosition)
  if not fn then
    return nil, nil
  end
  return fn()
end

--- 摇杆与扳机: 策略拦摇杆时不轮询. 已按下的轴按键 (扳机, 当方向键用的左摇杆) 先松开, 不让它卡在按住.
---@param controller table
local function release_axis_buttons(controller)
  for _, v in pairs(controller.axis_buttons or {}) do
    if v.current ~= "" or v.previous ~= "" then
      local held = v.current ~= "" and v.current or v.previous
      v.previous, v.current = "", ""
      controller:button_release(held)
    end
  end
end

--- 装上输入门. 只装一次.
---@param env {love: table, controller_class: table?}
function M.install(env)
  if installed then
    return
  end
  installed = true
  local lv = env.love
  for _, name in ipairs(Events.NAMES) do
    local original = lv[name]
    lv[name] = function(...)
      return route(name, original, ...)
    end
  end
  if lv.mouse and lv.mouse.getPosition then
    raw_get_position = lv.mouse.getPosition
    lv.mouse.getPosition = get_position
    lv.mouse.getX = function()
      return (select(1, get_position()))
    end
    lv.mouse.getY = function()
      return (select(2, get_position()))
    end
  end
  local class = env.controller_class
  if class and class.update_axis then
    local update_axis = class.update_axis
    class.update_axis = function(self, dt)
      local policy = M.policy()
      if policy and policy.block_axis then
        release_axis_buttons(self)
        return nil
      end
      return update_axis(self, dt)
    end
  end
  sendInfoMessage("Input gate installed", LOGGER)
end

return M
