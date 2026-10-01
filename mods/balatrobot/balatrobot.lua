--[[
BalatroBot 入口, 由本仓库在 upstream v1.5.2 的基础上改写. 本仓库新增的代码在 agent/ 下.
游戏动作端点, 弹窗拦截, 决策消息等公共部分在 bbcore (先于本 mod 加载); 录像与回放在 bbreplay.

与 upstream 的区别:
- agent 模式三选一 (agent/mode.lua): 关闭 / 外部 (HTTP 接口) / 内置 (游戏内 loop, 见 agent/runner.lua).
  默认关闭, 不开端口. 游戏内 模组 -> BalatroBot -> 配置 切换, 或启动时设 BALATROBOT_ENABLE=1 锁定为外部.
- 切换模式只启停 HTTP 服务, 不改游戏设置. BALATROBOT_ENABLE=1 时由 agent/settings.lua
  处理 BALATROBOT_* 环境变量: 画面, 开场动画, 声音默认沿用存档, 显式要求的改动不写回存档.
- 模式可在运行中切换, 保存在存档目录的 config/balatrobot.jkr. 设置页见 agent/ui/settings_tab.lua.
- 内置模式: 选项菜单的 Agent 按钮与面板, F9 暂停/继续 (agent/ui/agent_menu.lua), 顶部流式条.
- 请求可带 reason, 另有 notify 方法, 在游戏内以原版通知的样式显示 agent 的决策消息.
- 弹窗 (解锁通知, 胜利界面等) 打开时拦截操作, 等待中的请求先返回 (bbcore 的 runtime/overlay.lua).
  解锁通知用 continue 关掉, 胜利后用 endless 进入无尽模式.
- 别的东西独占游戏时 (bbreplay 的回放, 见 bbcore 的 BB_CONTROL) 不开端口, 内置 loop 不能开始.
]]

local MOD = SMODS.current_mod
local LOGGER = "BB.BALATROBOT"

if not (BB_CORE and BB_CORE.ready) then
  sendErrorMessage("BB Core is not loaded, BalatroBot disabled", LOGGER)
  return
end

-- 修复早期版本写坏的存档设置, 迁移 mod 配置. 两种开启方式都执行.
assert(SMODS.load_file("agent/migrate.lua"))().run(MOD)

local env_enabled = os.getenv("BALATROBOT_ENABLE") == "1"
if env_enabled then
  assert(SMODS.load_file("agent/settings.lua"))().setup()
end

-- 手册查询: 只读, 登记为被动方法 (不算活动, 弹窗打开时也可调用).
local KNOWLEDGE_ENDPOINTS = {
  "agent/endpoints/docs_index.lua",
  "agent/endpoints/docs_read.lua",
  "agent/endpoints/docs_search.lua",
  "agent/endpoints/lookup.lua",
}
for _, method in ipairs({ "docs_index", "docs_read", "docs_search", "lookup" }) do
  BB_ACTIVITY.PASSIVE[method] = true
end
do
  local ok, err = BB_DISPATCHER.load_endpoints(KNOWLEDGE_ENDPOINTS, MOD.id)
  if not ok then
    sendErrorMessage("Knowledge endpoints unavailable: " .. tostring(err), LOGGER)
  end
end
-- 这几个方法在左侧工具调用弹窗里的文案 (bbcore 按方法名写死一套, 手册这套由本 mod 补上).
BB_CALL_NOTE.register_all(assert(SMODS.load_file("agent/knowledge/notes.lua"))())

assert(SMODS.load_file("src/lua/core/server.lua"))() -- define BB_SERVER
local OPENRPC = assert(SMODS.load_file("agent/openrpc.lua"))()
-- 端点的结果经 bbcore 的 BB_TRANSPORT 交出, HTTP 服务从这里取走写给客户端. 没有客户端时它直接返回.
BB_TRANSPORT.add_writer(function(response)
  return BB_SERVER.send_response(response)
end)

