--[[
开局那一刻的存档进度, 回放时恢复到临时存档里.

商店, 卡包的候选池按 "已解锁 / 已发现" 过滤 (functions/common_events.lua get_current_pool),
局中的解锁判断还要看 profile 里的累计数据. 两者不一致, 同一个种子也会抽出不同的牌.

- uda: 每张卡的解锁 (u), 已发现 (d), 已提示 (a), 与 Game:save_progress 写进 meta.jkr 的格式相同.
- profile: G.PROFILES[当前档位] 整张表, 用 STR_PACK 序列化.
- unlock_notify: 待显示的解锁通知 (开局或回主菜单时弹出), 按原样恢复, 回放时同样弹出.
- settings: 影响画面的设置. 语言不在运行中切换, 只在不一致时提示.

都从内存里取: 游戏写存档在后台线程里进行, 磁盘上的文件可能还没写到最新.
]]

local M = {}

local SETTING_KEYS = {
  "GAMESPEED",
  "screenshake",
  "reduced_motion",
  "colourblind_option",
  "SOUND",
  "GRAPHICS",
}

local function pools()
  return { G.P_CENTERS, G.P_BLINDS, G.P_TAGS, G.P_SEALS }
end

---@return table
function M.capture()
  local uda = {}
  for _, pool in ipairs(pools()) do
    for key, v in pairs(pool) do
      uda[key] = (v.unlocked and "u" or "") .. (v.discovered and "d" or "") .. (v.alerted and "a" or "")
    end
  end

  local profile_num = G.SETTINGS.profile or 1
  local settings = {}
  for _, key in ipairs(SETTING_KEYS) do
    local value = G.SETTINGS[key]
    if type(value) == "table" then
      settings[key] = STR_PACK(value)
    else
      settings[key] = value
    end
  end

  return {
    uda = uda,
    profile = STR_PACK(G.PROFILES[profile_num] or {}),
    unlock_notify = get_compressed(profile_num .. "/unlock_notify.jkr") or "",
    settings = settings,
    language = G.SETTINGS.language,
  }
end

--- 恢复到当前档位. 只在回放的临时存档里调用.
---@param snap table
---@return string[] warnings
function M.apply(snap)
  local warnings = {}
  local profile_num = G.SETTINGS.profile or 1

  -- 解锁与发现. 没有 unlocked 字段的对象 (如蜡封) 默认视为已解锁, 不能写成 false.
  for _, pool in ipairs(pools()) do
    for key, v in pairs(pool) do
      local flags = snap.uda[key]
      if flags then
        local unlocked = flags:find("u", 1, true) ~= nil
        if unlocked or type(v.unlocked) == "boolean" then
          v.unlocked = unlocked
        end
        v.discovered = flags:find("d", 1, true) ~= nil
        v.alerted = flags:find("a", 1, true) ~= nil
      end
    end
  end
  if set_discover_tallies then
    set_discover_tallies()
  end

  -- profile 整张替换
  local profile = G.PROFILES[profile_num]
  local restored = STR_UNPACK(snap.profile)
  for k in pairs(profile) do
    profile[k] = nil
  end
  for k, v in pairs(restored) do
    profile[k] = v
  end

  -- 待显示的解锁通知, 与原局开局时相同
  love.filesystem.createDirectory(tostring(profile_num))
  local notify_path = profile_num .. "/unlock_notify.jkr"
  if snap.unlock_notify ~= "" then
    compress_and_save(notify_path, snap.unlock_notify)
  else
    love.filesystem.remove(notify_path)
  end

  for key, value in pairs(snap.settings or {}) do
    if type(value) == "string" and value:sub(1, 6) == "return" then
      G.SETTINGS[key] = STR_UNPACK(value)
    else
      G.SETTINGS[key] = value
    end
  end
  if snap.language and snap.language ~= G.SETTINGS.language then
    warnings[#warnings + 1] = string.format("原局语言为 %s, 回放为 %s, 界面文字会不同", snap.language, G.SETTINGS.language)
  end

  G:save_progress()
  G:save_settings()
  return warnings
end

return M
