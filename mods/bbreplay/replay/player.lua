--[[
回放: 用同一个种子开局, 恢复原局开局时的存档进度, 再按顺序重做每一步操作. 游戏照常运行,
画面, 动画和声音都由游戏自己产生, 录制照常进行.

两种入口:
- 命令行: 由 BALATROBOT_REPLAY=<回放文件> 开启, 用 just macos replay 启动. 结束后以退出码结束进程.
- 游戏内: 主菜单的 选项 -> 回放 选一个文件, 见 ui/replay_menu.lua. 存档隔离与收尾交给
  replay/session.lua (丢弃存档写入, 结束后读回进度并恢复设置), 结束后回调给界面显示结果.

节奏 (BALATROBOT_REPLAY_PACING, 游戏内由确认页选):
- tight: 上一步完成且动画停下后, 稍等 TIGHT_GAP 秒就做下一步, 去掉原局里 agent 思考的时间.
  讲解 (notify) 仍等阅读时长 (传 wait: true), 但 toast 改用紧凑时长, 退去更快.
  回放期间关掉讲解门槛, 原局里操作是怎么排的就怎么排. 工具调用那条左侧始终用短时长.
- original: 按原局里两步之间的实际间隔回放, 包括思考的时间; 动画没停时也会等它停下.

弹窗不会一出现就关:
- 解锁通知: 停留 UNLOCK_HOLD 秒后点继续 (original 节奏下取原局的停留时长, 至少 UNLOCK_HOLD).
  原局里有 continue 但回放时没弹出, 跳过这一步; 回放时多出的解锁通知同样停留后关掉.
- 胜利界面: Jimbo 出现后再停 WIN_HOLD 秒, 然后按原局的选择 (endless 或 menu) 继续.

每步完成后比对状态摘要, 不一致时在 VERIFY_WINDOW 秒内反复确认, 仍不一致就停止回放, 录像保留到这里.
回放期间锁定输入, 按住 Esc 1 秒中止 (触摸是长按 1.5 秒). 命令行回放完成退出码为 0, 跑偏为 1,
中止为 2, 文件无法回放为 3; 游戏内以同样的数字回调给界面, 用来显示结果.
]]

local json = require("json")

local LOGGER = "BB.AGENT.REPLAY"

local M = {
  active = false,
  status = "off",
}

local ABORT_HINT = "要中止回放: 按住 Esc 1 秒; 触摸时长按屏幕 1.5 秒"

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or "")
  return value and value >= 0 and value or default
end

local cfg = {
  pacing = "tight",
  tight_gap = 0.35, -- tight 节奏下动画停下后再等的秒数
  settle_max = 12, -- 等动画停下的上限
  unlock_hold = 2.5, -- 解锁通知的停留秒数
  win_hold = 3, -- 胜利界面 Jimbo 出现后的停留秒数
  end_hold = 3, -- 最后一步之后的停留秒数
  continue_grace = 3, -- 原局有 continue 时等解锁通知出现的上限
  overlay_grace = 8, -- 等胜利界面出现, 或意外弹窗消失的上限
  verify_window = 2, -- 摘要不一致时反复确认的时长
}

-- dispatcher, activity, overlay, gamestate, recorder, toast, stream, format, snapshot, session, input_lock, manual,
-- tutorial (教程局的回放支持),
-- control (bbcore 的 BB_CONTROL), animating (画面是否还在动, bbcore 的 BB_OVERLAY.animating), game_version, mod_version
local deps = {}
-- 回放进行时在 BB_CONTROL 上的独占名: balatrobot 据此不开端口, 内置 loop 不能开始.
local OWNER = "回放"
local data = nil -- 回放文件内容
local st = {} -- 回放进度

local function now()
  return love.timer.getTime()
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

local function set_phase(phase)
  st.phase = phase
  st.phase_at = now()
end

local function toast(title, text, duration)
  deps.toast.push(title, text, duration)
end

--- 回放期间关掉 "等讲解退去" 的门槛: 原局里操作是在讲解停留期间执行的, 回放照原样重做.
--- 紧凑节奏同时打开 toast.compact, 右侧消息更快退去. 结束或开始失败时都要恢复.
---@param active boolean
local function set_replay_toast(active)
  deps.toast.gate_enabled = not active
  deps.toast.compact = active and cfg.pacing == "tight"
end

local REPLAY_SUFFIX = ".replay.json"

