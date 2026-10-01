--[[
录制时写回放文件 <stem>.replay.json, 与录像同名. 回放见 replay/player.lua.

内容:
- run: 牌组, 赌注, 种子, 是否指定过种子 (seeded), 是否读档开局; 读档时附带存档.
- snapshot: 开局那一刻的存档进度与画面设置, 见 replay/snapshot.lua.
- actions: agent 的每一步操作 (含 notify), 带参数, reason, 开始与完成时间, 成功与否, 状态摘要.
  人手动的操作 (出牌, 购买, 拖动排序, 弹窗上选无尽或回主菜单等, 见 replay/manual.lua)
  换算成同样的步骤, 标 manual = true. 手动步骤没有 "完成" 的时刻, 它的状态摘要在下一步开始时取:
  人点下一步时画面已经停下, 与回放时这一步的接口返回时的状态对应.

旧版本的文件只记了手动操作的次数 (manual_inputs), 没有具体操作, 回放时据此提示结果可能不同.

时间都是开局起的秒数, 与时间线 JSON 的 wall 相同. 写入先写临时文件再 rename.
]]

local json = require("json")

local LOGGER = "BB.AGENT.REPLAY"
local FLUSH_INTERVAL = 3

local M = {}

local deps = {} -- activity, recorder, overlay, gamestate, format, snapshot, game_version, mod_version, replaying
local log = nil -- 当前一局
local unsettled = nil -- 最近一步还没取状态摘要的手动步骤
local pending = nil -- 开局时录像还没开始的一段, 见 M.update 里的补写
local PENDING_LIMIT = 2 -- 等录像段出现的时间上限

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
  -- 不走 love.filesystem 的写包装, 要单独通知 Android 修正权限, 否则文件管理器与 adb 读不到.
  local storage_ok, storage = pcall(require, "android_storage")
  if storage_ok and type(storage) == "table" and storage.fix_path then
    pcall(storage.fix_path, l.path)
  end
  l.dirty = false
  l.last_flush = now()
end

local function elapsed()
  return log and round(now() - log.started) or 0
end

--- 给上一个手动步骤补上状态摘要: 在下一步开始之前调用, 这时是人看着画面决定下一步的时刻.
--- 有弹窗时不比 (与 summarize 相同的规则).
local function settle_manual()
  local action = unsettled
  unsettled = nil
  if not action or not deps.format.comparable(deps.overlay.kind()) then
    return
  end
  local ok, state = pcall(deps.gamestate.get_gamestate)
  if ok and type(state) == "table" then
    action.digest = deps.format.digest(state)
  end
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

--- 记一步人手动的操作. fields 至少有 method, 可以带 params.
---
--- reorder (拖动排序) 可能发生在上一步的动画中途, 那时的状态和回放时上一步完成时不同, 所以它不给
--- 上一步补摘要, 上一步就不比对; 它自己的摘要照常在下一步开始时取.
---@param fields {method: string, params: table?}
function M.record_manual(fields)
  if not log then
    return
  end
  -- menu 的钩子 (Game:main_menu) 运行时这一局已经在拆了, 那时取的状态是空的, 上一步也不比对.
  if fields.method == "reorder" or fields.method == "menu" then
    unsettled = nil
  else
    settle_manual()
  end
  fields.manual = true
  fields.ok = true
  unsettled = add_action(fields)
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
  unsettled = nil
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
---@param tutorial boolean 是否受教程影响
local function begin(resumed_save, snap, tutorial)
  if deps.replaying() then
    -- 回放自己的一局不再写回放文件 (录制仍然照常).
    return
  end
  local session = deps.recorder.current()
  if not session then
    if not deps.recorder.enabled then
      return
    end
    -- 录像段还没开始: 录制是运行中才打开时, 录制器的 start_run 钩子装在这里之外, 它的录像段
    -- 要等这里返回之后才建立. 记下来, 由 M.update 在短时间里补上.
    pending = { resumed_save = resumed_save, snap = snap, tutorial = tutorial, until_at = now() + PENDING_LIMIT }
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
        tutorial = tutorial,
        save = resumed_save,
        start_end = nil,
      },
      snapshot = snap,
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
    settle_manual()
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

  -- 人在胜利界面上点 "无尽模式": 按钮直接调用 exit_overlay_menu, 不经过 agent 接口.
  local exit_overlay_menu = G.FUNCS.exit_overlay_menu
  G.FUNCS.exit_overlay_menu = function(...)
    if log and deps.overlay.kind() == "win" and not (activity.inflight and activity.inflight.method == "endless") then
      M.record_manual({ method = "endless" })
    end
    return exit_overlay_menu(...)
  end

  local start_run = Game.start_run
  function Game:start_run(args) ---@diagnostic disable-line: duplicate-set-field
    finish("restart")
    -- 开局前取存档进度; 读档时 savetext 会在这一局里被改写, 先序列化.
    local snap_ok, snap = pcall(deps.snapshot.capture)
    local resumed_save = args and args.savetext and STR_PACK(args.savetext) or nil
    -- 教程的强制内容在原函数里读取, 之后会被清掉, 先看.
    local tutorial = deps.format.tutorial_settings(G.SETTINGS)
    start_run(self, args)
    if snap_ok then
      begin(resumed_save, snap, tutorial)
    else
      sendWarnMessage("Replay snapshot failed, no replay file for this run: " .. tostring(snap), LOGGER)
    end
  end

  -- 人从局内回主菜单 (游戏结束, 胜利界面, 选项菜单): 记成一步 menu, 回放时同样回去.
  local main_menu = Game.main_menu
  function Game:main_menu(change_context) ---@diagnostic disable-line: duplicate-set-field
    if log and not (activity.inflight and activity.inflight.method == "menu") then
      M.record_manual({ method = "menu" })
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
  if not pending then
    return
  end
  if deps.recorder.current() then
    local waiting = pending
    pending = nil
    begin(waiting.resumed_save, waiting.snap, waiting.tutorial)
  elseif now() > pending.until_at then
    sendWarnMessage("录像没有开始, 这一局不写回放文件", LOGGER)
    pending = nil
  end
end

return M
