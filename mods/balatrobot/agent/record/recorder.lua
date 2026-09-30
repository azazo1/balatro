--[[
整局录制. 由 BALATROBOT_RECORD=on 开启, 每局 (start_run 到回主菜单/下一局/退出) 输出:
- <stem>-full.mp4: 按墙钟原样录制, 带声音.
- <stem>-cut.mp4: 同一份素材剪掉 agent 思考时的无意义等待, 见 record/cuts.lua.
- <stem>.json: 关键时间点, 同时给出两份视频里的时间.
两份视频在局末由后台脚本生成 (record/post.lua), 录制中只写中间文件 <stem>.video.mp4 与 <stem>.pcm.

画面: 录制期间把 "画到屏幕" 的 setCanvas 调用改到一张全分辨率的 frame canvas, love.draw 结束后
画回屏幕, 再缩放到录制尺寸读出像素, 交给编码线程写进 ffmpeg. CRT, smods 屏幕着色器, 通知都在里面.
帧数按墙钟计算 (第 n 帧对应开局后 n/fps 秒), 卡顿时重复上一帧, 与录音保持同步.
声音: 见 record/audio.lua.
剪辑: 活动 = agent 请求处理中, 通知在屏幕上, 或者动画还没停下; 前后各留 pre/post 秒.

环境变量:
- BALATROBOT_RECORD_DIR     输出目录, 默认 <存档目录>/recordings
- BALATROBOT_RECORD_FPS     默认 30
- BALATROBOT_RECORD_HEIGHT  默认 720, 宽度按窗口比例, 取偶数
- BALATROBOT_RECORD_PRE     剪辑版在每次活动前保留的秒数, 默认 0.6
- BALATROBOT_RECORD_POST    剪辑版在动画停下后保留的秒数, 默认 0.8
- BALATROBOT_RECORD_PREFIX  输出文件名前缀, 默认为空, 回放时为 replay-
- BALATROBOT_FFMPEG         ffmpeg 路径, 默认在 PATH, /opt/homebrew/bin, /usr/local/bin 中查找
- BALATROBOT_RECORD_CODEC   videotoolbox 或 x264, 默认 ffmpeg 支持时用 videotoolbox (macOS 硬件编码)
                            x264 画质体积比更好, 但与游戏争抢 CPU, 动画多时游戏会掉帧
]]

local LOGGER = "BB.AGENT.RECORD"
local MAX_QUEUE = 8
local START_GRACE = 1.5 -- 开局后固定算作活动的秒数, 覆盖开局动画
local QUIT_WAIT = 5
local MIN_GAP = 1.5 -- 剪掉的部分短于它时不剪
-- 动画判定的上限: 距上次请求, 通知, 状态变化或手动输入超过这么久, 即使还有未完成的阻塞事件
-- 也视为停下, 防止某个一直挂着的事件让剪辑版一刀都剪不掉.
local SETTLE_MAX = 10

local Cuts, Timeline, Audio, Post -- 在 init 中加载

local M = {
  enabled = false,
  status = "off",
}

local cfg = {}
local deps = {} -- activity, toast, mod_path
local session = nil
local finishing = {} -- 已结束但编码线程还在收尾的录制
local redirect = false -- 本局是否录视频
local drawing = false -- 正在执行被包装的 love.draw
local frame_canvas = nil
local set_canvas = love.graphics.setCanvas
local last_input = -math.huge -- 最近一次手动输入 (鼠标, 键盘, 手柄)

local function now()
  return love.timer.getTime()
end

local function env_number(name, default)
  local value = tonumber(os.getenv(name) or "")
  if value and value > 0 then
    return value
  end
  return default
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function is_executable(path)
  local ok, _, code = os.execute(shell_quote(path) .. " -version >/dev/null 2>&1")
  -- LuaJIT 下 os.execute 返回退出码数字, 5.2 语义下返回 true/nil
  return ok == 0 or ok == true or code == 0
end

local function find_ffmpeg()
  local explicit = os.getenv("BALATROBOT_FFMPEG")
  if explicit and explicit ~= "" then
    return is_executable(explicit) and explicit or nil
  end
  for _, candidate in ipairs({ "ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" }) do
    if is_executable(candidate) then
      return candidate
    end
  end
  return nil