--- 参数是这一局的文件夹时 (每局一个文件夹), 取里面的回放文件. 是文件时原样返回.
---@param path string
---@return string? resolved
---@return string? problem
local function resolve_replay_path(path)
  if path:sub(-#REPLAY_SUFFIX) == REPLAY_SUFFIX then
    return path
  end
  local nfs = SMODS and SMODS.NFS
  if type(nfs) ~= "table" or not nfs.getInfo(path, "directory") then
    return path
  end
  local found = {}
  for _, name in ipairs(nfs.getDirectoryItems(path) or {}) do
    if name:sub(-#REPLAY_SUFFIX) == REPLAY_SUFFIX then
      found[#found + 1] = name
    end
  end
  if #found ~= 1 then
    return nil, string.format("文件夹里没有唯一的回放文件 (找到 %d 个): %s", #found, path)
  end
  return path .. "/" .. found[1]
end

--- 读一个回放文件并校验, 返回内容或中文的不可回放原因. 列表里的同样判断见 library.describe.
---@param path string 回放文件, 或存放它的一局文件夹
---@return table? data
---@return string? problem
local function read_data(path)
  local resolved, problem = resolve_replay_path(path)
  if not resolved then
    return nil, problem
  end
  path = resolved
  local file = io.open(path, "rb")
  local text = file and file:read("*a")
  if file then
    file:close()
  end
  if not text then
    return nil, "读不到回放文件 " .. path
  end
  local ok, decoded = pcall(json.decode, text)
  if not ok or type(decoded) ~= "table" or type(decoded.actions) ~= "table" or type(decoded.run) ~= "table" then
    return nil, "回放文件格式不对"
  end
  if decoded.version ~= deps.format.VERSION then
    return nil, string.format("回放文件版本 %s, 当前只支持 %d", tostring(decoded.version), deps.format.VERSION)
  end
  if decoded.run.challenge then
    return nil, "挑战模式的局不支持回放"
  end
  if not decoded.run.resumed and not (decoded.run.deck and decoded.run.stake and decoded.run.seed) then
    return nil, "只支持原版牌组的局"
  end
  return decoded
end

--- 停留 hold 秒后结束回放: 命令行按退出码结束进程, 游戏内把结果交回界面, 由它收尾.
local function finish_later(code, hold)
  st.exit_code = code
  st.quit_at = now() + hold
  set_phase("ending")
end

--- 游戏内回放的收尾: 结束录像段, 恢复存档进度与设置, 把结果交给界面.
local function finish_ingame()
  deps.recorder.end_segment("replay")
  deps.tutorial.restore()
  set_replay_toast(false)
  local warnings = deps.session.finish()
  M.active = false
  M.status = "off"
  st.phase = "off"
  -- 先释放再回调: 界面收尾时 agent 已经按当前模式恢复.
  deps.control.release(OWNER)
  if st.on_finish then
    local ok, err = pcall(st.on_finish, st.exit_code, warnings)
    if not ok then
      sendErrorMessage("Replay finish handler failed: " .. tostring(err), LOGGER)
    end
  end
end

local function update_status()
  local total = data and #data.actions or 0
  if st.phase == "run" or st.phase == "verify" then
    M.status = string.format("replaying %d/%d (%s)", math.min(st.index, total), total, cfg.pacing)
  else
    M.status = "replay " .. tostring(st.phase)
  end
end

--- 回放跑偏或无法继续: 停止操作, 停留一会儿后退出, 录像保留到这里.
---@param detail string
---@param index integer? 出错的步骤, 默认为当前步骤
local function diverge(detail, index)
  index = index or st.index
  local action = data and data.actions[index]
  local where = action and string.format("第 %d 步 %s", index, action.method) or "开局"
  sendErrorMessage(string.format("Replay diverged at step %d (%s): %s", index or 0, action and action.method or "start", detail), LOGGER)
  toast("回放中止", where .. ": " .. detail, 6)
  deps.recorder.annotate("replay", {
    source = data and data.source,
    pacing = cfg.pacing,
    ok = false,
    step = index,
    method = action and action.method,
    detail = detail,
  })
  finish_later(1, 6)
end

---@param method string
---@param params table?
---@param reason string?
---@param synthetic boolean?
local function dispatch(method, params, reason, synthetic)
  local request_params = copy(params or {})
  if reason then
    request_params.reason = reason
  end
  st.request_id = (st.request_id or 0) + 1
  st.waiting = { method = method, sent = now(), synthetic = synthetic }
  st.result = nil
  deps.dispatcher.dispatch({ jsonrpc = "2.0", method = method, params = request_params, id = st.request_id })
end

--- 这一步之前要不要再等: 动画没停, 或者 original 节奏下原局间隔还没到.
---@param action table
---@param t number
---@return boolean ready
local function gap_ready(action, t)
  if t - st.prev_done > cfg.settle_max then
    return true
  end
  if deps.animating() then
    return false
  end
  if cfg.pacing == "original" then
    return t - st.prev_done >= deps.format.original_gap(action, st.reference)
  end
  return t - st.last_busy >= cfg.tight_gap and t - st.prev_done >= cfg.tight_gap
end

--- 解锁通知已停留够了没有.
---@param action table? 下一步 (是 continue 时按原局的停留时长)
---@param t number
local function unlock_ready(action, t)
  local hold = cfg.unlock_hold
  if cfg.pacing == "original" and action and action.method == "continue" then
    hold = math.max(hold, deps.format.original_gap(action, st.reference))
  end
  return t - st.overlay_since >= hold
end

local function run_action(action)
  if st.index == #data.actions then
    -- 最后一步常是 menu, 它会先结束录制; 先记下结果, 这一步跑偏时 diverge 会覆盖.
    deps.recorder.annotate("replay", { source = data.source, pacing = cfg.pacing, ok = true, steps = #data.actions })
  end
  st.running = action
  if deps.manual.LOCAL[action.method] then
    -- 人手动的操作里没有接口的那些: 本地重做, 见 local_tick.
    st.waiting = { method = action.method, sent = now(), pending = true }
    return
  end
  -- 讲解照原局那样按阅读时长等: 端点默认改成不等了, 回放要的仍是原来的节奏.
  if action.method == "notify" then
    local params = copy(action.params or {})
    params.wait = true
    dispatch(action.method, params, action.reason, false)
    return
  end
  dispatch(action.method, action.params, action.reason, false)
end

-- 本地步骤做完后至少等这么久再看动画, 它触发的事件可能下一帧才排进队列.
local LOCAL_SETTLE_MIN = 0.3

--- 本地步骤: 还没准备好 (例如标签送的卡包还没打开) 时每帧重试; 做完后等它触发的动画停下才算完成,
--- 与接口等到完成才返回一致, 之后照常比对状态摘要.
---@param t number
local function local_tick(t)
  local waiting = st.waiting
  if waiting.pending then
    local ok, applied, reason = pcall(deps.manual.apply_local, st.running.method, st.running.params)
    if not ok or applied == false then
      st.result = { ok = false, error = ok and reason or applied }
    elseif applied then
      waiting.pending = false
      waiting.applied_at = t
    end
    return
  end
  if t - waiting.applied_at >= LOCAL_SETTLE_MIN and not deps.animating() then
    st.result = { ok = true }
  end
end

--- 最后一步之后: 停留一会儿再退出. 胜利界面停得久一些.
local function finish_replay()
  sendInfoMessage(string.format("Replay finished: %d actions", #data.actions), LOGGER)
  deps.recorder.annotate("replay", { source = data.source, pacing = cfg.pacing, ok = true, steps = #data.actions })
  -- 已经回到主菜单时录制已结束, 不用再停.
  local hold = deps.recorder.current() and cfg.end_hold or 0.5
  if deps.overlay.kind() == "win" or G.STATE == G.STATES.GAME_OVER then
    hold = hold + cfg.win_hold
  end
  finish_later(0, hold)
end

--- 处理一步的响应.
local function handle_result(t)
  local result = st.result
  local waiting = st.waiting
  st.result = nil
  st.waiting = nil
  st.prev_done = t
  if waiting.synthetic then
    return
  end
  local action = st.running
  st.running = nil
  st.reference = action.wall_end or action.wall or st.reference

  if action.ok == true and not result.ok then
    diverge("原局成功, 回放失败: " .. tostring(result.error))
    return
  end
  if deps.format.usable_digest(action.digest) and result.ok then
    local response = result.response
    local overlay = type(response) == "table" and response.overlay or deps.overlay.kind()
    if not deps.format.comparable(overlay) then
      -- 回放时这一步弹出了原局没有的解锁通知: 等通知关掉再比, 关通知不改变状态.
      st.deferred = { action = action, index = st.index }
    elseif action.manual then
      -- 手动步骤的摘要是人点下一步时取的, 那时画面已经停下 (例如跳过盲注后标签送的卡包已经打开),
      -- 而接口可能更早返回. 等动画停下再比, 比的是当时的状态而不是接口的返回.
      st.verify = { action = action, index = st.index, since = t, started = t, settle = true, advance = true }
      set_phase("verify")
      return
    else
      local digest = type(response) == "table" and response.state ~= nil and deps.format.digest(response)
        or deps.format.digest(deps.gamestate.get_gamestate())
      local diff = deps.format.diff(action.digest, digest)
      if diff then
        st.verify = { action = action, index = st.index, since = t, diff = diff, advance = true }
        set_phase("verify")
        return
      end
    end
  end
  st.index = st.index + 1
end

--- 摘要不一致: 动画中金钱等数值可能晚一帧, 在 verify_window 内反复确认.
local function verify_tick(t)
  local v = st.verify
  if v.settle and t - v.started < cfg.settle_max then
    -- 动画没停, 或者刚做完 (它触发的事件可能还没排进队列): 确认窗口从停下的那一刻算起.
    if t - v.started < cfg.tight_gap or deps.animating() then
      v.since = t
      return
    end
  end
  local diff = deps.format.diff(v.action.digest, deps.format.digest(deps.gamestate.get_gamestate()))
  if not diff then
    st.verify = nil
    if v.advance then
      st.index = st.index + 1
    end
    set_phase("run")
    return
  end
  v.diff = diff
  if t - v.since >= cfg.verify_window then
    st.verify = nil
    diverge("状态不一致: " .. diff, v.index)
  end
end

local function run_tick(t)
  if st.waiting then
    if not st.result and st.waiting.pending ~= nil then
      local_tick(t)
    end
    if st.result then
      handle_result(t)
      return
    end
    local limit = st.waiting.synthetic and 30 or deps.format.timeout(st.running or {}, 20, 180)
    if t - st.waiting.sent > limit then
      diverge(string.format("等待 %s 的响应超过 %d 秒", st.waiting.method, limit))
    end
    return
  end

  local kind = deps.overlay.kind()
  if kind ~= st.overlay_kind then
    st.overlay_kind = kind
    st.overlay_since = t
  end
  local action = data.actions[st.index]

  if kind == "unlock" then
    if not unlock_ready(action, t) then
      return
    end
    if action and action.method == "continue" then
      run_action(action)
    else
      dispatch("continue", nil, nil, true)
    end
    return
  end

  if kind == "win" then
    if not deps.overlay.win_settled() then
      st.overlay_since = t
      return
    end
    if t - st.overlay_since < cfg.win_hold then
      return
    end
    if not action then
      finish_replay()
      return
    end
    if cfg.pacing == "original" and t - st.prev_done < deps.format.original_gap(action, st.reference) then
      return
    end
    run_action(action)
    return
  end

  if kind == "other" then
    if t - st.overlay_since > cfg.overlay_grace then
      diverge("出现了原局没有的弹窗")
    end
    return
  end

  -- 被解锁通知推迟的比对, 通知关掉后补上.
  if st.deferred then
    local deferred = st.deferred
    st.deferred = nil
    st.verify = { action = deferred.action, index = deferred.index, since = t, advance = false }
    set_phase("verify")
    return
  end

  if not action then
    finish_replay()
    return
  end

  -- 原局里失败的操作不重做, 它的耗时算进下一步的间隔.
  if not deps.format.should_run(action) then
    st.index = st.index + 1
    return
  end

  -- 原局里关解锁通知的 continue, 回放时通知没弹出就跳过.
  if action.method == "continue" then
    if t - st.prev_done < cfg.continue_grace then
      return
    end
    st.reference = action.wall_end or action.wall or st.reference
    st.index = st.index + 1
    return
  end

  -- 原局在胜利界面上选的无尽模式, 回放时等胜利界面出现.
  if action.method == "endless" then
    if t - st.prev_done > cfg.overlay_grace then
      diverge("没有出现胜利界面")
    end
    return
  end

  -- 游戏结束界面暂停了游戏, 动画判定一直是停下; 先让观众看一会儿再回主菜单.
  if G.STATE == G.STATES.GAME_OVER and t - st.prev_done < cfg.win_hold then
    return
  end

  if gap_ready(action, t) then
    run_action(action)
  end
end

--- 开局钩子与响应钩子, 启动时装一次, 两种入口共用. 钩子内部都看回放状态, 不在回放时没有影响.
local function install_hooks()
  -- 原局没有指定种子时, 回放用同一个种子开局后把 seeded 改回去: 它影响解锁, 发现与界面上的种子框.
  local start_run = Game.start_run
  function Game:start_run(args) ---@diagnostic disable-line: duplicate-set-field
    start_run(self, args)
    if data and st.phase == "starting" and not data.run.resumed and G.GAME then
      G.GAME.seeded = data.run.seeded and true or false
    end
  end

  deps.activity.on("response", function(method, ok, message, response)
    if st.waiting and st.waiting.method == method and not st.result then
      st.result = { ok = ok, error = message, response = response }
    end
  end)
end

---@param options table
function M.init_early(options)
  deps = options
  install_hooks()
  local path = os.getenv("BALATROBOT_REPLAY")
  if not path or path == "" then
    return
  end
  -- 启动时没有别的东西在操作游戏, 这里只是登记, 让 balatrobot 不开端口.
  deps.control.claim(OWNER)
  M.active = true
  st = { phase = "boot", phase_at = now(), index = 1, prev_done = now(), last_busy = now(), reference = 0 }

  local pacing = os.getenv("BALATROBOT_REPLAY_PACING")
  if pacing == "tight" or pacing == "original" then
    cfg.pacing = pacing
  end
  cfg.unlock_hold = env_number("BALATROBOT_REPLAY_UNLOCK_HOLD", cfg.unlock_hold)
  cfg.win_hold = env_number("BALATROBOT_REPLAY_WIN_HOLD", cfg.win_hold)
  cfg.end_hold = env_number("BALATROBOT_REPLAY_END_HOLD", cfg.end_hold)
  cfg.tight_gap = env_number("BALATROBOT_REPLAY_GAP", cfg.tight_gap)
  set_replay_toast(true)

  local decoded, problem = read_data(path)
  if problem then
    sendErrorMessage("Replay unavailable: " .. problem, LOGGER)
    st.problem = problem
    data = nil
  else
    data = decoded
    sendInfoMessage(
      string.format("Replay loaded: %s, %d actions, pacing %s", path, #data.actions, cfg.pacing),
      LOGGER
    )
  end
  update_status()
end

--- 装在其它输入钩子之外, 必须在录制与回放文件初始化之后调用.
function M.init_late()
  if M.active then
    deps.input_lock.install()
  end
end

--- 回放开始前的提示: 局里有手动操作, 版本不一致, 以及恢复存档进度时的提示 (extra).
--- 逐条弹出, 返回读完它们要等的秒数.
---@param extra string[]?
---@param duration number? 每条的停留时长, 默认按阅读时长
---@return number
local function show_warnings(extra, duration)
  local list = {}
  local manual = data.manual_inputs or 0
  if manual > 0 then
    list[#list + 1] = string.format(
      "原局里有 %d 次手动操作, 回放只重做 agent 的操作和弹窗上的选择, 结果可能与原局不同",
      manual
    )
  end
  if data.game_version ~= deps.game_version or data.mod_version ~= deps.mod_version then
    list[#list + 1] = string.format(
      "原局版本 %s / %s, 当前 %s / %s, 结果可能不同",
      tostring(data.game_version),
      tostring(data.mod_version),
      tostring(deps.game_version),
      tostring(deps.mod_version)
    )
  end
  for _, text in ipairs(extra or {}) do
    list[#list + 1] = text
  end
  local wait = 0
  for _, text in ipairs(list) do
    sendWarnMessage("Replay warning: " .. text, LOGGER)
    toast("回放警告", text, duration)
    wait = wait + deps.toast.duration_for(text) + 0.5
  end
  return wait
end

local function start_run_request()
  local run = data.run
  -- 先切阶段: start_run 钩子据此判断这次开局是回放发起的.
  set_phase("starting")
  -- 教程局的强制内容 (优惠券, 标签, 商店牌) 来自 G.SETTINGS 的教程状态, 开局前换成回放用的那份.
  if deps.format.is_tutorial(run) then
    deps.tutorial.install()
  end
  if run.resumed then
    -- 读档开局: 把存档写成一个临时文件交给 load. 游戏内回放结束时由 session 删掉.
    local name = "replay_resume.jkr"
    if st.ingame then
      deps.session.add_temp_file(name)
    end
    love.filesystem.write(name, run.save)
    dispatch("load", { path = love.filesystem.getSaveDirectory() .. "/" .. name }, nil, false)
  else
    dispatch("start", { deck = run.deck, stake = run.stake, seed = run.seed }, nil, false)
  end
end

--- 游戏内开始一次回放. 由 选项 -> 回放 的确认页调用, 此时人在主菜单上.
--- 存档隔离 (session.begin) 由调用方先做好, 收尾由这里的 finish_ingame 调 session.finish.
---@param options {path: string, pacing: string?, on_finish: fun(code: integer, warnings: string[])?}
---@return boolean ok
---@return string? reason
function M.start(options)
  if M.active then
    return false, "回放已经在进行"
  end
  local claimed, blocker = deps.control.claim(OWNER)
  if not claimed then
    return false, tostring(blocker) .. " 正在运行, 先停止再回放"
  end
  local decoded, problem = read_data(options.path)
  if problem then
    deps.control.release(OWNER)
    return false, problem
  end
  cfg.pacing = options.pacing == "original" and "original" or "tight"
  -- 回放期间不写盘: 待弹的解锁通知也保持磁盘上的原样, 回放里没有的通知就跳过对应步骤.
  local ok, result = pcall(deps.snapshot.apply, decoded.snapshot, { write_notify = false })
  if not ok then
    deps.control.release(OWNER)
    return false, "恢复存档进度失败: " .. tostring(result)
  end
  data = decoded
  st = {
    phase = "warn",
    phase_at = now(),
    index = 1,
    prev_done = now(),
    last_busy = now(),
    reference = 0,
    ingame = true,
    on_finish = options.on_finish,
  }
  M.active = true
  set_replay_toast(true)
  st.warn_until = now() + show_warnings(result, 4)
  deps.input_lock.install()
  deps.recorder.annotate("replay", { source = data.source, file = options.path, pacing = cfg.pacing, entry = "ingame" })
  sendInfoMessage(string.format("游戏内回放开始: %s, %d 步, 节奏 %s", options.path, #data.actions, cfg.pacing), LOGGER)
  toast("回放中", ABORT_HINT, deps.toast.duration_for(ABORT_HINT))
  update_status()
  return true
end

function M.update()
  if not M.active then
    return
  end
  local t = now()
  local progress = deps.input_lock.abort_progress()
  if progress > 0 and st.phase ~= "ending" and st.phase ~= "quit" then
    -- 按住期间显示进度, 松手后按下一次刷新 (0.3 秒) 收起.
    deps.stream.show_status(string.format("松开: 中止回放 (%d%%)", math.floor(progress * 100 + 0.5)), 0.3)
  end
  if progress >= 1 and st.phase ~= "ending" and st.phase ~= "quit" then
    sendWarnMessage("Replay aborted by user", LOGGER)
    toast("回放中止", "用户中止了回放", 3)
    deps.recorder.annotate("replay", { source = data and data.source, pacing = cfg.pacing, ok = false, aborted = true, step = st.index })
    finish_later(2, 1)
  end
  if deps.animating() then
    st.last_busy = t
  end

  local phase = st.phase
  if phase == "boot" then
    -- 等主菜单. 临时存档里积压的解锁通知直接关掉, 这时还没开始录制.
    if deps.overlay.kind() == "unlock" then
      G.FUNCS.continue_unlock()
      return
    end
    if G.STATE == G.STATES.MENU and G.MAIN_MENU_UI and not G.OVERLAY_MENU and t - st.phase_at > 1 then
      if st.problem then
        toast("无法回放", st.problem, 6)
        finish_later(3, 6)
        return
      end
      local ok, result = pcall(deps.snapshot.apply, data.snapshot)
      if not ok then
        st.problem = "恢复存档进度失败: " .. tostring(result)
        sendErrorMessage(st.problem, LOGGER)
        toast("无法回放", st.problem, 6)
        finish_later(3, 6)
        return
      end
      st.warn_until = t + show_warnings(result)
      set_phase("warn")
    end
  elseif phase == "warn" then
    if t >= st.warn_until then
      start_run_request()
    end
  elseif phase == "starting" then
    if st.result then
      local result = st.result
      st.result, st.waiting = nil, nil
      if not result.ok then
        diverge("开局失败: " .. tostring(result.error))
        return
      end
      deps.recorder.annotate("replay", { source = data.source, pacing = cfg.pacing })
      -- 第一步的参照点是原局里开局请求完成的时间.
      st.reference = data.run.start_end or 0
      st.prev_done = t
      set_phase("run")
    elseif t - st.phase_at > 60 then
      diverge("开局超过 60 秒没有完成")
    end
  elseif phase == "run" then
    run_tick(t)
  elseif phase == "verify" then
    verify_tick(t)
  elseif phase == "ending" then
    if t >= st.quit_at then
      set_phase("quit")
      deps.input_lock.release()
      if st.ingame then
        finish_ingame()
      else
        love.event.quit(st.exit_code)
      end
    end
  end
  update_status()
end

return M
