--[[
BB Replay 入口: 按局录像与写回放文件, 游戏内与命令行回放. 只依赖 bbcore; 装了 balatrobot 时录下 agent 的动作,
agent 停止时结束录像段, 暂停段在剪辑版里剪掉. 加载顺序在 bbcore 与 balatrobot 之后 (priority 1).

- BALATROBOT_RECORD=on (或设置页的开关) 时按局录制完整版与剪辑版视频 (带声音) 和时间线 JSON, 见 record/recorder.lua.
  同时写回放文件 <stem>.replay.json (replay/log.lua), 人手动的操作也换算成回放步骤 (replay/manual.lua).
- 回放: 主菜单 选项 -> 回放 (ui/replay_menu.lua), 或启动时设 BALATROBOT_REPLAY=<回放文件> (命令行, 按退出码结束).
  回放进行时在 bbcore 的 BB_CONTROL 上独占游戏, balatrobot 据此不开端口, 内置 loop 不能开始.

提供的全局: BB_RECORDER, BB_REPLAY, BB_REPLAY_LOG (命令行回放时没有).
]]

local MOD = SMODS.current_mod
local LOGGER = "BB.REPLAY"

if not (BB_CORE and BB_CORE.ready) then
  sendErrorMessage("BB Core is not loaded, BB Replay disabled", LOGGER)
  return
end

assert(SMODS.load_file("migrate.lua"))().run(MOD)

BB_RECORDER = assert(SMODS.load_file("record/recorder.lua"))()

-- 回放文件记录的版本: 打包时的构建版本 (含提交哈希) 与 mod 版本, 回放时不一致会提示.
-- 回放的每一步由 bbcore 的端点执行, 所以带上 bbcore 的版本.
local manifest_ok, manifest = pcall(require, "lovely_shim.manifest")
local GAME_VERSION = manifest_ok and type(manifest) == "table" and manifest.build_version or VERSION
local MOD_VERSION = string.format("%s / core %s / smods %s", MOD.version, tostring(BB_CORE.version), tostring(SMODS.version))
local REPLAY_FORMAT = assert(SMODS.load_file("replay/format.lua"))()
local REPLAY_SNAPSHOT = assert(SMODS.load_file("replay/snapshot.lua"))()
local REPLAY_SESSION = assert(SMODS.load_file("replay/session.lua"))()
local REPLAY_MANUAL = assert(SMODS.load_file("replay/manual.lua"))()
local REPLAY_TUTORIAL = assert(SMODS.load_file("replay/tutorial.lua"))()
REPLAY_SESSION.init({ snapshot = REPLAY_SNAPSHOT })
BB_REPLAY = assert(SMODS.load_file("replay/player.lua"))()
local function replaying()
  return BB_REPLAY.active == true
end

-- 顺序: 回放的 start_run 钩子要在录制之内 (先改好 seeded 再开始录制);
-- 回放文件的钩子在录制之外 (开局前取存档进度); 输入锁在所有输入钩子之外.
BB_REPLAY.init_early({
  dispatcher = BB_DISPATCHER,
  activity = BB_ACTIVITY,
  overlay = BB_OVERLAY,
  gamestate = BB_GAMESTATE,
  recorder = BB_RECORDER,
  toast = BB_TOAST,
  stream = BB_STREAM,
  control = BB_CONTROL,
  animating = BB_OVERLAY.animating,
  format = REPLAY_FORMAT,
  snapshot = REPLAY_SNAPSHOT,
  session = REPLAY_SESSION,
  tutorial = REPLAY_TUTORIAL,
  input_lock = assert(SMODS.load_file("replay/input_lock.lua"))(),
  manual = REPLAY_MANUAL,
  game_version = GAME_VERSION,
  mod_version = MOD_VERSION,
})
BB_RECORDER.init({
  activity = BB_ACTIVITY,
  toast = BB_TOAST,
  animating = BB_OVERLAY.animating,
  mod_path = MOD.path,
  config_enabled = MOD.config.record == true,
  config_keep = MOD.config.record_keep,
  config_quality = {
    height = MOD.config.record_height,
    fps = MOD.config.record_fps,
    bitrate = MOD.config.record_bitrate,
  },
})
-- 流式条在屏幕上时和决策消息一样算作活动, 剪辑版不剪掉.
BB_RECORDER.add_activity_source(function()
  return BB_STREAM.active()
end)
-- 回放文件与录像同名, 只在有录像段时写. 录像可以在运行中才打开, 所以不看启动时的录像开关;
-- 回放的一局不写, 命令行回放在这里排除, 游戏内回放由 replaying 排除.
if not BB_REPLAY.active then
  BB_REPLAY_LOG = assert(SMODS.load_file("replay/log.lua"))()
  BB_REPLAY_LOG.init({
    activity = BB_ACTIVITY,
    recorder = BB_RECORDER,
    overlay = BB_OVERLAY,
    gamestate = BB_GAMESTATE,
    format = REPLAY_FORMAT,
    snapshot = REPLAY_SNAPSHOT,
    game_version = GAME_VERSION,
    mod_version = MOD_VERSION,
    replaying = replaying,
  })
  -- 人手动的操作换算成回放步骤. 按钮函数的钩子装在这里, 回放时 log 不存在, 不装.
  REPLAY_MANUAL.install({ record = BB_REPLAY_LOG.record_manual })
