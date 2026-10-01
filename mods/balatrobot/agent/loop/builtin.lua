--[[
内置 agent 在游戏里的接线: 把 driver.lua 接到运行控制 (agent/runner.lua), 模型客户端 (agent/llm/client.lua),
进程内调用 (local_call.lua), 流式条与录像. bbcore 装好 BB_OVERLAY/BB_ACTIVITY 之后, 由 balatrobot.lua 调用 M.install.

- runner 的暂停, 继续, 停止转给 driver; driver 的汇报 (请求, 重试, 用量, 防失控, 本局结束) 转给 runner.
- 转录: 每条记录一行 JSON. 装了 bbreplay 且正在录像时写到录像旁边的 <stem>-agent.jsonl, 能和录像时间轴对上;
  否则写到存档目录的 agent/<开始时间>-agent.jsonl. 不含 key.
]]

local LOGGER = "BB.AGENT.LOOP"

local M = {}

local function load(rel)
  return assert(SMODS.load_file(rel, "balatrobot"))()
end

local function log(level, msg)
  if level == "error" then
    sendErrorMessage(msg, LOGGER)
  elseif level == "warn" then
    sendWarnMessage(msg, LOGGER)
  elseif level == "debug" then
    sendDebugMessage(msg, LOGGER)
  else
    sendInfoMessage(msg, LOGGER)
  end
end

-- driver 子状态到 runner 阶段的映射, 其余状态 (idle, waiting) 算 running.
local PHASE = { requesting = "requesting", acting = "acting", retry_wait = "retry_wait" }
local OVERLAY_HOLD = 2.5 -- 解锁通知与胜利界面停留的秒数

--- 转录写入器. 录像换段 (换 stem) 时换文件.
---@param encode fun(v: any): string
local function transcript_writer(encode)
  local file, path = nil, nil
  local started = nil

  local function target()
    local current = BB_RECORDER and BB_RECORDER.current and BB_RECORDER.current()
    if current and current.base then
      return current.base .. "-agent.jsonl", true
    end
    return nil, false
  end

  local function open(want, native)
    if file then
      file:close()
      file = nil
    end
    path = want
    if native then
      local f, err = io.open(want, "a")
      if not f then
        log("warn", "Cannot open agent transcript " .. want .. ": " .. tostring(err))
        return
      end
      file = f
    end
  end

  return function(entry)
    local want, native = target()
    if not want then
      started = started or os.date("%Y%m%d-%H%M%S")
      want = "agent/" .. started .. "-agent.jsonl"
    end
    if want ~= path then
      open(want, native)
    end
    local ok, line = pcall(encode, entry)
    if not ok then
      return
    end
    if file then
      file:write(line, "\n")
      file:flush()
    elseif not native then
      love.filesystem.createDirectory("agent")
      love.filesystem.append(want, line .. "\n")
    end
  end
end

--- 从手册目录取卡的中文名与效果, 给状态摘要用. 手册不可用时返回 nil, 摘要改用 gamestate 里的名字.
local function describer()
  local cache = {}
  return function(key)
    if key == "" then
      return nil
    end
    if cache[key] ~= nil then
      return cache[key] or nil
    end
    local info = false
    local store = BB_KNOWLEDGE
    local catalog = store and store.catalog and store.catalog()
    if catalog then
      local ok, found = pcall(catalog.find, catalog, key)
      local entry = ok and found and found[1]
      if entry then
        local effect = entry.effect_zh
        info = { name = entry.name_zh, effect = type(effect) == "table" and table.concat(effect, " ") or effect }
      end
    end
    cache[key] = info
    return info or nil
  end
end

