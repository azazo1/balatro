--[[
BalatroBot 入口, 由本仓库在 upstream v1.5.2 的基础上改写. 本仓库新增的代码在 agent/ 下.

与 upstream 的区别:
- agent 模式三选一 (agent/mode.lua): 关闭 / 外部 (HTTP 接口) / 内置 (游戏内 loop, 见 agent/runner.lua).
  默认关闭, 不开端口. 游戏内 模组 -> BalatroBot -> 配置 切换, 或启动时设 BALATROBOT_ENABLE=1 锁定为外部.
- 切换模式只启停 HTTP 服务, 不改游戏设置. BALATROBOT_ENABLE=1 时由 agent/settings.lua
  处理 BALATROBOT_* 环境变量: 画面, 开场动画, 声音默认沿用存档, 显式要求的改动不写回存档.
- 模式可在运行中切换, 保存在存档目录的 config/balatrobot.jkr. 设置页见 agent/ui/settings_tab.lua.
- 内置模式: ESC 菜单的 Agent 按钮与面板, F9 暂停/继续 (agent/ui/agent_menu.lua), 顶部流式条 (agent/ui/stream_bar.lua).
- 请求可带 reason, 另有 notify 方法, 在游戏内以原版通知的样式显示 agent 的决策消息.
- 弹窗 (解锁通知, 胜利界面等) 打开时拦截操作, 等待中的请求先返回, 见 agent/overlay.lua.
  解锁通知用 continue 关掉, 胜利后用 endless 进入无尽模式.
- BALATROBOT_RECORD=on 时按局录制完整版与剪辑版视频 (带声音) 和时间线 JSON, 见 agent/record/recorder.lua.
  同时写回放文件 <stem>.replay.json; BALATROBOT_REPLAY=<回放文件> 时按它重玩一局, 见 agent/replay/.
]]

local MOD = SMODS.current_mod
local LOGGER = "BB.BALATROBOT"

assert(SMODS.load_file("src/lua/settings.lua"))() -- define BB_SETTINGS

-- 修复早期版本写坏的存档设置, 迁移 mod 配置. 两种开启方式都执行.
assert(SMODS.load_file("agent/migrate.lua"))().run(MOD)

local env_enabled = os.getenv("BALATROBOT_ENABLE") == "1"
if env_enabled then
  assert(SMODS.load_file("agent/settings.lua"))().setup()
end

-- Endpoints for the BalatroBot API
BB_ENDPOINTS = {
  "src/lua/endpoints/health.lua",
  "src/lua/endpoints/gamestate.lua",
  "src/lua/endpoints/save.lua",
  "src/lua/endpoints/load.lua",
  "src/lua/endpoints/screenshot.lua",
  "src/lua/endpoints/set.lua",
  "src/lua/endpoints/add.lua",
  "src/lua/endpoints/menu.lua",
  "src/lua/endpoints/start.lua",
  "src/lua/endpoints/skip.lua",
  "src/lua/endpoints/select.lua",
  "src/lua/endpoints/play.lua",
  "src/lua/endpoints/discard.lua",
  "src/lua/endpoints/cash_out.lua",
  "src/lua/endpoints/next_round.lua",
  "src/lua/endpoints/reroll.lua",
  "src/lua/endpoints/buy.lua",
  "src/lua/endpoints/pack.lua",
  "src/lua/endpoints/rearrange.lua",
  "src/lua/endpoints/sell.lua",
  "src/lua/endpoints/use.lua",
  "agent/endpoints/notify.lua",
  "agent/endpoints/endless.lua",
  "agent/endpoints/continue.lua",
  "agent/endpoints/docs_index.lua",
  "agent/endpoints/docs_read.lua",
  "agent/endpoints/docs_search.lua",
  "agent/endpoints/lookup.lua",
  -- If debug mode is enabled, debugger.lua will load test endpoints
}

-- 调试端点依赖 DebugPlus, 只在环境变量方式开启时生效, 与 upstream 一致.
if env_enabled and BB_SETTINGS.debug then
  assert(SMODS.load_file("src/lua/utils/debugger.lua"))() -- define BB_DEBUG
  BB_DEBUG.setup()
end

