--[[
agent 模式 (BALATROBOT_ENABLE=1) 的游戏设置. 替代 upstream 的 BB_SETTINGS.setup.

原则: 画面, 开场动画, 声音, vsync, 游戏速度默认沿用存档, 与正常游玩一致.
只有显式要求的项才改, 而且这些改动只在本次运行生效, 不写回存档:

- BALATROBOT_FAST=1: 10 倍速, 动画 60fps, 不限帧率, 关 vsync, 固定 dt.
- BALATROBOT_HEADLESS=1: 与 upstream 相同, 另外跳过开场动画 (没有画面可看).
- BALATROBOT_GAMESPEED / BALATROBOT_FPS_CAP / BALATROBOT_ANIMATION_FPS: 显式设置时覆盖.
- BALATROBOT_AUDIO=1: 强制开声音. 不设置时沿用存档音量 (upstream 默认静音).
- BALATROBOT_RENDER_ON_API / BALATROBOT_NO_SHADERS: 调用 upstream 的实现.
]]

local LOGGER = "BB.AGENT.SETTINGS"

local M = {}

---@type {path: string[], value: any, original: any}[]
local overrides = {}

local function get_path(root, path)
  local node = root
  for i = 1, #path do
    if type(node) ~= "table" then
      return nil
    end
    node = node[path[i]]
  end
  return node
end

local function set_path(root, path, value)
  local node = root
  for i = 1, #path - 1 do
    node[path[i]] = node[path[i]] or {}
    node = node[path[i]]
  end
  node[path[#path]] = value
end

--- 在运行时覆盖 G.SETTINGS 的一个字段, 保存设置时写回原值.
---@param path string[]
---@param value any
local function override(path, value)
  local key = table.concat(path, ".")
  for _, item in ipairs(overrides) do
    -- 同一字段被多次覆盖时只更新目标值, 原值始终是存档里的值.
    if table.concat(item.path, ".") == key then
      item.value = value
      set_path(G.SETTINGS, path, value)
      return
    end
  end
  overrides[#overrides + 1] = { path = path, value = value, original = get_path(G.SETTINGS, path) }
  set_path(G.SETTINGS, path, value)
end

local function env_number(name)
  local raw = os.getenv(name)
  return raw and tonumber(raw) or nil
end

--- 保存设置时交给存档线程的是副本: 仍等于覆盖值的字段还原成原值.
--- 字段已被 user 在游戏里改过时, 保留新值, 并不再追踪这项覆盖.
local function install_save_filter()
  local save_settings = Game.save_settings
  function Game:save_settings() ---@diagnostic disable-line: duplicate-set-field
    save_settings(self)
    if #overrides == 0 then
      return
    end
    local copy = copy_table(G.SETTINGS)
    local kept = {}
    for _, item in ipairs(overrides) do
      if get_path(G.SETTINGS, item.path) == item.value then
        set_path(copy, item.path, item.original)
        kept[#kept + 1] = item
      end
    end
    overrides = kept
    G.ARGS.save_settings = copy
  end
end

function M.setup()
  local settings = BB_SETTINGS
  local configure = settings.configure

  -- 教程会拦住 agent 的操作, 与 upstream 一样跳过. 这是正常游玩也会写入的进度.
  -- 全新存档里 tutorial_progress 要等第一帧的 tutorial_controller 才处理, 这里提前做它跳过教程时的处理.
  G.F_SKIP_TUTORIAL = true
  G.SETTINGS.tutorial_complete = true
  G.SETTINGS.tutorial_progress = nil

  if settings.headless and settings.render_on_api then
    sendWarnMessage("Headless mode and render on API mode are mutually exclusive. Disabling headless", LOGGER)
    settings.headless = false
  end

  -- upstream 的固定 dt 只在需要确定步长时使用. 正常速度用真实 dt, 高刷屏上也不会变快.
  if settings.headless or settings.fast then
    configure.love_update()
  end

  if settings.headless then
    configure.headless()
    override({ "skip_splash" }, "Yes")
  end
  if settings.render_on_api then
    configure.render_on_api()
  end
  if settings.no_shaders then
    configure.no_shaders()
  end

  if settings.fast then
    G.FPS_CAP = nil -- love.run 按 500 处理
    G.ANIMATION_FPS = 60
    love.window.setVSync(0)
    override({ "GAMESPEED" }, 10)
  end

  local gamespeed = env_number("BALATROBOT_GAMESPEED")
  if gamespeed then
    override({ "GAMESPEED" }, gamespeed)
  end
  local fps_cap = env_number("BALATROBOT_FPS_CAP")
  if fps_cap then
    G.FPS_CAP = fps_cap
  end
  local animation_fps = env_number("BALATROBOT_ANIMATION_FPS")
  if animation_fps then
    G.ANIMATION_FPS = animation_fps
  end

  if settings.audio then
    override({ "SOUND", "volume" }, 50)
    override({ "SOUND", "music_volume" }, 100)
    override({ "SOUND", "game_sounds_volume" }, 100)
    G.F_MUTE = false
  end

  install_save_filter()

  local parts = {}
  for _, key in ipairs({ "fast", "headless", "render_on_api", "no_shaders", "audio" }) do
    if settings[key] then
      parts[#parts + 1] = key
    end
  end
  sendInfoMessage(
    "Agent settings applied: " .. (#parts > 0 and table.concat(parts, ", ") or "save settings kept"),
    LOGGER
  )
end

return M