---@param opts {mod: table, runner: table, stream: table, dispatcher: table, server: table, gamestate: table}
--- server: 端点结果的出口 (bbcore 的 BB_TRANSPORT), 本地调用在这里取结果.
function M.install(opts)
  local mod, runner, stream = opts.mod, opts.runner, opts.stream
  local LocalCall = load("agent/loop/local_call.lua")
  local Driver = load("agent/loop/driver.lua")
  local Client = load("agent/llm/client.lua")
  local streaming, why = Client.init({ mod_path = mod.path })
  log("info", "Model client backend: " .. tostring(Client.backend()) .. (streaming and "" or (" (" .. tostring(why) .. ")")))
  M.client = Client

  LocalCall.install(opts.server)
  local json = require("json")

  local driver
  driver = Driver.new({
    tools = load("agent/loop/tools.lua"),
    prompt = load("agent/loop/prompt.lua"),
    history = load("agent/loop/history.lua"),
    summary = load("agent/loop/summary.lua"),
    text = load("agent/text.lua"),
    client = Client,
    json = { encode = Client.Chat.encode, decode = json.decode },
    now = love.timer.getTime,
    overlay_hold = OVERLAY_HOLD,
    config = function()
      return mod.config
    end,
    call = function(method, params, reason, cb)
      return LocalCall.call(opts.dispatcher, method, params, reason, cb)
    end,
    abandon = LocalCall.abandon,
    gamestate = function()
      local gs = opts.gamestate.get_gamestate()
      gs.overlay = BB_OVERLAY.kind()
      return gs
    end,
    overlay = function()
      return BB_OVERLAY.kind()
    end,
    busy = function()
      -- 人打开了任何菜单 (包括主菜单上的设置, BB_OVERLAY.kind 对它返回 nil) 时都不动, 解锁通知与胜利界面除外.
      local kind = BB_OVERLAY.kind()
      if G.OVERLAY_MENU and kind ~= "unlock" and kind ~= "win" then
        return true
      end
      return BB_OVERLAY.animating() and true or false
    end,
    describe = describer(),
    bar = stream,
    log = log,
    transcript = transcript_writer(Client.Chat.encode),
    on_state = function(state)
      local phase = PHASE[state]
      if phase then
        runner.set_phase(phase)
      elseif state == "idle" or state == "waiting" then
        runner.set_phase("running")
      end
    end,
    report = function(event, a, b)
      if event == "request" then
        runner.note_request()
      elseif event == "retry" then
        runner.note_retry()
      elseif event == "usage" then
        runner.add_usage(a, b)
      elseif event == "new_run" then
        runner.new_run()
      elseif event == "halt" then
        runner.pause(a)
      elseif event == "finish" then
        runner.stop()
        -- 放在 stop 之后, 覆盖 runner 自己的 "已停止".
        stream.show_status(a == "win" and "赢下本局, 内置 agent 已停止" or "本局结束, 内置 agent 已停止", 4)
      end
    end,
  })
  M.driver = driver

  runner.set_driver({
    start = function()
      driver.start()
    end,
    stop = function()
      driver.stop("user")
    end,
    pause = function()
      driver.pause()
    end,
    resume = function()
      -- 防失控停下后继续, 或普通暂停后继续, 都保留历史.
      if driver.state == "halted" then
        driver.retry()
      else
        driver.resume()
      end
    end,
    update = function()
      driver.update()
    end,
  })

  -- 录像的暂停剪辑, 停止时结束录像段, 流式条算作活动: 由 balatrobot.lua 挂在 runner 与 recorder 上.
  M.install_lifecycle(runner, stream)
end

--- 移动端的生命周期: 运行中防止熄屏; 切到后台时自动暂停, 回到前台后由 user 点继续 (期间画面可能变了).
--- 桌面上窗口失去焦点很常见 (看别的窗口), 不暂停.
---@param runner table
---@param stream table
function M.install_lifecycle(runner, stream)
  local os_name = love.system and love.system.getOS and love.system.getOS() or ""
  local mobile = os_name == "Android" or os_name == "iOS"
  table.insert(runner.on_state, function(state)
    if mobile and love.window and love.window.setDisplaySleepEnabled then
      love.window.setDisplaySleepEnabled(not runner.is_busy())
    end
  end)
  if not mobile or not love.handlers then
    return
  end
  -- 触摸平台没有 F9.
  runner.pause_hint = "已暂停, 在 选项 -> Agent 里继续"
  local function background()
    if runner.is_active() then
      runner.pause()
      runner.notice = "切到后台时自动暂停"
      log("info", "Builtin agent paused: app went to background")
    end
  end
  for _, name in ipairs({ "focus", "visible" }) do
    local original = love.handlers[name]
    love.handlers[name] = function(on, ...)
      if not on then
        pcall(background)
      end
      if original then
        return original(on, ...)
      end
    end
  end
end

return M
