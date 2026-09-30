--[[
迁移: 每次加载都执行, 重复执行无副作用.

1. 游戏设置: 早期版本在 agent 模式下调用 upstream 的 BB_SETTINGS.setup, 把跳过开场动画,
   关 CRT/bloom/阴影, 静音, reduced_motion, 4 倍速, 关 vsync 写进了存档.
   原版 1.0.1n 没有 skip_splash 的界面入口, 值为 "Yes" 只可能来自这里, 以此识别并恢复原版默认值.
2. mod 配置: 记录版本号, 供以后不兼容的配置变更迁移.
]]

local LOGGER = "BB.AGENT.MIGRATE"
local CONFIG_VERSION = 1

local M = {}

-- 与 game/globals.lua 中 G.SETTINGS 的默认值一致.
local function restore_polluted_settings()
  local s = G.SETTINGS
  if s.skip_splash ~= "Yes" then
    return
  end
  s.skip_splash = "No"
  s.GRAPHICS = s.GRAPHICS or {}
  s.GRAPHICS.texture_scaling = 2
  s.GRAPHICS.shadows = "On"
  s.GRAPHICS.crt = 70
  s.GRAPHICS.bloom = 1
  s.screenshake = true
  s.reduced_motion = nil
  s.SOUND = s.SOUND or {}
  s.SOUND.volume = 50
  s.SOUND.music_volume = 100
  s.SOUND.game_sounds_volume = 100
  s.GAMESPEED = 1
  s.WINDOW = s.WINDOW or {}
  s.WINDOW.vsync = 1
  love.window.setVSync(1)
  G:save_settings()
  sendInfoMessage(
    "Restored settings changed by earlier agent runs: splash, graphics, sound, reduced motion, game speed, vsync",
    LOGGER
  )
end

---@param mod table SMODS mod 对象
local function migrate_config(mod)
  local config = mod.config
  local version = config.version or 0
  if version >= CONFIG_VERSION then
    return
  end
  -- 0 -> 1: 新增 show_messages. smods 加载时会把 config.lua 的默认值合并进旧配置, 这里只记录版本.
  -- 版本号不放进 config.lua 的默认值, 否则旧配置合并后也带上版本号, 无法识别.
  config.version = CONFIG_VERSION
  SMODS.save_mod_config(mod)
  sendInfoMessage("Mod config migrated from version " .. version .. " to " .. CONFIG_VERSION, LOGGER)
end

---@param mod table SMODS mod 对象
function M.run(mod)
  restore_polluted_settings()
  migrate_config(mod)
end

return M
