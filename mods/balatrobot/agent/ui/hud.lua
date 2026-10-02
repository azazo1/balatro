--[[
内置 agent 运行时的右上角: 最上方是状态文字 (请求中, 执行中, 暂停),
下面一条上下文占用条 (不可点), 再下面是暂停/继续, 以及是否挡住人手动操作.

- 只在 runner 运行或暂停时显示 (BB_HUD 的 agent 源); 一停就拆掉.
- 挡住操作时仍能点这两颗按钮, 以及 Esc (开菜单) 和 F9.
- 开始一轮时默认挡住; 暂停期间可以解开自己操作, 选择会保持到下次开始.
]]

local M = {}

---@class BBAgentHudDeps
---@field runner table
---@field hud table bbcore 的 ui/hud.lua
local deps

-- 是否挡住人手动操作. 开始时打开, 停止后下次开始再打开.
local lock_on = true

local function overlay_open()
  return G and G.SETTINGS and G.SETTINGS.paused and G.OVERLAY_MENU ~= nil
end

local STATUS = {
  running = { label = "运行中", colour = "PALE_GREEN" },
  requesting = { label = "请求中", colour = "BLUE", pulse = true, pulse_hz = 2.2 },
  acting = { label = "执行中", colour = "GREEN" },
  retry_wait = { label = "重试中", colour = "ORANGE", pulse = true, pulse_hz = 1.1 },
  paused = { label = "暂停", colour = "GOLD" },
}

local function status_info()
  return STATUS[deps.runner.state] or STATUS.running
end

---@return table
local function status_spec()
  return {
    label = function()
      return status_info().label
    end,
    pulse = function()
      return status_info().pulse == true
    end,
    pulse_hz = function()
      return status_info().pulse_hz or 6
    end,
    colour = function()
      return G.C[status_info().colour] or G.C.GREEN
    end,
  }
end

---@return number
local function context_ratio()
  local used, limit = 0, 0
  if deps.runner.context_usage then
    used, limit = deps.runner.context_usage()
  end
  if not limit or limit <= 0 then
    return 0
  end
  local r = (tonumber(used) or 0) / limit
  if r < 0 then
    return 0
  end
  if r > 1 then
    return 1
  end
  return r
end

---@return table
local function meter_spec()
  return {
    fill = context_ratio,
    colour = function()
      local r = context_ratio()
      if r >= 0.95 then
        return G.C.RED
      end
      if r >= 0.8 then
        return G.C.ORANGE
      end
      return G.C.BLUE
    end,
  }
end

---@return table?
local function spec()
  local runner = deps.runner
  if not runner.is_busy() then
    return nil
  end
  return {
    -- 菜单开着时不拦, 否则选项和 Agent 面板也点不了.
    blocking = lock_on and not overlay_open(),
    status = status_spec(),
    meter = meter_spec(),
    buttons = {
      {
        label = "暂停",
        label_fn = function()
          return runner.state == "paused" and "继续" or "暂停"
        end,
        colour = function()
          return runner.state == "paused" and G.C.GOLD or G.C.GREEN
        end,
        on_click = function()
          runner.toggle_pause()
        end,
      },
      {
        label = "锁操作",
        label_fn = function()
          return lock_on and "可操作" or "锁操作"
        end,
        colour = function()
          return lock_on and G.C.ORANGE or G.C.L_BLACK
        end,
        on_click = function()
          lock_on = not lock_on
        end,
      },
    },
  }
end

---@param options BBAgentHudDeps
function M.init(options)
  deps = options
  options.hud.bind("agent", spec)
  options.runner.on_state[#options.runner.on_state + 1] = function(_state, previous)
    if previous == "stopped" or previous == "error" then
      lock_on = true
    end
  end
end

return M
