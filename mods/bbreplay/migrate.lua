--[[
bbreplay 的配置迁移: 每次加载都执行, 按版本号逐步迁移, 已是最新版本时不做事.

0 -> 1: 录像设置 (record, record_keep) 原来在 balatrobot 的配置 (config/balatrobot.jkr) 里. 第一次加载时
        搬到这里, 再从 balatrobot 的配置里删掉. balatrobot 先加载 (priority 0), 这时它的配置已经读好.
1 -> 2: 原来的 record 同时录两者, 用它初始化 record_video 与 record_replay, 再移除旧字段.
]]

local LOGGER = "BB.REPLAY.MIGRATE"
local CONFIG_VERSION = 2

local M = {}

local KEEP_VALUES = { skip = true, keep = true }

--- 从 balatrobot 的配置里取出旧的录像设置. 没装 balatrobot 或它没存过这两项时不做事.
---@param config table bbreplay 的配置
---@return boolean moved
local function take_from_balatrobot(config)
  local bot = SMODS.Mods and SMODS.Mods.balatrobot
  local old = bot and bot.config
  if type(old) ~= "table" or (old.record == nil and old.record_keep == nil) then
    return false
  end
  if type(old.record) == "boolean" then
    config.record = old.record
  end
  if KEEP_VALUES[old.record_keep] then
    config.record_keep = old.record_keep
  end
  old.record, old.record_keep = nil, nil
  SMODS.save_mod_config(bot)
  return true
end

---@param mod table SMODS mod 对象
function M.run(mod)
  local config = mod.config
  local version = config.version or 0
  if version >= CONFIG_VERSION then
    return
  end
  if version < 1 and take_from_balatrobot(config) then
    sendInfoMessage("Recording settings moved from balatrobot config", LOGGER)
  end
  if version < 2 then
    if type(config.record) == "boolean" then
      config.record_video = config.record
      config.record_replay = config.record
    end
    config.record = nil
  end
  config.version = CONFIG_VERSION
  SMODS.save_mod_config(mod)
  sendInfoMessage("Mod config migrated from version " .. version .. " to " .. CONFIG_VERSION, LOGGER)
end

return M
