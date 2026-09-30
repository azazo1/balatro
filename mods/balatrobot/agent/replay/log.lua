--[[
录制时写回放文件 <stem>.replay.json, 与录像同名. 回放见 agent/replay/player.lua.

内容:
- run: 牌组, 赌注, 种子, 是否指定过种子 (seeded), 是否读档开局; 读档时附带存档.
- snapshot: 开局那一刻的存档进度与画面设置, 见 agent/replay/snapshot.lua.
- actions: agent 的每一步操作 (含 notify), 带参数, reason, 开始与完成时间, 成功与否, 状态摘要.
  人在弹窗上手动选的 "无尽模式" 或 "主菜单" 也记成一步 (manual = true), 回放时照做.
- manual_inputs: 这局里手动操作的次数, 回放时据此提示结果可能不同.

时间都是开局起的秒数, 与时间线 JSON 的 wall 相同. 写入先写临时文件再 rename.
]]

local json = require("json")

local LOGGER = "BB.AGENT.REPLAY"
local FLUSH_INTERVAL = 3

local M = {}

local deps = {} -- activity, recorder, overlay, gamestate, format, snapshot, game_version, mod_version
local log = nil -- 当前一局

local function now()
  return love.timer.getTime()
end

local function round(x)
  return math.floor(x * 1000 + 0.5) / 1000
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return out
end

local function flush(force)
  local l = log
  if not l or (not l.dirty and not force) then
    return
  end
  if not force and now() - l.last_flush < FLUSH_INTERVAL then
    return
  end
  local ok, encoded = pcall(json.encode, l.data)
  if not ok then
    sendWarnMessage("Failed to encode replay file: " .. tostring(encoded), LOGGER)
    return
  end
  local tmp = l.path .. ".tmp"
  local file, err = io.open(tmp, "wb")
  if not file then
    sendWarnMessage("Failed to write replay file: " .. tostring(err), LOGGER)
    return
  end
  file:write(encoded)
  file:close()
  os.rename(tmp, l.path)
  l.dirty = false
  l.last_flush = now()
end

local function elapsed()
  return log and round(now() - log.started) or 0
end

--- 追加一步操作.
---@param fields table
---@return table
local function add_action(fields)
  fields.wall = fields.wall or elapsed()
  table.insert(log.data.actions, fields)
  log.dirty = true
  return fields
end

--- 这一步完成后的状态摘要. 响应不是完整状态 (例如 notify 只返回 success) 时不记.
---@param response any
---@return string? digest
---@return string? overlay
local function summarize(response)
  if type(response) ~= "table" or response.state == nil then
    return nil, nil
  end
  local overlay = response.overlay
  if not deps.format.comparable(overlay) then
    return nil, overlay
  end
  return deps.format.digest(response), overlay
end

local function finish(reason)
  if not log then
    return
  end
  log.data.result = { reason = reason, won = G.GAME and G.GAME.won or false }
  log.dirty = true
  flush(true)
  sendInfoMessage(string.format("Replay file saved: %s (%d actions)", log.path, #log.data.actions), LOGGER)
  log = nil
end

---@param resumed_save string? 读档开局时序列化的存档
---@param snap table 开局前取的存档进度
local function begin(resumed_save, snap)
  local session = deps.recorder.current()
  if not session then
    return
  end
  local game = G.GAME or {}
  local deck_key = game.selected_back and game.selected_back.effect and game.selected_back.effect.center
    and game.selected_back.effect.center.key
  log = {
    path = session.base .. ".replay.json",
    started = session.started,
    last_flush = -math.huge,
    dirty = true,
    open = nil,
    data = {
      version = deps.format.VERSION,
      game_version = deps.game_version,
      mod_version = deps.mod_version,
      recorded_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      source = session.stem,
      run = {
        deck = deps.format.deck_enum(deck_key),
        deck_key = deck_key,
        stake = deps.format.stake_enum(game.stake),
        seed = game.pseudorandom and game.pseudorandom.seed or nil,
        seeded = game.seeded or false,
        challenge = game.challenge,
        resumed = resumed_save ~= nil,
        save = resumed_save,
        start_end = nil,
      },
      snapshot = snap,
      manual_inputs = 0,
      actions = {},
    },
  }
  flush(true)
end

---@param options table
function M.init(options)
  deps = options
  local activity = deps.activity
  local format = deps.format

  activity.on("request", function(method, params, reason)
    if not log or not format.recorded(method) then
      return
    end
    log.open = add_action({ method = method, params = next(params) and copy(params) or nil, reason = reason })
  end)

  activity.on("response", function(method, ok, message, response)
    if not log then
      return
    end
    if (method == "start" or method == "load") and not log.data.run.start_end then
      log.data.run.start_end = elapsed()
      log.dirty = true
      return
    end
    local action = log.open
    if not action or action.method ~= method then
      return
    end
    log.open = nil
    action.wall_end = elapsed()
    action.ok = ok
    action.error = message
    if ok then
      action.digest, action.overlay = summarize(response)
    end
    log.dirty = true
  end)

  -- 手动输入计数. 装在录制的输入钩子之外; 回放时输入被锁, 这里不会被调用.
  for _, name in ipairs({ "mousepressed", "keypressed", "gamepadpressed", "touchpressed" }) do
    local original = love[name]
    love[name] = function(...)
      if log then
        log.data.manual_inputs = log.data.manual_inputs + 1
        log.dirty = true
      end
      if original then
        return original(...)
      end
    end
  end

  -- 人在胜利界面上点 "无尽模式": 按钮直接调用 exit_overlay_menu, 不经过 agent 接口.
  local exit_overlay_menu = G.FUNCS.exit_overlay_menu
  G.FUNCS.exit_overlay_menu = function(...)
    if log and deps.overlay.kind() == "win" and not (activity.inflight and activity.inflight.method == "endless") then
      add_action({ method = "endless", manual = true, ok = true })
    end
    return exit_overlay_menu(...)
  end

  local start_run = Game.start_run
  function Game:start_run(args) ---@diagnostic disable-line: duplicate-set-field
    finish("restart")
    -- 开局前取存档进度; 读档时 savetext 会在这一局里被改写, 先序列化.
    local snap_ok, snap = pcall(deps.snapshot.capture)
    local resumed_save = args and args.savetext and STR_PACK(args.savetext) or nil
    start_run(self, args)
    if snap_ok then
      begin(resumed_save, snap)
    else
      sendWarnMessage("Replay snapshot failed, no replay file for this run: " .. tostring(snap), LOGGER)
    end
  end

  -- 人从局内回主菜单 (游戏结束, 胜利界面, 选项菜单): 记成一步 menu, 回放时同样回去.
  local main_menu = Game.main_menu
  function Game:main_menu(change_context) ---@diagnostic disable-line: duplicate-set-field
    if log and not (activity.inflight and activity.inflight.method == "menu") then
      add_action({ method = "menu", manual = true, ok = true })
    end
    finish("menu")
    return main_menu(self, change_context)
  end

  local quit = love.quit
  love.quit = function(...) ---@diagnostic disable-line: duplicate-set-field
    finish("quit")
    if quit then
      return quit(...)
    end
  end

  sendInfoMessage("Replay files enabled, written next to each recording", LOGGER)
end

function M.update()
  flush(false)
end

return M