-- 右侧: 决策消息与解说; 左侧: 工具调用记录. 两个开关各自控制 (设置页的 "显示 agent 消息" / "显示工具调用").
BB_TOAST.enabled = MOD.config.show_messages ~= false
BB_TOAST.calls_enabled = MOD.config.show_calls ~= false

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
      BB_TRANSPORT.openrpc_spec = BB_SERVER.openrpc_spec
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

-- agent 模式. BALATROBOT_ENABLE=1 锁定为外部; 别的东西独占游戏 (回放) 时不监听.
local function replaying()
  return BB_CONTROL.owner() ~= nil
end
local MODE = assert(SMODS.load_file("agent/mode.lua"))()
BB_RUNNER = assert(SMODS.load_file("agent/runner.lua"))()
BB_MODE = MODE.new({
  initial = MOD.config.mode,
  env_locked = env_enabled,
  replaying = replaying,
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
-- 回放开始与结束时重新按模式启停 HTTP 服务.
BB_CONTROL.on_change(function()
  BB_MODE.apply()
end)

local LOG_FUNCS = { debug = sendDebugMessage, info = sendInfoMessage, warn = sendWarnMessage, error = sendErrorMessage }
BB_RUNNER.init({
  stream = BB_STREAM,
  can_start = function()
    if not BB_MODE.is_builtin() then
      return false, "当前不是内置模式"
    end
    local owner = BB_CONTROL.owner()
    if owner then
      return false, owner .. "进行中"
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
-- 内置 loop 运行或暂停时占着游戏, 回放不能开始.
BB_CONTROL.add_busy("内置 agent", function()
  return BB_RUNNER.is_busy()
end)

-- 内置 agent 的真实 driver: 模型客户端, 进程内调用端点, 主循环. 出错时保留演示 driver 可用, 不影响其他功能.
do
  local ok, err = pcall(function()
    BB_BUILTIN = assert(SMODS.load_file("agent/loop/builtin.lua"))()
    BB_BUILTIN.install({
      mod = MOD,
      runner = BB_RUNNER,
      stream = BB_STREAM,
      dispatcher = BB_DISPATCHER,
      server = BB_TRANSPORT,
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
  love_update(dt)
  BB_SERVER.update(BB_DISPATCHER)
  -- 内置 loop 在游戏 update 之后推进; 菜单打开 (游戏暂停) 时也调用, 由 driver 自己看 overlay 决定是否执行动作.
  BB_RUNNER.update(love.timer.getDelta())
end

-- 设置页, 选项菜单的 Agent 按钮与面板, F9.
local SETTINGS_TAB = assert(SMODS.load_file("agent/ui/settings_tab.lua"))()
SETTINGS_TAB.init({
  mod = MOD,
  modes = MODE,
  mode = BB_MODE,
  runner = BB_RUNNER,
  toast = BB_TOAST,
  agent = BB_AGENT,
  widgets = BB_WIDGETS,
})
MOD.config_tab = SETTINGS_TAB.build
BB_AGENT_MENU = assert(SMODS.load_file("agent/ui/agent_menu.lua"))()
BB_AGENT_MENU.init({
  mod = MOD,
  mode = BB_MODE,
  runner = BB_RUNNER,
  stream = BB_STREAM,
  toast = BB_TOAST,
  widgets = BB_WIDGETS,
  menu = BB_MENU,
})

-- 按模式启停 HTTP 服务. 推迟到所有 mod 加载完: 命令行回放由 bbreplay 判断 (它加载得更晚),
-- 在这之前打开端口会先开再关.
BB_CORE.after_load[#BB_CORE.after_load + 1] = function()
  if BB_CONTROL.owner() then
    sendInfoMessage(BB_CONTROL.owner() .. " in progress: agent API not started", LOGGER)
  end
  BB_MODE.apply()
  sendInfoMessage("Agent mode: " .. BB_MODE.current .. (env_enabled and " (locked by BALATROBOT_ENABLE)" or ""), LOGGER)
end

sendInfoMessage("BalatroBot loaded - version " .. MOD.version, LOGGER)
