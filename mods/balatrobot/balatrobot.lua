--[[
BalatroBot 入口, 由本仓库在 upstream v1.5.2 的基础上改写, src/lua 下的文件保持原样.

与 upstream 的区别:
- 默认不开端口. 游戏内 Mods > BalatroBot > Config 的开关, 或启动时设 BALATROBOT_ENABLE=1, 才监听.
- 游戏内开关只启停 HTTP 服务, 不改游戏设置; BALATROBOT_ENABLE=1 时与 upstream 相同,
  按 BALATROBOT_* 环境变量调整设置 (静音, 加速, headless 等).
- 开关可在运行中切换, 状态保存在存档目录的 config/balatrobot.jkr.
]]

local MOD = SMODS.current_mod
local LOGGER = "BB.BALATROBOT"

assert(SMODS.load_file("src/lua/settings.lua"))() -- define BB_SETTINGS

local env_enabled = os.getenv("BALATROBOT_ENABLE") == "1"
if env_enabled then
  BB_SETTINGS.setup()
  -- setup 打开了 skip_splash 与 F_SKIP_TUTORIAL. 全新存档里 tutorial_progress 要等第一帧的
  -- tutorial_controller 才创建, 跳过开场时 main_menu 先于它执行, 会在 game.lua 的
  -- tutorial_progress.completed_parts 处因 nil 崩溃. 这里提前做 tutorial_controller 跳过教程时的处理.
  if G.F_SKIP_TUTORIAL then
    G.SETTINGS.tutorial_complete = true
    G.SETTINGS.tutorial_progress = nil
  end
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

-- 端点只能注册一次, 与服务的启停无关.
if not BB_DISPATCHER.init(BB_SERVER, BB_ENDPOINTS) then
  sendErrorMessage("Dispatcher init failed, agent API unavailable", LOGGER)
  return
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
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.05 },
        nodes = {
          { n = G.UIT.T, config = { text = BB_AGENT.address, scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
        },
      },
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.05 },
        nodes = {
          { n = G.UIT.T, config = { text = "Status: ", scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
          { n = G.UIT.T, config = { ref_table = BB_AGENT, ref_value = "status", scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
        },
      },
    },
  }
end

if env_enabled or MOD.config.enabled then
  BB_AGENT.set_enabled(true)
end

sendInfoMessage("BalatroBot loaded - version " .. MOD.version, LOGGER)
