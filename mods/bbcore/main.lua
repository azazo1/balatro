--[[
BB Core 入口: balatrobot 与 bbreplay 共用的运行时, 由本仓库从 BalatroBot (upstream v1.5.2) 拆出.
本身不开网络端口, 只在进程内执行游戏动作. 加载顺序 (priority): bbcore -50, balatrobot 0, bbreplay 1.

提供的全局:
- BB_SETTINGS: BALATROBOT_* 环境变量 (src/lua/settings.lua).
- BB_DISPATCHER: 端点注册与分发 (src/lua/core/dispatcher.lua). 游戏动作端点都在这里注册, 别的 mod 用
  BB_DISPATCHER.load_endpoints(files, mod_id) 追加自己的端点.
- BB_TRANSPORT: 端点结果的公共出口 (runtime/transport.lua), HTTP 服务与本地调用在这里取结果.
- BB_GAMESTATE, BB_ERROR_NAMES / BB_ERROR_CODES: 状态序列化与错误码.
- BB_OVERLAY: 弹窗拦截, kind / win_settled / animating (runtime/overlay.lua).
- BB_ACTIVITY: 请求与响应事件 (runtime/activity.lua).
- BB_SCORING: 一次出牌的计分过程, 写进 gamestate 的 round.last_hand (runtime/scoring.lua).
- BB_TOAST, BB_STREAM: 决策消息与顶部状态条. BB_WIDGETS: 界面组件.
- BB_CONTROL: 谁在操作游戏, 回放与 agent 的互斥 (runtime/control.lua).
- BB_MENU: 选项菜单里的公共入口 (ui/menu.lua, lovely/menu.toml).
- BB_CORE: ready, version, after_load.
]]

local MOD = SMODS.current_mod
local LOGGER = "BB.CORE"

BB_CORE = {
  ready = false,
  version = MOD.version,
  ---@type fun()[] 所有 mod 加载完之后, 第一帧 update 时依次调用一次.
  --- Steamodded 没有 "全部 mod 加载完" 的回调, 而 balatrobot 按模式启停 HTTP 服务要等 bbreplay 先判断是不是
  --- 命令行回放 (bbreplay 加载得更晚), 回放的输入锁也要包在所有 mod 的输入钩子外面.
  after_load = {},
}

assert(SMODS.load_file("src/lua/settings.lua"))() -- define BB_SETTINGS

-- 游戏动作端点. 手册查询等只读端点在 balatrobot 里, 由它自己注册.
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
  "runtime/endpoints/notify.lua",
  "runtime/endpoints/endless.lua",
  "runtime/endpoints/continue.lua",
  "runtime/endpoints/dynamics.lua",
  -- If debug mode is enabled, debugger.lua will load test endpoints
}

-- 调试端点依赖 DebugPlus, 只在环境变量方式开启时生效, 与 upstream 一致.
if os.getenv("BALATROBOT_ENABLE") == "1" and BB_SETTINGS.debug then
  assert(SMODS.load_file("src/lua/utils/debugger.lua"))() -- define BB_DEBUG
  BB_DEBUG.setup()
end

BB_TRANSPORT = assert(SMODS.load_file("runtime/transport.lua"))()
assert(SMODS.load_file("src/lua/core/dispatcher.lua"))() -- define BB_DISPATCHER
BB_GAMESTATE = assert(SMODS.load_file("src/lua/utils/gamestate.lua"))()
assert(SMODS.load_file("src/lua/utils/errors.lua"))()
-- 一次出牌的计分过程 (写进 gamestate 的 round.last_hand), 装钩子要在游戏函数定义之后.
BB_SCORING = assert(SMODS.load_file("runtime/scoring.lua"))()
BB_GAMESTATE.scoring = BB_SCORING -- gamestate 的 round.last_hand 从这里取
assert(BB_SCORING.install(BB_SCORING.game_deps(BB_GAMESTATE)), "scoring record already installed")

BB_OVERLAY = assert(SMODS.load_file("runtime/overlay.lua"))()
BB_ACTIVITY = assert(SMODS.load_file("runtime/activity.lua"))()
BB_TOAST = assert(SMODS.load_file("runtime/toast.lua"))()
BB_STREAM = assert(SMODS.load_file("ui/stream_bar.lua"))()
BB_STREAM.init({ toast = BB_TOAST })
BB_CONTROL = assert(SMODS.load_file("runtime/control.lua"))()
BB_MENU = assert(SMODS.load_file("ui/menu.lua"))()
BB_WIDGETS = assert(SMODS.load_file("ui/widgets.lua"))()
BB_WIDGETS.init({ toast = BB_TOAST })

-- 端点只能注册一次, 与谁在调用无关.
if not BB_DISPATCHER.init(BB_TRANSPORT, BB_ENDPOINTS, MOD.id) then
  sendErrorMessage("Dispatcher init failed, game actions unavailable", LOGGER)
  return
end
-- 先装弹窗拦截, 再装活动追踪: 被拦下的请求也会作为失败的操作记进时间线.
BB_OVERLAY.install(BB_DISPATCHER, BB_GAMESTATE)
BB_ACTIVITY.install(BB_DISPATCHER, BB_TRANSPORT)

-- 请求附带 reason 时, 通知标题用操作的中文名, 观众不用看懂方法名.
-- 是否显示由 BB_TOAST.enabled 决定: balatrobot 按设置页的开关设置, 回放时 bbreplay 打开.
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
  -- notify 自己负责显示 (显示后立刻返回, 消息怎么停留由通知自己管); 这里只管操作参数带的 reason.
  if source == "reason" then
    BB_TOAST.push(ACTION_TITLES[title] or title, text, duration)
  end
end)

local love_update = love.update
local loaded = false
love.update = function(dt) ---@diagnostic disable-line: duplicate-set-field
  BB_GAMESTATE.check_game_over()
  love_update(dt)
  BB_OVERLAY.update()
  -- fast/headless 模式下传进来的 dt 是固定步长, 通知停留时间按墙钟算.
  local wall_dt = love.timer.getDelta()
  BB_TOAST.update(wall_dt)
  -- 等讲解退去的请求: 放在通知之后, 这一帧退场的讲解这一帧就能放行.
  BB_DISPATCHER.update()
  BB_STREAM.update(wall_dt)
  if not loaded then
    loaded = true
    for _, fn in ipairs(BB_CORE.after_load) do
      local ok, err = pcall(fn)
      if not ok then
        sendErrorMessage("after_load hook failed: " .. tostring(err), LOGGER)
      end
    end
  end
end

BB_CORE.ready = true
sendInfoMessage("BB Core loaded - version " .. MOD.version, LOGGER)
