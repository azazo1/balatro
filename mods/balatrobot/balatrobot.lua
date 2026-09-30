--[[
BalatroBot 入口, 由本仓库在 upstream v1.5.2 的基础上改写. 本仓库新增的代码在 agent/ 下.

与 upstream 的区别:
- 默认不开端口. 游戏内 Mods > BalatroBot > Config 的开关, 或启动时设 BALATROBOT_ENABLE=1, 才监听.
- 游戏内开关只启停 HTTP 服务, 不改游戏设置. BALATROBOT_ENABLE=1 时由 agent/settings.lua
  处理 BALATROBOT_* 环境变量: 画面, 开场动画, 声音默认沿用存档, 显式要求的改动不写回存档.
- 开关可在运行中切换, 状态保存在存档目录的 config/balatrobot.jkr.
- 请求可带 reason, 另有 notify 方法, 在游戏内以原版通知的样式显示 agent 的决策消息.
- 弹窗 (解锁通知, 胜利界面等) 打开时拦截操作, 等待中的请求先返回, 见 agent/overlay.lua.
  解锁通知用 continue 关掉, 胜利后用 endless 进入无尽模式.
- BALATROBOT_RECORD=skip|keep 时按局录制 mp4 与时间线 JSON, 见 agent/record/recorder.lua.
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

BB_RECORDER.init({ activity = BB_ACTIVITY, toast = BB_TOAST, mod_path = MOD.path })

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
    MOD.config.enabled = false
    BB_AGENT.status = "bind failed"
    sendErrorMessage("Agent API failed to start: " .. tostring(ok and "bind failed" or started), LOGGER)
    return false
  end
  BB_SERVER.close()
  BB_AGENT.status = "off"
  sendInfoMessage("Agent API stopped", LOGGER)
  return false
end

-- 未监听时 BB_SERVER.update 直接返回, 关闭状态下几乎没有开销.
local love_update = love.update
love.update = function(dt) ---@diagnostic disable-line: duplicate-set-field
  BB_GAMESTATE.check_game_over()
  love_update(dt)
  BB_SERVER.update(BB_DISPATCHER)
  BB_OVERLAY.update()
  -- fast/headless 模式下传进来的 dt 是固定步长, 通知停留时间按墙钟算.
  BB_TOAST.update(love.timer.getDelta())
  BB_RECORDER.update()
end

-- 录制关闭时 BB_RECORDER.draw 直接调用原函数.
local love_draw = love.draw
love.draw = function() ---@diagnostic disable-line: duplicate-set-field
  BB_RECORDER.draw(love_draw)
end

local function text_row(nodes)
  return { n = G.UIT.R, config = { align = "cm", padding = 0.05 }, nodes = nodes }
end

local function label(text)
  return { n = G.UIT.T, config = { text = text, scale = 0.35, colour = G.C.UI.TEXT_LIGHT } }
end

local function live_label(ref_table, ref_value)
  return { n = G.UIT.T, config = { ref_table = ref_table, ref_value = ref_value, scale = 0.35, colour = G.C.UI.TEXT_LIGHT } }
end

MOD.config_tab = function()
  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.2, r = 0.1, colour = G.C.BLACK, minw = 7 },
    nodes = {
      create_toggle({
        label = "Enable Agent API",
        ref_table = MOD.config,
        ref_value = "enabled",
        w = 4,
        callback = BB_AGENT.set_enabled,
      }),
      text_row({ label(BB_AGENT.address) }),
      text_row({ label("Status: "), live_label(BB_AGENT, "status") }),
      create_toggle({
        label = "Show Agent Messages",
        ref_table = MOD.config,
        ref_value = "show_messages",
        w = 4,
        callback = function(value)
          BB_TOAST.enabled = value
          if not value then
            BB_TOAST.clear()
          end
        end,
      }),
      text_row({ label("Recording: "), live_label(BB_RECORDER, "status") }),
    },
  }
end

if env_enabled or MOD.config.enabled then
  BB_AGENT.set_enabled(true)
end

sendInfoMessage("BalatroBot loaded - version " .. MOD.version, LOGGER)