assert(SMODS.load_file("src/lua/core/server.lua"))() -- define BB_SERVER
assert(SMODS.load_file("src/lua/core/dispatcher.lua"))() -- define BB_DISPATCHER
BB_GAMESTATE = assert(SMODS.load_file("src/lua/utils/gamestate.lua"))()
assert(SMODS.load_file("src/lua/utils/errors.lua"))()

BB_OVERLAY = assert(SMODS.load_file("agent/overlay.lua"))()
BB_ACTIVITY = assert(SMODS.load_file("agent/activity.lua"))()
local OPENRPC = assert(SMODS.load_file("agent/openrpc.lua"))()
BB_TOAST = assert(SMODS.load_file("agent/toast.lua"))()
BB_STREAM = assert(SMODS.load_file("agent/ui/stream_bar.lua"))()
BB_STREAM.init({ toast = BB_TOAST })
BB_RECORDER = assert(SMODS.load_file("agent/record/recorder.lua"))()

-- 端点只能注册一次, 与服务的启停无关.
if not BB_DISPATCHER.init(BB_SERVER, BB_ENDPOINTS) then
  sendErrorMessage("Dispatcher init failed, agent API unavailable", LOGGER)
  return
end
-- 先装弹窗拦截, 再装活动追踪: 被拦下的请求也会作为失败的操作记进时间线.
BB_OVERLAY.install(BB_DISPATCHER, BB_GAMESTATE)
BB_ACTIVITY.install(BB_DISPATCHER, BB_SERVER)

BB_TOAST.enabled = MOD.config.show_messages ~= false
-- 请求附带 reason 时, 通知标题用操作的中文名, 观众不用看懂方法名.
local ACTION_TITLES = {
  start = "开局",
  menu = "回主菜单",
  select = "选择盲注",
  skip = "跳过盲注",
  play = "出牌",
  discard = "弃牌",
  cash_out = "结算",
  next_round = "离开商店",
  reroll = "刷新商店",
  buy = "购买",
  sell = "出售",
  pack = "补充包",
  use = "使用",
  rearrange = "调整顺序",
  endless = "无尽模式",
  continue = "继续",
}
BB_ACTIVITY.on("message", function(title, text, duration, source)
  -- notify 自己负责显示, 这样它能等消息读完再返回.
  if source == "reason" then
    BB_TOAST.push(ACTION_TITLES[title] or title, text, duration)
  end
end)

-- 回放文件记录的版本: 打包时的构建版本 (含提交哈希) 与 mod 版本, 回放时不一致会提示.
local manifest_ok, manifest = pcall(require, "lovely_shim.manifest")
local GAME_VERSION = manifest_ok and type(manifest) == "table" and manifest.build_version or VERSION
local MOD_VERSION = MOD.version .. " / smods " .. tostring(SMODS.version)
local REPLAY_FORMAT = assert(SMODS.load_file("agent/replay/format.lua"))()
local REPLAY_SNAPSHOT = assert(SMODS.load_file("agent/replay/snapshot.lua"))()
local REPLAY_SESSION = assert(SMODS.load_file("agent/replay/session.lua"))()
BB_REPLAY = assert(SMODS.load_file("agent/replay/player.lua"))()
BB_REPLAY_LIBRARY = assert(SMODS.load_file("agent/replay/library.lua"))()
REPLAY_SESSION.init({ recorder = BB_RECORDER, toast = BB_TOAST, snapshot = REPLAY_SNAPSHOT })

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
  format = REPLAY_FORMAT,
  snapshot = REPLAY_SNAPSHOT,
  session = REPLAY_SESSION,
  input_lock = assert(SMODS.load_file("agent/replay/input_lock.lua"))(),
  game_version = GAME_VERSION,
  mod_version = MOD_VERSION,
})
BB_RECORDER.init({
  activity = BB_ACTIVITY,
  toast = BB_TOAST,
  mod_path = MOD.path,
  config_enabled = MOD.config.record == true,
  config_keep = MOD.config.record_keep,
})
-- 流式条在屏幕上时和决策消息一样算作活动, 剪辑版不剪掉.
BB_RECORDER.add_activity_source(function()
  return BB_STREAM.active()
end)
-- 回放文件与录像同名, 只在录制时写; 回放自己的一局不写回放文件 (录制器运行中才打开时, 由 log.lua 补上).
if not BB_REPLAY.active then
  BB_REPLAY_LOG = assert(SMODS.load_file("agent/replay/log.lua"))()
  BB_REPLAY_LOG.init({
    activity = BB_ACTIVITY,
    recorder = BB_RECORDER,
    overlay = BB_OVERLAY,
    format = REPLAY_FORMAT,
    snapshot = REPLAY_SNAPSHOT,
    game_version = GAME_VERSION,
    mod_version = MOD_VERSION,
    replaying = function()
      return BB_REPLAY.active == true
    end,
  })
