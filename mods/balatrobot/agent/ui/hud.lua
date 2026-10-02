--[[
内置 agent 运行时的右上角按钮: 暂停/继续, 以及是否挡住人手动操作.

- 只在 runner 运行或暂停时显示 (BB_HUD 的 agent 源).
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

---@return table?
local function spec()
  local runner = deps.runner
  if not runner.is_busy() then
    return nil
  end
  return {
    -- 菜单开着时不拦, 否则选项和 Agent 面板也点不了.
    blocking = lock_on and not overlay_open(),
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