end
-- 本 mod 最后加载, 输入锁包在所有 mod 的输入钩子之外.
BB_REPLAY.init_late()
if BB_REPLAY.active then
  -- 讲解与工具调用记录都是回放的一部分, 不受 balatrobot 设置页开关的影响 (只改内存, 不写回配置).
  BB_TOAST.enabled = true
  BB_TOAST.calls_enabled = true
end

-- 装了 balatrobot 时: agent 停止 (含出错停止) 时立即结束当前录像段; 暂停段在剪辑版里剪掉.
if BB_RUNNER then
  BB_RUNNER.on_stop[#BB_RUNNER.on_stop + 1] = function(reason)
    BB_RECORDER.set_paused(false, "agent_" .. reason)
    BB_RECORDER.end_segment("agent_" .. reason)
  end
  BB_RUNNER.on_state[#BB_RUNNER.on_state + 1] = function(state, previous)
    if state == "paused" then
      BB_RECORDER.set_paused(true, "agent_pause")
    elseif previous == "paused" then
      BB_RECORDER.set_paused(false, "agent_resume")
    end
  end
end

local love_update = love.update
love.update = function(dt) ---@diagnostic disable-line: duplicate-set-field
  love_update(dt)
  BB_REPLAY.update()
  if BB_REPLAY_LOG then
    BB_REPLAY_LOG.update()
    REPLAY_MANUAL.update()
  end
  BB_RECORDER.update()
end

-- 录制关闭时 BB_RECORDER.draw 直接调用原函数. 本 mod 最后加载, 截到的是所有 mod 画完的画面.
local love_draw = love.draw
love.draw = function() ---@diagnostic disable-line: duplicate-set-field
  BB_RECORDER.draw(love_draw)
end

-- 设置页 (录像开关与保留方式), 选项菜单的 "回放" 入口.
local SETTINGS_TAB = assert(SMODS.load_file("ui/settings_tab.lua"))()
SETTINGS_TAB.init({
  mod = MOD,
  recorder = BB_RECORDER,
  replay = BB_REPLAY,
  record_env = os.getenv("BALATROBOT_RECORD"),
  widgets = BB_WIDGETS,
})
MOD.config_tab = SETTINGS_TAB.build
assert(SMODS.load_file("ui/replay_menu.lua"))().init({
  menu = BB_MENU,
  control = BB_CONTROL,
  recorder = BB_RECORDER,
  replay = BB_REPLAY,
  session = REPLAY_SESSION,
  library = assert(SMODS.load_file("replay/library.lua"))(),
  format = REPLAY_FORMAT,
  toast = BB_TOAST,
  stream = BB_STREAM,
  widgets = BB_WIDGETS,
})

sendInfoMessage("BB Replay loaded - version " .. MOD.version, LOGGER)