end
BB_REPLAY.init_late()
if BB_REPLAY.active then
  -- 讲解是回放的一部分, 不受设置页 "显示 agent 消息" 的影响 (只改内存, 不写回配置).
  BB_TOAST.enabled = true
end

BB_AGENT = {
  address = string.format("http://%s:%d", BB_SERVER.host, BB_SERVER.port),
  status = "off",
}

--- 启停 HTTP 服务. 返回服务最终是否在监听.
---@param on boolean
---@return boolean
function BB_AGENT.set_enabled(on)
  if on then
    if BB_SERVER.server_socket then
      return true
    end
    -- server.init 通过 SMODS.current_mod 定位 openrpc.json, 从 UI 回调进入时它不是本 mod.
    local previous = SMODS.current_mod
    SMODS.current_mod = MOD
    local ok, started = pcall(BB_SERVER.init)
    SMODS.current_mod = previous
    if ok and started then
      BB_SERVER.openrpc_spec = OPENRPC.extend(BB_SERVER.openrpc_spec, BB_ACTIVITY.PASSIVE)
      BB_AGENT.status = "listening"
      sendInfoMessage("Agent API listening on " .. BB_AGENT.address, LOGGER)
      return true
    end
    BB_AGENT.status = "bind failed"
    sendErrorMessage("Agent API failed to start: " .. tostring(ok and "bind failed" or started), LOGGER)
    return false
  end
  local was_listening = BB_SERVER.server_socket ~= nil
  BB_SERVER.close()
  BB_AGENT.status = "off"
  if was_listening then
    sendInfoMessage("Agent API stopped", LOGGER)
  end
  return false
end

-- agent 模式. BALATROBOT_ENABLE=1 锁定为外部; 回放时不监听.
local MODE = assert(SMODS.load_file("agent/mode.lua"))()
BB_RUNNER = assert(SMODS.load_file("agent/runner.lua"))()
BB_MODE = MODE.new({
  initial = MOD.config.mode,
  env_locked = env_enabled,
  replaying = function()
    return BB_REPLAY.active == true
  end,
  runner_busy = function()
    return BB_RUNNER.is_busy()
  end,
  set_listening = function(on, reason)
    if reason == "replaying" then
      BB_AGENT.set_enabled(false)
      BB_AGENT.status = "off (replaying)"
      return
    end
    BB_AGENT.set_enabled(on)
  end,
  persist = function(mode)
    MOD.config.mode = mode
    SMODS.save_mod_config(MOD)
  end,
  log = function(text)
    sendInfoMessage(text, LOGGER)
  end,
})

local LOG_FUNCS = { debug = sendDebugMessage, info = sendInfoMessage, warn = sendWarnMessage, error = sendErrorMessage }
BB_RUNNER.init({
  stream = BB_STREAM,
  can_start = function()
    if not BB_MODE.is_builtin() then
      return false, "当前不是内置模式"
    end
    if BB_REPLAY.active then
      return false, "回放进行中"
    end
    return true
  end,
  demo_enabled = function()
    return MOD.config.demo_stream == true
  end,
  demo_driver = assert(SMODS.load_file("agent/demo_driver.lua"))(),
  token_limit = function()
    return tonumber(MOD.config.token_limit) or 0
  end,
  log = function(level, text)
    (LOG_FUNCS[level] or sendInfoMessage)(text, "BB.AGENT.RUNNER")
  end,
})
-- 录像: 停止 (含出错停止) 时立即结束当前录像段; 暂停段在剪辑版里剪掉.
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