end

local CODEC_ARGS = {
  -- 硬件编码, CPU 占用约为 x264 veryfast 的 1/4, 同画质下体积约大一倍.
  videotoolbox = "-c:v h264_videotoolbox -q:v 65 -realtime 1",
  x264 = "-c:v libx264 -preset veryfast -crf 20",
}

local function pick_codec(ffmpeg)
  local wanted = os.getenv("BALATROBOT_RECORD_CODEC")
  if wanted and CODEC_ARGS[wanted] then
    return wanted
  end
  local pipe = io.popen(shell_quote(ffmpeg) .. " -hide_banner -encoders 2>/dev/null")
  local list = pipe and pipe:read("*a") or ""
  if pipe then
    pipe:close()
  end
  return list:find("h264_videotoolbox", 1, true) and "videotoolbox" or "x264"
end

local function state_name(value)
  for name, v in pairs(G.STATES) do
    if v == value then
      return name
    end
  end
  return tostring(value)
end

local function run_info()
  local game = G.GAME or {}
  return {
    ante = game.round_resets and game.round_resets.ante or 0,
    round = game.round or 0,
    money = game.dollars or 0,
  }
end

-- ==========================================================================
-- 画面
-- ==========================================================================

local function targets_screen(...)
  local n = select("#", ...)
  if n == 0 then
    return true
  end
  local first = ...
  if first == nil then
    return true
  end
  -- 表形式 {canvas, depthstencil = ...}: 第一项为空时也是画到屏幕
  return type(first) == "table" and first[1] == nil and not first.depthstencil
end

-- 只在 love.draw 执行期间重定向. 其余时候 (崩溃界面, 截图回调等) 画到屏幕的调用保持原样.
local function wrapped_set_canvas(...)
  if drawing and frame_canvas and targets_screen(...) then
    return set_canvas({ frame_canvas, stencil = true })
  end
  return set_canvas(...)
end

-- 与屏幕同尺寸同 dpi, 画回屏幕时 1:1.
local function ensure_frame_canvas()
  local w, h = love.graphics.getDimensions()
  local dpi = love.graphics.getDPIScale()
  if
    not frame_canvas
    or frame_canvas:getWidth() ~= w
    or frame_canvas:getHeight() ~= h
    or frame_canvas:getDPIScale() ~= dpi
  then
    if frame_canvas then
      frame_canvas:release()
    end
    frame_canvas = love.graphics.newCanvas(w, h, { dpiscale = dpi })
  end
end

--[[
截帧分两步, 避免掉帧:
- stage: 本帧末尾在 GPU 上把画面缩放到一张录制画布, 不读回.
- collect: READ_DELAY 帧之后, 在 love.draw 开头读回.
读回 (newImageData) 会等这张画布之前的 GPU 命令执行完. 当帧读回时 CPU 要等 GPU 画完整帧,
开着 vsync 的游戏从 60fps 掉到 35fps 左右; 延迟一帧仍会与帧末 present 互相等待.
延迟两帧时那部分命令早已执行完, 读回不再阻塞. 录制画布轮流使用, 视频晚于屏幕两帧, 时长不变.
]]
local READ_DELAY = 2
local rec_pool = {} -- 录制画布
local staged = {} -- {canvas, count, frame}, 按时间顺序
local draw_frame = 0

