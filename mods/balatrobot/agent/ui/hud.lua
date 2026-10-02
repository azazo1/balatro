--[[
内置 agent 运行时的右上角: 最上方是状态文字 (请求中, 执行中, 暂停),
下面一条上下文占用条 (不可点), 再下面是暂停/继续, 以及锁操作开关.

- 只在 runner 运行或暂停时显示 (BB_HUD 的 agent 源); 一停就拆掉.
- 锁操作的状态与挡哪些输入在 agent/input.lua. 锁着时仍能点这两颗按钮 (HUD 不受锁影响).
- 运行中也能解锁: 人操作后 agent 作废当前计划, 等人停手再按新状态决定. 下次开始时重新锁上.
]]

local M = {}

---@class BBAgentHudDeps
---@field runner table
---@field hud table bbcore 的 ui/hud.lua
---@field lock table agent/input.lua
local deps

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
  local lock = deps.lock
  return {
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
          return lock.locked() and "可操作" or "锁操作"
        end,
        colour = function()
          return lock.locked() and G.C.ORANGE or G.C.L_BLACK
        end,
        on_click = function()
          lock.toggle()
        end,
      },
    },
  }
end

---@param options BBAgentHudDeps
function M.init(options)
  deps = options
  options.hud.bind("agent", spec)
end

return M