-- 内置 agent 的真实 driver: 模型客户端, 进程内调用端点, 主循环. 出错时保留演示 driver 可用, 不影响其他功能.
do
  local ok, err = pcall(function()
    BB_BUILTIN = assert(SMODS.load_file("agent/loop/builtin.lua"))()
    BB_BUILTIN.install({
      mod = MOD,
      runner = BB_RUNNER,
      stream = BB_STREAM,
      dispatcher = BB_DISPATCHER,
      server = BB_SERVER,
      gamestate = BB_GAMESTATE,
    })
  end)
  if not ok then
    sendErrorMessage("Builtin agent unavailable: " .. tostring(err), LOGGER)
  end
end

-- 未监听时 BB_SERVER.update 直接返回, 关闭状态下几乎没有开销.
local love_update = love.update
love.update = function(dt) ---@diagnostic disable-line: duplicate-set-field
  BB_GAMESTATE.check_game_over()
  love_update(dt)
  BB_SERVER.update(BB_DISPATCHER)
  BB_OVERLAY.update()
  BB_REPLAY.update()
  if BB_REPLAY_LOG then
    BB_REPLAY_LOG.update()
  end
  -- fast/headless 模式下传进来的 dt 是固定步长, 通知停留时间按墙钟算.
  local wall_dt = love.timer.getDelta()
  BB_TOAST.update(wall_dt)
  -- 内置 loop 在游戏 update 之后推进; 菜单打开 (游戏暂停) 时也调用, 由 driver 自己看 overlay 决定是否执行动作.
  BB_RUNNER.update(wall_dt)
  BB_STREAM.update(wall_dt)
  BB_RECORDER.update()
end

-- 录制关闭时 BB_RECORDER.draw 直接调用原函数.
local love_draw = love.draw
love.draw = function() ---@diagnostic disable-line: duplicate-set-field
  BB_RECORDER.draw(love_draw)
end

-- 设置页, ESC 菜单的 Agent 按钮与面板, F9.
local WIDGETS = assert(SMODS.load_file("agent/ui/widgets.lua"))()
WIDGETS.init({ toast = BB_TOAST })
local SETTINGS_TAB = assert(SMODS.load_file("agent/ui/settings_tab.lua"))()
SETTINGS_TAB.init({
  mod = MOD,
  modes = MODE,
  mode = BB_MODE,
  runner = BB_RUNNER,
  toast = BB_TOAST,
  agent = BB_AGENT,
  recorder = BB_RECORDER,
  replay = BB_REPLAY,
  record_env = os.getenv("BALATROBOT_RECORD"),
  widgets = WIDGETS,
})
MOD.config_tab = SETTINGS_TAB.build
-- lovely/agent_menu.toml 在 create_UIBox_options 里调用 BB_AGENT_MENU.button().
BB_AGENT_MENU = assert(SMODS.load_file("agent/ui/agent_menu.lua"))()
BB_AGENT_MENU.init({
  mod = MOD,
  mode = BB_MODE,
  runner = BB_RUNNER,
  stream = BB_STREAM,
  toast = BB_TOAST,
  widgets = WIDGETS,
})
-- 主菜单 选项 -> 回放: 列表, 确认页, 存档隔离与结束收尾.
BB_REPLAY_MENU = assert(SMODS.load_file("agent/ui/replay_menu.lua"))()
BB_REPLAY_MENU.init({
  mod = MOD,
  agent_menu = BB_AGENT_MENU,
  runner = BB_RUNNER,
  mode = BB_MODE,
  recorder = BB_RECORDER,
  replay = BB_REPLAY,
  session = REPLAY_SESSION,
  library = BB_REPLAY_LIBRARY,
  snapshot = REPLAY_SNAPSHOT,
  format = REPLAY_FORMAT,
  toast = BB_TOAST,
  stream = BB_STREAM,
  widgets = WIDGETS,
})

-- 按模式启停 HTTP 服务. 回放时不开端口, 只有回放驱动在操作游戏.
if BB_REPLAY.active then
  sendInfoMessage("Replay mode: agent API not started", LOGGER)
end
BB_MODE.apply()
sendInfoMessage("Agent mode: " .. BB_MODE.current .. (env_enabled and " (locked by BALATROBOT_ENABLE)" or ""), LOGGER)

sendInfoMessage("BalatroBot loaded - version " .. MOD.version, LOGGER)