local function free_rec_canvas(w, h)
  for _, canvas in ipairs(rec_pool) do
    local busy = false
    for _, item in ipairs(staged) do
      if item.canvas == canvas then
        busy = true
        break
      end
    end
    if not busy and canvas:getPixelWidth() == w and canvas:getPixelHeight() == h then
      return canvas
    end
  end
  local canvas = love.graphics.newCanvas(w, h, { dpiscale = 1 })
  rec_pool[#rec_pool + 1] = canvas
  return canvas
end

local function stage_frame(s, count)
  local canvas = free_rec_canvas(s.size[1], s.size[2])
  local sw, sh = frame_canvas:getDimensions()
  local rw, rh = s.size[1], s.size[2]
  local scale = math.min(rw / sw, rh / sh)
  love.graphics.push("all")
  set_canvas(canvas)
  love.graphics.origin()
  love.graphics.setShader()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("alpha")
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.draw(frame_canvas, (rw - sw * scale) / 2, (rh - sh * scale) / 2, 0, scale, scale)
  set_canvas()
  love.graphics.pop()
  staged[#staged + 1] = { canvas = canvas, count = count, frame = draw_frame }
end

local function push_frame(s, canvas, count)
  local image = canvas:newImageData()
  local frames = s.frames
  -- 不丢帧: 编码跟不上时等它, 保证视频时长与时间线一致.
  local waited = 0
  while frames:getCount() >= MAX_QUEUE and waited < 2 do
    if not s.thread:isRunning() then
      break
    end
    love.timer.sleep(0.002)
    waited = waited + 0.002
  end
  frames:push({ image = image, count = count })
  image:release()
end

--- 读回已到期的帧. force 为 true 时 (录制结束) 全部读回.
---@return integer 读回的张数
local function collect_frames(s, force)
  local n = 0
  while staged[1] and (force or draw_frame - staged[1].frame >= READ_DELAY) do
    local item = table.remove(staged, 1)
    if s.thread and item.count > 0 then
      push_frame(s, item.canvas, item.count)
      n = n + 1
    end
  end
  return n
end

-- ==========================================================================
-- 编码
-- ==========================================================================

local function start_encoder(video_path, log_path, w, h)
  local command = table.concat({
    shell_quote(cfg.ffmpeg),
    "-y -loglevel error -f rawvideo -pix_fmt rgba",
    "-s " .. w .. "x" .. h,
    "-r " .. cfg.fps,
    "-i -",
    CODEC_ARGS[cfg.codec],
    "-pix_fmt yuv420p",
    -- fragmented mp4: 游戏中途崩溃时已写入的部分仍可播放
    "-movflags +frag_keyframe+empty_moov+default_base_moof",
    shell_quote(video_path),
    "2>" .. shell_quote(log_path),
  }, " ")
  local source = SMODS.NFS.read(deps.mod_path .. "agent/record/encoder_thread.lua")
  local thread = love.thread.newThread(love.filesystem.newFileData(source, "bb_encoder_thread.lua"))
  local frames = love.thread.newChannel()
  local status = love.thread.newChannel()
  thread:start(command, frames, status)
  return thread, frames, status
end

local function drain_status(item)
  while true do
    local msg = item.status:pop()
    if not msg then
      break
    end
    if msg.kind == "error" then
      item.error = msg.message
      sendWarnMessage("Recording " .. item.stem .. ": " .. msg.message, LOGGER)
    elseif msg.kind == "done" then
      item.done = msg
    end
  end
  local thread_err = item.thread:getError()
  if thread_err and not item.error then
    item.error = thread_err
    sendErrorMessage("Recording " .. item.stem .. " encoder crashed: " .. thread_err, LOGGER)
  end
end

---@param part table? {thread, status, done, error}
---@return boolean
local function part_finished(part)
  if not part then
    return true
  end
  drain_status(part)
  return part.done ~= nil or part.error ~= nil or not part.thread:isRunning()
end

--- 画面与声音都写完后启动后台合成. force 为 true 时 (退出前等不及了) 直接启动.
---@param item table
---@param force boolean
---@return boolean started
local function try_post(item, force)
  if not force and not (part_finished(item.video) and part_finished(item.audio)) then
    return false
  end
  local video_done = item.video and item.video.done or {}
  local audio_ok = item.audio ~= nil and not item.audio.error
  if audio_ok then
    local file = io.open(item.post.base .. ".pcm", "rb")
    local size = file and file:seek("end") or 0
    if file then
      file:close()
    end
    audio_ok = size > 0
  end
  item.post.audio = audio_ok
  local ok, err = Post.spawn(item.post)
  sendInfoMessage(
    string.format(
      "Recording %s: %d frames, audio %s, building -full.mp4 and -cut.mp4 in background%s",
      item.stem,
      video_done.frames or 0,
      audio_ok and "ok" or "missing",
      ok and "" or (" (failed to start: " .. tostring(err) .. ")")
    ),
    LOGGER
  )
  return true
end

local function poll_finishing(block_until)
  local kept = {}
  for _, item in ipairs(finishing) do
    local started = try_post(item, false)
    while not started and block_until and now() < block_until do
      love.timer.sleep(0.01)
      started = try_post(item, false)
    end
    if not started and block_until then
      started = try_post(item, true)
    end
    if not started then
      kept[#kept + 1] = item
    end
  end
  finishing = kept
end

-- ==========================================================================
-- 会话
-- ==========================================================================

--- 当前时刻算作活动, 返回它在完整版与剪辑版里的时间.
---@return number wall
---@return number cut
local function mark_now(s)
  local wall = now() - s.started
  s.cuts:mark(wall)
  s.last_busy = now()
  return wall, s.cuts:cut_time(wall)
end

--- 记一个事件, 同时算作活动, 保证事件所在的时刻留在剪辑版里.
---@return table event
local function log_event(s, kind, fields)
  local wall, cut = mark_now(s)
  return s.timeline:event(wall, cut, kind, fields)
end

local function start_session(resumed)
  local game = G.GAME or {}
  local seed = game.pseudorandom and game.pseudorandom.seed or "noseed"
  local stem = cfg.prefix .. os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(seed):gsub("[^%w%-_]", "")
  local base = cfg.dir .. "/" .. stem

  local sw, sh = love.graphics.getPixelDimensions()
  local h = cfg.height - cfg.height % 2
  local w = math.floor(h * sw / sh + 0.5)
  w = w - w % 2

  local meta = {
    fps = cfg.fps,
    size = { w, h },
    videos = cfg.ffmpeg and { full = stem .. "-full.mp4", cut = stem .. "-cut.mp4" } or nil,
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    deck = game.selected_back and game.selected_back.name or nil,
    stake = game.stake,
    seed = seed,
    seeded = game.seeded or false,
    resumed = resumed,
    padding = { pre = cfg.pre, post = cfg.post, min_gap = MIN_GAP },
  }

  session = {
    stem = stem,
    base = base,
    started = now(),
    last_busy = now(),
    cuts = Cuts.new({ pre = cfg.pre, post = cfg.post, min_gap = MIN_GAP }),
    timeline = Timeline.new(base .. ".json", meta),
    size = { w, h },
    frames_out = 0, -- 已交给画面的帧数 (含待写出的 pending)
    pending = 0,
    last_state = G.STATE,
    last_blind = nil,
    won = game.won or false,
  }
  log_event(session, "run_start", { resumed = resumed })

  if cfg.ffmpeg then
    local audio, audio_err = Audio.start(deps.mod_path, base .. ".pcm", session.started)
    if audio then
      session.audio = audio
    else
      sendWarnMessage("Recording without sound: " .. tostring(audio_err), LOGGER)
    end
  end

  if cfg.ffmpeg then
    -- 尺寸变了 (窗口比例不同) 时旧画布不再能用, 释放掉.
    local kept = {}
    for _, canvas in ipairs(rec_pool) do
      if canvas:getPixelWidth() == w and canvas:getPixelHeight() == h then
        kept[#kept + 1] = canvas
      else
        canvas:release()
      end
    end
    rec_pool = kept
    local ok, thread, frames, status = pcall(start_encoder, base .. ".video.mp4", base .. ".ffmpeg.txt", w, h)
    if ok then
      session.thread, session.frames, session.status = thread, frames, status
      redirect = true
    else
      sendErrorMessage("Failed to start encoder: " .. tostring(thread), LOGGER)
      session.timeline:set("videos", nil)
    end
  end
  session.timeline:set("audio", session.audio ~= nil)
  session.timeline:flush(now(), true)
  M.status = "recording " .. stem
  sendInfoMessage(
    string.format("Recording started: %s (%dx%d@%d, sound %s)", base, w, h, cfg.fps, session.audio and "on" or "off"),
    LOGGER
  )
end

--- 把画面帧数补到墙钟时间 wall 对应的帧.
local function advance_frames(s, wall)
  local target = math.floor(wall * cfg.fps + 1e-9)
  if target > s.frames_out then
    s.pending = s.pending + (target - s.frames_out)
    s.frames_out = target
  end
end

local function end_session(reason)
  if not session then
    return
  end
  local s = session
  session = nil
  redirect = false

  local wall = now() - s.started
  advance_frames(s, wall)
  -- 写出还没读回的帧. 已计入但还没画的帧用最后一帧补齐, 画面与声音等长.
  if s.thread and frame_canvas then
    if s.pending > 0 then
      if #staged > 0 then
        staged[#staged].count = staged[#staged].count + s.pending
      else
        stage_frame(s, s.pending) -- frame_canvas 里是屏幕上的最后一帧
      end
      s.pending = 0
    end
    collect_frames(s, true)
  end
  staged = {}
  local length = s.frames_out / cfg.fps -- 视频的实际长度
  s.cuts:finish(length)
  local info = run_info()
  -- 回主菜单时 G.GAME 可能已重置, 以本局记录到的 won 事件为准.
  local won = s.won or (G.GAME and G.GAME.won) or false
  local result = { reason = reason, won = won, ante = info.ante, round = info.round }
  s.timeline:event(length, s.cuts:cut_time(length), "run_end", result)
  s.timeline:set("result", result)
  s.timeline:sync_cuts(s.cuts, length)
  local ok, err = s.timeline:flush(now(), true)
  if not ok then
    sendErrorMessage("Failed to write timeline: " .. tostring(err), LOGGER)
  end

  if s.audio then
    Audio.stop(s.audio, length)
  end
  if s.thread then
    s.frames:push("stop")
    finishing[#finishing + 1] = {
      stem = s.stem,
      video = { stem = s.stem, thread = s.thread, status = s.status },
      audio = s.audio and { stem = s.stem, thread = s.audio.thread, status = s.audio.status } or nil,
      post = {
        ffmpeg = cfg.ffmpeg,
        codec_args = CODEC_ARGS[cfg.codec]:gsub(" %-realtime 1", ""),
        base = s.base,
        fps = cfg.fps,
        cuts = s.cuts.list,
      },
    }
  end
  M.status = "on"
  sendInfoMessage(
    string.format(
      "Recording ended (%s): full %.1fs, cut %.1fs, %d cuts removing %.1fs",
      reason,
      length,
      length - s.cuts.removed,
      #s.cuts.list,
      s.cuts.removed
    ),
    LOGGER
  )
end

local function track_state(s)
  local state = G.STATE
  if state ~= s.last_state then
    s.last_state = state
    local name = state_name(state)
    -- 状态变化本身算作活动: 它会带出动画, 不记事件的过渡状态也一样.
    mark_now(s)
    if name:match("^%-?%d+$") then
      -- 不在 G.STATES 里的过渡值, 例如 delete_run 设置的 -1
    elseif state == G.STATES.GAME_OVER then
      local info = run_info()
      log_event(s, "game_over", { won = G.GAME.won or false, ante = info.ante, round = info.round })
    elseif state == G.STATES.SELECTING_HAND then
      local blind = G.GAME.blind
      local key = blind and blind.config and blind.config.blind and blind.config.blind.key or nil
      local id = tostring(key) .. "@" .. tostring(G.GAME.round)
      if blind and id ~= s.last_blind then
        s.last_blind = id
        log_event(s, "blind", { key = key, name = blind.name, round = G.GAME.round })
      end
    elseif name ~= "HAND_PLAYED" and name ~= "DRAW_TO_HAND" and name ~= "NEW_ROUND" and name ~= "PLAY_TAROT" then
      local info = run_info()
      log_event(s, "state", { state = name, ante = info.ante, round = info.round, money = info.money })
    end
  end
  if G.GAME and G.GAME.won and not s.won then
    s.won = true
    local info = run_info()
    log_event(s, "won", { ante = info.ante, round = info.round })
  end
end

--- 画面还在动: 有未完成的阻塞事件 (发牌, 计分, 翻牌等动画都是), 或者控制器被锁住.
--- 暂停时 (弹窗打开) 事件都停着, 算作停下.
local function animating()
  if G.SETTINGS.paused then
    return false
  end
  if G.CONTROLLER and G.CONTROLLER.locked then
    return true
  end
  for _, queue in pairs(G.E_MANAGER.queues) do
    for _, event in ipairs(queue) do
      if event.blocking and not event.complete then
        return true
      end
    end
  end
  return false
end

-- ==========================================================================
-- 对外接口
-- ==========================================================================

local ENABLE_VALUES = { on = true, ["1"] = true, ["true"] = true, yes = true }

--- 画面是否还在动, 回放的 tight 节奏据此等动画停下.
M.animating = animating

--- 正在录制的一局: stem, base (不含扩展名的输出路径), started (love.timer 时间). 没有时为 nil.
---@return {stem: string, base: string, started: number}?
function M.current()
  local s = session
  return s and { stem = s.stem, base = s.base, started = s.started } or nil
end

--- 给正在录制的一局的时间线加一个顶层字段.
---@param key string
---@param value any
function M.annotate(key, value)
  if session then
    session.timeline:set(key, value)
  end
end

---@param options {activity: table, toast: table, mod_path: string}
function M.init(options)
  deps = options
  local mode = os.getenv("BALATROBOT_RECORD")
  if not ENABLE_VALUES[mode or ""] then
    M.status = "off"
    return
  end
  if BB_SETTINGS.headless or BB_SETTINGS.render_on_api then
    M.status = "unavailable (headless/render_on_api)"
    sendWarnMessage("Recording disabled: headless and render_on_api modes have no frames to capture", LOGGER)
    return
  end

  Cuts = assert(SMODS.load_file("agent/record/cuts.lua"))()
  Timeline = assert(SMODS.load_file("agent/record/timeline.lua"))()
  Audio = assert(SMODS.load_file("agent/record/audio.lua"))()
  Post = assert(SMODS.load_file("agent/record/post.lua"))()

  cfg.fps = math.floor(env_number("BALATROBOT_RECORD_FPS", 30))
  cfg.height = math.floor(env_number("BALATROBOT_RECORD_HEIGHT", 720))
  cfg.pre = env_number("BALATROBOT_RECORD_PRE", 0.6)
  cfg.post = env_number("BALATROBOT_RECORD_POST", 0.8)
  -- 文件名前缀, 回放时为 "replay-", 与原局的录像区分.
  cfg.prefix = (os.getenv("BALATROBOT_RECORD_PREFIX") or ""):gsub("[^%w%-_]", "")
  local dir = os.getenv("BALATROBOT_RECORD_DIR")
  cfg.dir = (dir and dir ~= "") and dir:gsub("/+$", "") or (love.filesystem.getSaveDirectory() .. "/recordings")
  local created, err = SMODS.NFS.createDirectory(cfg.dir)
  if not created then
    M.status = "unavailable (output dir)"
    sendErrorMessage("Recording disabled: " .. tostring(err), LOGGER)
    return
  end
  cfg.ffmpeg = find_ffmpeg()
  if cfg.ffmpeg then
    cfg.codec = pick_codec(cfg.ffmpeg)
  end
  M.enabled = true
  M.status = cfg.ffmpeg and "on" or "on, ffmpeg not found (json only)"
  if not cfg.ffmpeg then
    sendWarnMessage("ffmpeg not found, recording writes timeline JSON only. Set BALATROBOT_FFMPEG to its path", LOGGER)
  end

  love.graphics.setCanvas = wrapped_set_canvas

  local activity = deps.activity
  activity.on("request", function(method, params, reason)
    if not session or method == "notify" then
      return
    end
    local fields = { method = method, reason = reason }
    if next(params) ~= nil then
      fields.params = params
    end
    session.open_action = log_event(session, "action", fields)
  end)
  activity.on("response", function(method, ok, message)
    if not session or not session.open_action or session.open_action.method ~= method then
      return
    end
    local event = session.open_action
    session.open_action = nil
    local wall, cut = mark_now(session)
    event.ok = ok
    event.error = message
    event.wall_end = math.floor(wall * 1000 + 0.5) / 1000
    event.cut_end = math.floor(cut * 1000 + 0.5) / 1000
    session.timeline.dirty = true
  end)
  activity.on("message", function(title, text, _, source)
    if not session or source ~= "notify" then
      return
    end
    log_event(session, "message", { title = title, text = text })
  end)

  -- 手动操作也算活动, 人玩的部分不会被剪掉.
  for _, name in ipairs({ "mousepressed", "keypressed", "gamepadpressed", "touchpressed" }) do
    local original = love[name]
    love[name] = function(...)
      last_input = now()
      if original then
        return original(...)
      end
    end
  end

  local start_run = Game.start_run
  function Game:start_run(args) ---@diagnostic disable-line: duplicate-set-field
    end_session("restart")
    start_run(self, args)
    start_session(args and args.savetext ~= nil or false)
  end

  local main_menu = Game.main_menu
  function Game:main_menu(change_context) ---@diagnostic disable-line: duplicate-set-field
    end_session("menu")
    return main_menu(self, change_context)
  end

  local quit = love.quit
  love.quit = function(...) ---@diagnostic disable-line: duplicate-set-field
    end_session("quit")
    poll_finishing(now() + QUIT_WAIT)
    if quit then
      return quit(...)
    end
  end

  sendInfoMessage(
    string.format(
      "Recording enabled: %d fps, height %d, padding %.1f/%.1fs, dir %s, ffmpeg %s, codec %s",
      cfg.fps,
      cfg.height,
      cfg.pre,
      cfg.post,
      cfg.dir,
      tostring(cfg.ffmpeg),
      tostring(cfg.codec)
    ),
    LOGGER
  )
end

--- 每帧在游戏 update 之后调用.
function M.update()
  local t = now()
  if #finishing > 0 then
    poll_finishing(nil)
  end
  local s = session
  if not s then
    return
  end
  if s.thread and not s.thread:isRunning() and redirect then
    drain_status({ stem = s.stem, status = s.status, thread = s.thread })
    sendErrorMessage("Encoder stopped unexpectedly, video recording disabled for this run", LOGGER)
    redirect = false
    s.thread = nil
  end

  local wall = t - s.started
  advance_frames(s, wall)
  if s.audio then
    Audio.tick()
  end

  -- 活动: 请求处理中, 通知在屏幕上, 开局动画, 手动操作; 之后动画还没停下的部分也算,
  -- 但距上一次活动最多 SETTLE_MAX 秒.
  local activity = deps.activity
  local busy = activity.busy(t) or deps.toast.active() or wall < START_GRACE or t - last_input < 1
  if busy then
    s.last_busy = t
  end
  if busy or (t - s.last_busy < SETTLE_MAX and animating()) then
    s.cuts:mark(wall)
  end

  track_state(s)
  s.timeline:sync_cuts(s.cuts, wall)
  local ok, err = s.timeline:flush(t, false)
  if not ok then
    sendWarnMessage("Failed to write timeline: " .. tostring(err), LOGGER)
  end
end

--- 包装 love.draw.
---@param draw function 原 love.draw
function M.draw(draw)
  local s = session
  if not (s and redirect) then
    return draw()
  end
  -- 读回 READ_DELAY 帧之前放进录制画布的画面. 此时本帧还没提交绘制.
  draw_frame = draw_frame + 1
  collect_frames(s, false)

  ensure_frame_canvas()
  set_canvas({ frame_canvas, stencil = true })
  love.graphics.clear(0, 0, 0, 1)

  drawing = true
  local ok, err = xpcall(draw, debug.traceback)
  drawing = false
  -- 先切回屏幕再做其他事. push("all")/pop 会恢复 push 时的画布, 必须在屏幕上调用,
  -- 否则帧末 present 时画布仍是 frame canvas, LÖVE 报错.
  set_canvas()

  if ok and s.pending > 0 and s.thread then
    stage_frame(s, s.pending)
    s.pending = 0
  end

  -- 无论 draw 是否出错, 都把画面还给屏幕.
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setShader()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("alpha")
  love.graphics.draw(frame_canvas, 0, 0)
  love.graphics.pop()

  if not ok then
    error(err, 0)
  end
end

return M
