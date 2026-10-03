--[[
内置 agent 运行时的右上角: 最上方是状态文字 (请求中, 执行中, 暂停),
下面一条上下文占用条 (不可点), 再下面是暂停, 锁操作, 消息节奏三个开关.
按钮文字显示当前状态 (运行中/已暂停, 已锁定/可操作, 阅读/快速), 点一下切换到另一种.

- 内置 runner 运行或暂停时显示完整一组; 外部模式 (just agent-call) 只显示节奏按钮.
- 锁操作的状态与挡哪些输入在 agent/input.lua. 锁着时仍能点这些按钮 (HUD 不受锁影响).
- 运行中也能解锁: 人操作后 agent 作废当前计划, 等人停手再按新状态决定. 下次开始时重新锁上.
]]

local M = {}

---@class BBAgentHudDeps
---@field runner table
---@field hud table bbcore 的 ui/hud.lua
---@field lock table agent/input.lua
---@field pace table agent/pace.lua
---@field mode table agent/mode.lua 的实例
---@field replaying fun(): boolean
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
      local label = status_info().label
      if deps.runner.backend == "decision" then return "Decision " .. label end
      if deps.runner.backend == "hybrid" then
        local source = deps.runner.request_source == "decision" and "Decision" or "LLM"
        return source .. " " .. label
      end
      return label
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

---@return table
local function pace_button()
  local pace = deps.pace
  return {
    -- 显示当前节奏, 点一下在阅读 / 快速之间切换.
    label = "阅读",
    label_fn = function()
      return pace.label(pace.current())
    end,
    colour = function()
      return pace.current() == "fast" and G.C.BLUE or G.C.GREY
    end,
    on_click = function()
      pace.cycle()
    end,
  }
end

---@return table?
local function spec()
  local runner = deps.runner
  if runner.is_busy() then
    local lock = deps.lock
    return {
      status = status_spec(),
      meter = runner.backend ~= "decision" and meter_spec() or nil,
      buttons = {
        -- 按钮文字是当前状态, 不是点下去要做的事; 点一下切换.
        {
          label = "运行中",
          label_fn = function()
            return runner.state == "paused" and "已暂停" or "运行中"
          end,
          colour = function()
            return runner.state == "paused" and G.C.GOLD or G.C.GREEN
          end,
          on_click = function()
            runner.toggle_pause()
          end,
        },
        {
          label = "已锁定",
          label_fn = function()
            return lock.locked() and "已锁定" or "可操作"
          end,
          colour = function()
            return lock.locked() and G.C.ORANGE or G.C.L_BLACK
          end,
          on_click = function()
            lock.toggle()
          end,
        },
        pace_button(),
      },
    }
  end
  if deps.mode.current == "external" and not deps.replaying() then
    return { buttons = { pace_button() } }
  end
  return nil
end

---@param options BBAgentHudDeps
function M.init(options)
  deps = options
  options.hud.bind("agent", spec)
end

return M
