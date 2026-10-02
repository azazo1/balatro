--[[
内置 agent 运行时的输入控制 (锁操作), 经 bbcore 的输入门 (BB_INPUT) 生效. 依赖经 init 注入.

- 锁操作: 内置 loop 运行或暂停时默认开着, 丢弃人对游戏的操作. 仍放行:
  - 移动 (看牌, 悬停提示), Esc (开关选项菜单; Android 的返回键也以 escape 送来), F9 (暂停/继续),
  - 手柄的 start (开选项菜单: 手柄点不到右上角 HUD, 从选项 -> Agent 面板里可以解锁或暂停).
  摇杆与扳机不轮询. 人打开菜单 (BB_OVERLAY.menu_open) 时不拦, 否则选项和 Agent 面板也点不了.
  解锁通知与胜利界面不算菜单, 仍然挡住, 由 agent 停留一会儿后自己处理, 不会和人抢着点.
  每次从停止状态开始时重新锁上.
- F9: 观察输入门的按键, 不用 SMODS.Keybind. 后者排在原版 "控制器上锁就返回" 之后, 动画期间按了没反应.
  文字输入框开着时不算.
- 手动操作: 解锁后人在 loop 运行中 (不含暂停) 点了游戏或按了手柄键, 通知 runner, 由 driver 作废按旧状态
  做的计划 (见 driver.manual). 菜单开着时的点击 (选项, 牌组预览) 不算.
]]

local LOGGER = "BB.AGENT.INPUT"

local M = {}

---@class BBAgentInputDeps
---@field runner table agent/runner.lua
---@field input table bbcore 的 BB_INPUT
---@field menu_open fun(): boolean bbcore 的 BB_OVERLAY.menu_open
---@field hotkey fun() F9 的处理 (agent_menu.hotkey)
---@field manual fun() 人手动操作了游戏 (runner.manual_input)
local deps

-- 是否挡住人手动操作.
local lock_on = true

-- 锁着时放行的键与手柄键 (原始键名, 未经 G.button_mapping).
local PASS_KEYS = { escape = true, f9 = true }
local PASS_PAD = { start = true }
-- 这些手柄键开关菜单, 不算对局里的操作.
local MENU_PAD = { start = true, back = true, guide = true }

---@return boolean
function M.locked()
  return lock_on
end

---@param value boolean
function M.set_locked(value)
  value = value and true or false
  if lock_on == value then
    return
  end
  lock_on = value
  sendInfoMessage("Agent input lock " .. (value and "on" or "off"), LOGGER)
end

function M.toggle()
  M.set_locked(not lock_on)
end

--- 锁着时哪些输入交给游戏.
---@param ev table bbcore 的 runtime/input/events.lua 的事件
---@return boolean
function M.pass(ev)
  local kind = ev.kind
  if kind == "move" then
    return true
  end
  if kind == "key_press" or kind == "key_release" then
    return PASS_KEYS[ev.key] == true
  end
  if kind == "pad_press" or kind == "pad_release" then
    return ev.source == "gamepad" and PASS_PAD[ev.button] == true
  end
  return false
end

local POLICY = { pass = M.pass, block_axis = true }

--- 输入门问的策略: 锁着, loop 在运行或暂停, 且人没开菜单时生效.
---@return table?
function M.policy()
  if lock_on and deps.runner.is_busy() and not deps.menu_open() then
    return POLICY
  end
  return nil
end

--- 这一下是不是人在对局里的操作: 指针按下, 或手柄的非菜单键.
---@param ev table
---@return boolean
function M.is_manual(ev)
  if ev.kind == "press" then
    return true
  end
  return ev.kind == "pad_press" and not MENU_PAD[ev.button]
end

---@param ev table
---@param outcome string
local function observe(ev, outcome)
  if outcome == "drop" then
    return
  end
  if ev.kind == "key_press" and ev.key == "f9" and not ev.isrepeat then
    if not (G and G.CONTROLLER and G.CONTROLLER.text_input_hook) then
      deps.hotkey()
    end
    return
  end
  -- 观察者在原版处理之后调用, 但原版只是把按下排进队列, 菜单要到下一帧 update 才打开, 这里看到的仍是按下前的状态.
  if outcome == "game" and M.is_manual(ev) and deps.runner.is_active() and not deps.menu_open() then
    deps.manual()
  end
end

---@param options BBAgentInputDeps
function M.init(options)
  deps = options
  options.input.add_policy("agent", M.policy)
  options.input.observe("agent", observe)
  options.runner.on_state[#options.runner.on_state + 1] = function(_state, previous)
    if previous == "stopped" or previous == "error" then
      M.set_locked(true)
    end
  end
end

return M
