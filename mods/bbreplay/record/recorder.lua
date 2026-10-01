--[[
整局录制. 由 BALATROBOT_RECORD=on 或设置页的录像开关开启, 每局 (start_run 到回主菜单/下一局/退出) 输出:
- <stem>-full.mp4: 按墙钟原样录制, 带声音.
- <stem>-cut.mp4: 同一份素材剪掉 agent 思考时的无意义等待, 见 record/cuts.lua.
- <stem>.json: 关键时间点, 同时给出两份视频里的时间.
两份视频在局末由后台脚本生成 (record/post.lua), 录制中只写中间文件 <stem>.video.mp4 与 <stem>.pcm.

崩溃时尽量少丢: 画面约 2 秒一个关键帧 (即一个分片) 并逐个落盘, 声音每秒 flush, 时间线每 2 秒写一次;
开局时就写出草稿合成脚本 <stem>.post.sh (Windows 上是 <stem>.post.cmd), 剪辑区间变多时覆盖, 局末用最终版覆盖并运行.
崩溃后用 sh <stem>.post.sh (Windows 上直接运行 .post.cmd) 或 scripts/recordings_recover.py 补做合成.
Windows 上 ffmpeg 与合成脚本都由 record/win_proc.lua 直接启动, 不弹控制台窗口.

给 agent 控制的接口: M.end_segment / M.start_segment (停止时立即结束一段), M.set_paused (暂停段在剪辑版里剪掉),
M.add_activity_source (额外的活动来源, 例如流式条).

画面: 录制期间把 "画到屏幕" 的 setCanvas 调用改到一张全分辨率的 frame canvas, love.draw 结束后
画回屏幕, 再缩放到录制尺寸读出像素, 交给编码线程写进 ffmpeg. CRT, smods 屏幕着色器, 通知都在里面.
帧数按墙钟计算 (第 n 帧对应开局后 n/fps 秒), 卡顿时重复上一帧, 与录音保持同步.
声音: 见 record/audio.lua.
剪辑: 活动 = agent 请求处理中, 通知在屏幕上, 额外活动来源, 或者动画还没停下; 前后各留 pre/post 秒.
agent 暂停期间一律不算活动.

环境变量:
- BALATROBOT_RECORD_DIR     输出目录, 默认 <存档目录>/recordings
- BALATROBOT_RECORD_FPS     帧率, 未设置时用设置页的值, 默认 30 (Android 24)
- BALATROBOT_RECORD_HEIGHT  画面高度, 宽度按窗口比例, 取偶数. 未设置时用设置页的值, 默认 720 (Android 540)
- BALATROBOT_RECORD_BITRATE 视频码率 (Mbps), 0 为自动. 未设置时用设置页的值, 默认自动
  三者的可选值与取舍见 record/quality.lua. 设置页改了之后从下一个录像段起生效, 正在录的一段不变.
- BALATROBOT_RECORD_PRE     剪辑版在每次活动前保留的秒数, 默认 0.6
- BALATROBOT_RECORD_POST    剪辑版在动画停下后保留的秒数, 默认 0.8
- BALATROBOT_RECORD_PREFIX  输出文件名前缀, 默认为空, 回放时为 replay-
- BALATROBOT_RECORD_KEEP    设为 keep 时合成成功后保留中间文件, 未设置时用设置页的保留方式
- BALATROBOT_FFMPEG         ffmpeg 路径, 默认在 PATH, /opt/homebrew/bin, /usr/local/bin 中查找
- BALATROBOT_RECORD_CODEC   videotoolbox 或 x264, 默认 ffmpeg 支持时用 videotoolbox (macOS 硬件编码)
                            x264 画质体积比更好, 但与游戏争抢 CPU, 动画多时游戏会掉帧
]]

local LOGGER = "BB.AGENT.RECORD"
-- 运行时加载自己的模块必须显式给出 mod id: SMODS.load_file 只在首次加载 mod 时才可以省 id,
-- 少了它会报 "No ID was provided!". 录像可能在运行中才装载 (设置页打开开关, 游戏内回放).
local MOD_ID = "bbreplay"
local MAX_QUEUE = 8
local START_GRACE = 1.5 -- 开局后固定算作活动的秒数, 覆盖开局动画
local QUIT_WAIT = 5
local MIN_GAP = 1.5 -- 剪掉的部分短于它时不剪
-- 动画判定的上限: 距上次请求, 通知, 状态变化或手动输入超过这么久, 即使还有未完成的阻塞事件
-- 也视为停下, 防止某个一直挂着的事件让剪辑版一刀都剪不掉.
local SETTLE_MAX = 10

local Cuts, Timeline, Audio, Post, Quality -- 在 setup 中加载

local M = {
  enabled = false,
  status = "off",
}

local setup_done = false
local ready = false -- setup 成功, 可以录制

local cfg = {}
local deps = {} -- activity, toast, mod_path
local session = nil
local finishing = {} -- 已结束但编码线程还在收尾的录制
local redirect = false -- 本局是否录视频
local drawing = false -- 正在执行被包装的 love.draw
local frame_canvas = nil
local set_canvas = love.graphics.setCanvas
local last_input = -math.huge -- 最近一次手动输入 (鼠标, 键盘, 手柄)
local paused = false -- agent 暂停中: 剪辑版剪掉这一段, 跨局保持, 见 M.set_paused
local activity_sources = {} -- 额外的活动来源, 见 M.add_activity_source

local function now()
  return love.timer.getTime()
end

--- 通知存档目录的权限模块修正一个路径 (Android 上用; 别的平台或模块不在时什么都不做).
--- 录像的输出与合成都不走 love.filesystem 的写包装 (编码线程, 后台脚本), 所以要单独通知一次;
--- 之后仍由失去焦点时的整树扫描兜底.
---@param path string
local function fix_permissions(path)
  local ok, storage = pcall(require, "android_storage")
  if ok and type(storage) == "table" and storage.fix_path then
    pcall(storage.fix_path, path)
  end
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

-- Windows 上不经过 shell 启动子进程 (见 record/win_proc.lua), 在 setup 里装载.
local WINDOWS = love._os == "Windows"
local WinProc

local function is_executable(path)
  if WINDOWS then
    return WinProc.run({ path, "-version" }, 10000) == 0
  end
  local ok, _, code = os.execute(shell_quote(path) .. " -version >/dev/null 2>&1")
  -- LuaJIT 下 os.execute 返回退出码数字, 5.2 语义下返回 true/nil
  return ok == 0 or ok == true or code == 0
end

--- ffmpeg 的候选位置. Windows 上 PATH 之外再看几个包管理器的固定位置 (装完没重新登录时 PATH 还没生效).
---@return string[]
local function ffmpeg_candidates()
  if not WINDOWS then
    return { "ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg" }
  end
  local list = { "ffmpeg" }
  local function add(root, rest)
    if root and root ~= "" then
      list[#list + 1] = root .. rest
    end
  end
  add(os.getenv("LOCALAPPDATA"), "\\Microsoft\\WinGet\\Links\\ffmpeg.exe") -- winget
  add(os.getenv("USERPROFILE"), "\\scoop\\shims\\ffmpeg.exe") -- scoop
  add(os.getenv("ProgramData"), "\\chocolatey\\bin\\ffmpeg.exe") -- choco
  list[#list + 1] = "C:\\ffmpeg\\bin\\ffmpeg.exe" -- 手动解压的常见位置
  return list
end

local function find_ffmpeg()
  local explicit = os.getenv("BALATROBOT_FFMPEG")
  if explicit and explicit ~= "" then
    return is_executable(explicit) and explicit or nil
  end
  for _, candidate in ipairs(ffmpeg_candidates()) do
    if is_executable(candidate) then
      return candidate
    end
  end
  return nil
end

-- 码率为自动时用固定画质参数, 体积随画面复杂度变化.
local CODECS = {
  -- 硬件编码, CPU 占用约为 x264 veryfast 的 1/4, 同画质下体积约大一倍.
  videotoolbox = { encoder = "-c:v h264_videotoolbox", quality = "-q:v 65" },
  x264 = { encoder = "-c:v libx264 -preset veryfast", quality = "-crf 20" },
}

--- 码率参数. mbps 为 0 时用固定画质; 否则给目标码率, x264 另限峰值, 免得动画密集处突然变大.
---@param codec string
---@param mbps number
---@return string
local function rate_args(codec, mbps)
  if not mbps or mbps <= 0 then
    return CODECS[codec].quality
  end
  local kbps = math.floor(mbps * 1000 + 0.5)
  if codec == "x264" then
    return string.format("-b:v %dk -maxrate %dk -bufsize %dk", kbps, math.floor(kbps * 1.5), kbps * 2)
  end
  return string.format("-b:v %dk", kbps)
end

--- 编码参数. live 为 true 时是录制中的实时编码: 约 2 秒一个关键帧, fragmented mp4 按关键帧分片,
--- 崩溃时最多丢约 2 秒画面. x264 默认 250 帧一个关键帧, 30fps 下超过 8 秒;
--- videotoolbox 默认约 0.4 秒一个, 分片过碎. 局末重新编码剪辑版时不需要这些.
---@param codec string
---@param fps integer
---@param mbps number 码率, 0 为自动
---@param live boolean
---@return string
local function codec_args(codec, fps, mbps, live)
  local args = CODECS[codec].encoder .. " " .. rate_args(codec, mbps)
  if not live then
    return args
  end
  if codec == "videotoolbox" then
    return args .. " -realtime 1 -g " .. fps * 2
  end
  return args .. " -g " .. fps * 2 .. " -keyint_min " .. fps
end

local function pick_codec(ffmpeg)
  local wanted = os.getenv("BALATROBOT_RECORD_CODEC")
  if wanted and CODECS[wanted] then
    return wanted
  end
  -- videotoolbox 只有 macOS 有; Windows 上不探测, 直接用 x264 (常见的 ffmpeg 发行版都带).
  if WINDOWS then
    return "x264"
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
  if frames:getCount() >= MAX_QUEUE then
    -- 编码线程落后于采集, 主线程在这里等它 (次数多说明编码器跟不上当前分辨率与帧率).
    s.queue_full = s.queue_full + 1
  end
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
  -- 中间这些参数不含空格与引号, 两种写法都可以原样拼; 只有程序路径与输出路径要加引号.
  local args = table.concat({
    "-y -loglevel error -f rawvideo -pix_fmt rgba",
    "-s " .. w .. "x" .. h,
    "-r " .. cfg.fps,
    "-i -",
    codec_args(cfg.codec, cfg.fps, cfg.bitrate, true),
    "-pix_fmt yuv420p",
    -- fragmented mp4: 游戏中途崩溃时已写入的分片仍可播放. flush_packets 让每个分片写完就落盘,
    -- 否则画面简单时整个分片都停在 ffmpeg 的 32 KB 写缓冲里, 被 kill 时一帧都读不出.
    "-movflags +frag_keyframe+empty_moov+default_base_moof -flush_packets 1",
  }, " ")
  local command, win_source
  if WINDOWS then
    command = WinProc.quote(cfg.ffmpeg) .. " " .. args .. " " .. WinProc.quote(video_path)
    win_source = SMODS.NFS.read(deps.mod_path .. "record/win_proc.lua")
  else
    command = shell_quote(cfg.ffmpeg) .. " " .. args .. " " .. shell_quote(video_path) .. " 2>" .. shell_quote(log_path)
  end
  local source = SMODS.NFS.read(deps.mod_path .. "record/encoder_thread.lua")
  local thread = love.thread.newThread(love.filesystem.newFileData(source, "bb_encoder_thread.lua"))
  local frames = love.thread.newChannel()
  local status = love.thread.newChannel()
  thread:start(command, frames, status, win_source, WINDOWS and log_path or nil)
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

--- Windows: 在后台运行局末合成脚本 (.post.cmd), 不开窗口, 游戏退出不影响它.
--- cmd /s /c "..." : 去掉最外层一对引号后原样执行, 路径里有空格也不会拆开.
---@param path string
---@return boolean ok
---@return string? err
local function launch_cmd(path)
  local proc, err = WinProc.spawn('cmd.exe /d /s /c ""' .. path:gsub("/", "\\") .. '""', { detached = true })
  if not proc then
    return false, err
  end
  WinProc.release(proc)
  return true
end

--- 文件字节数, 读不到时返回 nil.
---@param path string
---@return integer?
local function file_size(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local size = file:seek("end")
  file:close()
  return size
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

  if item.android then
    -- Android: 编码线程已经把 mp4 写完, 没有后台合成这一步.
    -- 产物由原生 open 创建, 权限要补一次 (否则是 0600, 靠组权限的工具拉不到).
    if video_done.path then
      fix_permissions(video_done.path)
    end
    if item.video.error then
      sendErrorMessage(string.format("Recording %s: 编码失败: %s", item.stem, tostring(item.video.error)), LOGGER)
      return true
    end
    -- 封装成功才改名成 -full.mp4, 与桌面的成品同名; 没封装成功的留着 .video.mp4 (moov 没写, 播不了).
    local final = video_done.path
    if video_done.muxed and final then
      local renamed = final:gsub("%.video%.mp4$", "-full.mp4")
      local ok, err = os.rename(final, renamed)
      if ok then
        final = renamed
      else
        sendWarnMessage(string.format("Recording %s: 改名失败, 留在 %s: %s", item.stem, final, tostring(err)), LOGGER)
      end
    end
    sendInfoMessage(
      string.format(
        "Recording %s: %s, %d 帧, %d 个样本, 编码器 %s%s%s",
        item.stem,
        tostring(final),
        video_done.frames or 0,
        video_done.samples or 0,
        tostring(video_done.encoder),
        video_done.muxed and "" or " (没有封装成功)",
        item.queue_full > 0 and string.format(", 编码队列压满 %d 次", item.queue_full) or ""
      ),
      LOGGER
    )
    return true
  end

  local audio_ok = item.audio ~= nil and not item.audio.error
  if audio_ok then
    audio_ok = (file_size(item.post.base .. ".pcm") or 0) > 0
  end
  item.post.audio = audio_ok
  -- 自动码率档: 按完整版的实测码率给剪辑版一个目标码率, 否则离线重编码出来的剪辑版比完整版还大
  -- (原因见 post.lua 的 cut_mbps). 量不到时保持原样, 手动选了码率的也不用管.
  -- 崩溃后用的草稿脚本仍用画质档: 那一刻视频还没写完, 量不出码率.
  if cfg.bitrate <= 0 and #(item.post.cuts or {}) > 0 then
    local mbps = Post.cut_mbps(
      file_size(item.post.base .. ".video.mp4"),
      video_done.frames,
      cfg.fps
    )
    if mbps then
      item.post.codec_args = codec_args(cfg.codec, cfg.fps, mbps, false)
      sendDebugMessage(string.format("Cut video target bitrate: %.2f Mbps", mbps), LOGGER)
    else
      sendWarnMessage("量不到完整版的码率, 剪辑版用默认画质档", LOGGER)
    end
  end
  local ok, err = Post.spawn(item.post, WINDOWS and launch_cmd or nil)
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
  -- 暂停中 cuts 忽略 mark; 也不刷新 last_busy, 恢复后不会因为暂停期间的事件多留动画
  if not s.cuts.paused then
    s.cuts:mark(wall)
    s.last_busy = now()
  end
  return wall, s.cuts:cut_time(wall)
end

--- 记一个事件, 同时算作活动, 保证事件所在的时刻留在剪辑版里.
---@return table event
local function log_event(s, kind, fields)
  local wall, cut = mark_now(s)
  return s.timeline:event(wall, cut, kind, fields)
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

--- 写出或覆盖草稿合成脚本, 崩溃后用它补做合成. 局末由 Post.spawn 用最终版覆盖.
local function write_draft(s)
  s.draft_cuts = #s.cuts.list
  -- 只有 ffmpeg 后端有 post (合成参数); Android 后端自己写 mp4, 没有这一步.
  if not s.post then
    return
  end
  local opts = {}
  for k, v in pairs(s.post) do
    opts[k] = v
  end
  opts.draft = true
  opts.audio = s.audio and "auto" or false
  opts.cuts = s.cuts.list
  local path, err = Post.write(opts)
  if not path and not s.draft_warned then
    s.draft_warned = true
    sendWarnMessage("Failed to write draft post script: " .. tostring(err), LOGGER)
  end
end

--- 暂停: 这一刻算作活动, 之后到恢复为止剪辑版剪掉. 事件的剪辑版时间在恢复或结束时改正.
local function pause_session(s, reason)
  local event = log_event(s, "pause", { reason = reason })
  s.cuts:pause(event.wall)
  s.pause_from = event.wall
end

local function resume_session(s, reason)
  s.cuts:resume(now() - s.started)
  s.timeline:refresh_cut(s.cuts, s.pause_from)
  s.pause_from = nil
  log_event(s, "resume", { reason = reason })
end

---@param resumed boolean 读档开局
---@param reason string? run_start 事件的 reason, 局中重新开始录制时给出
local function start_session(resumed, reason)
  local game = G.GAME or {}
  local seed = game.pseudorandom and game.pseudorandom.seed or "noseed"
  local stem = cfg.prefix .. os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(seed):gsub("[^%w%-_]", "")
  -- 同一秒内结束一段又开始新的一段时 (M.end_segment 后 M.start_segment), 文件名加序号区分
  local suffix = 1
  while
    file_exists(cfg.dir .. "/" .. stem .. (suffix > 1 and ("-" .. suffix) or "") .. ".json")
    or file_exists(cfg.dir .. "/" .. stem .. (suffix > 1 and ("-" .. suffix) or "") .. ".video.mp4")
  do
    suffix = suffix + 1
  end
  if suffix > 1 then
    stem = stem .. "-" .. suffix
  end
  local base = cfg.dir .. "/" .. stem

  local sw, sh = love.graphics.getPixelDimensions()
  local h = cfg.height - cfg.height % 2
  local w = math.floor(h * sw / sh + 0.5)
  w = w - w % 2

  local meta = {
    fps = cfg.fps,
    size = { w, h },
    -- Android 没有剪辑版, 编码完成后 .video.mp4 改名成 -full.mp4 (见 try_post).
    videos = cfg.backend == "android" and { full = stem .. "-full.mp4" }
      or (cfg.backend and { full = stem .. "-full.mp4", cut = stem .. "-cut.mp4" } or nil),
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
    -- 本段的帧率. 设置页可以在录制中改 cfg.fps, 只影响下一段, 这一段的帧数一直按开始时的帧率算.
    fps = cfg.fps,
    frames_out = 0, -- 已交给画面的帧数 (含待写出的 pending)
    pending = 0,
    queue_full = 0, -- 编码队列被压满的次数: 编码跟不上帧率时才会发生
    last_state = G.STATE,
    last_blind = nil,
    won = game.won or false,
    draft_cuts = 0, -- 上次写草稿脚本时的剪辑区间数
  }
  log_event(session, "run_start", { resumed = resumed, reason = reason })
  if paused then
    pause_session(session, "carried")
  end

  -- 只有 ffmpeg 后端采音频: Android 只写无声 mp4, 混音还没做 (见 docs/recording.md),
  -- 采了也只会留下用不到的 .pcm, 白白占 CPU 与磁盘.
  if cfg.backend == "ffmpeg" then
    local audio, audio_err = Audio.start(deps.mod_path, base .. ".pcm", session.started)
    if audio then
      session.audio = audio
    else
      sendWarnMessage("Recording without sound: " .. tostring(audio_err), LOGGER)
    end
  end

  if cfg.backend then
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

    local ok, thread, frames, status
    if cfg.backend == "android" then
      ok, thread, frames, status = cfg.android.start(deps.mod_path, base .. ".video.mp4", w, h, cfg.fps, cfg.bitrate)
    else
      ok, thread, frames, status = pcall(start_encoder, base .. ".video.mp4", base .. ".ffmpeg.txt", w, h)
    end

    if ok then
      session.thread, session.frames, session.status = thread, frames, status
      redirect = true
      if cfg.backend == "ffmpeg" then
        -- 合成参数, 草稿与局末脚本共用
        session.post = {
          dialect = WINDOWS and "cmd" or "sh",
          ffmpeg = cfg.ffmpeg,
          codec_args = codec_args(cfg.codec, cfg.fps, cfg.bitrate, false),
          base = base,
          fps = cfg.fps,
          keep = cfg.keep,
        }
      end
    else
      sendErrorMessage("Failed to start encoder: " .. tostring(thread), LOGGER)
      session.timeline:set("videos", nil)
    end
  end
  session.timeline:set("audio", session.audio ~= nil)
  session.timeline:flush(now(), true)
  write_draft(session)
  M.status = "recording " .. stem
  sendInfoMessage(
    string.format(
      "Recording started: %s (%dx%d@%d, bitrate %s, sound %s)",
      base,
      w,
      h,
      cfg.fps,
      cfg.bitrate > 0 and (cfg.bitrate .. " Mbps") or "auto",
      session.audio and "on" or "off"
    ),
    LOGGER
  )
end

--- 把画面帧数补到墙钟时间 wall 对应的帧.
local function advance_frames(s, wall)
  local target = math.floor(wall * s.fps + 1e-9)
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
  local length = s.frames_out / s.fps -- 视频的实际长度
  local was_paused = s.cuts.paused
  s.cuts.paused = false -- 暂停中结束: 暂停的部分由 finish 当作结尾的等待剪掉
  s.cuts:finish(length)
  if s.pause_from then
    s.timeline:refresh_cut(s.cuts, s.pause_from)
    s.pause_from = nil
  end
  local info = run_info()
  -- 回主菜单时 G.GAME 可能已重置, 以本局记录到的 won 事件为准.
  local won = s.won or (G.GAME and G.GAME.won) or false
  local result = { reason = reason, won = won, ante = info.ante, round = info.round, paused = was_paused or nil }
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
    local item = {
      stem = s.stem,
      video = { stem = s.stem, thread = s.thread, status = s.status },
      audio = s.audio and { stem = s.stem, thread = s.audio.thread, status = s.audio.status } or nil,
      queue_full = s.queue_full,
    }
    if s.post then
      item.post = {}
      for k, v in pairs(s.post) do
        item.post[k] = v
      end
      item.post.cuts = s.cuts.list
    else
      -- Android: 编码线程自己收尾写 mp4, 主线程只等它结束 (没有 ffmpeg 可调).
      item.android = true
    end
    finishing[#finishing + 1] = item
  elseif s.post then
    -- 编码线程中途退出: 不在局末合成, 用最终的剪辑区间更新草稿, 之后可以用它或 recordings_recover 补做
    write_draft(s)
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

--- 画面还在动 (动画未停或控制器被锁住), 由 init 注入 bbcore 的 BB_OVERLAY.animating.
local function animating()
  return deps.animating() == true
end

-- ==========================================================================
-- 对外接口
-- ==========================================================================

local ENABLE_VALUES = { on = true, ["1"] = true, ["true"] = true, yes = true }

--- 正在录制的一段: stem, base (不含扩展名的输出路径), started (love.timer 时间), paused. 没有时为 nil.
---@return {stem: string, base: string, started: number, paused: boolean}?
function M.current()
  local s = session
  return s and { stem = s.stem, base = s.base, started = s.started, paused = paused } or nil
end

--- 立即结束当前录像段并开始合成, 不等回到主菜单 (agent 停止时调用).
--- 本局剩下的部分不再录制; 下一次开局 (或读档) 照常开始新的一局录像, 需要在本局内接着录时调用 M.start_segment.
---@param reason string? 写进 run_end 与 result.reason, 默认 "stop"
---@return boolean ended 是否有正在录制的一段
function M.end_segment(reason)
  if not session then
    return false
  end
  end_session(reason or "stop")
  -- 编码线程写完最后几帧后由 M.update 启动合成, 这里先试一次
  poll_finishing(nil)
  return true
end

--- 在当前这一局里开始新的一段录像 (M.end_segment 之后, agent 重新启动时可调用). 文件名按此刻重新取,
--- run_start 事件带 reason. 不在局内, 录制未开启或已在录制时不做任何事.
---@param reason string?
---@return boolean started
function M.start_segment(reason)
  if not M.enabled or session or G.STAGE ~= G.STAGES.RUN or not G.GAME then
    return false
  end
  start_session(false, reason or "segment")
  return true
end

--- agent 暂停/恢复. 暂停期间完整版照录, 剪辑版剪掉 (手动输入, 动画, 通知和额外活动来源都不算活动),
--- 时间线记 pause/resume 事件. 状态跨局保持: 暂停中开的新局从暂停开始. 重复设置同一状态不做任何事.
---@param value boolean
---@param reason string? 写进 pause/resume 事件
function M.set_paused(value, reason)
  value = value and true or false
  if value == paused then
    return
  end
  paused = value
  local s = session
  if not s then
    return
  end
  if value then
    pause_session(s, reason)
  else
    resume_session(s, reason)
  end
end

---@return boolean
function M.is_paused()
  return paused
end

--- 注册额外的活动来源 (例如流式条在屏幕上时). fn 每帧调用一次, 返回 true 时本帧算作活动
--- (与决策消息在屏幕上同等对待, 暂停期间不调用). fn 出错时移除并警告. 可以在 init 之前调用.
---@param fn fun(t: number): boolean? t 为 love.timer 时间
---@return fun() remove 注销函数
function M.add_activity_source(fn)
  activity_sources[#activity_sources + 1] = fn
  return function()
    for i, f in ipairs(activity_sources) do
      if f == fn then
        table.remove(activity_sources, i)
        return
      end
    end
  end
end

--- 额外活动来源里是否有一个认为此刻在活动.
local function extra_active(t)
  for i = #activity_sources, 1, -1 do
    local fn = activity_sources[i]
    local ok, result = pcall(fn, t)
    if not ok then
      table.remove(activity_sources, i)
      sendWarnMessage("Activity source removed after error: " .. tostring(result), LOGGER)
    elseif result then
      return true
    end
  end
  return false
end

--- 给正在录制的一局的时间线加一个顶层字段.
---@param key string
---@param value any
function M.annotate(key, value)
  if session then
    session.timeline:set(key, value)
  end
end

--- 按设置页的值 (cfg.wanted) 与环境变量定下清晰度, 帧率与码率. 下一个录像段开始时生效.
local function apply_quality()
  local q = Quality.resolve(cfg.wanted, os.getenv, love._os == "Android")
  cfg.height, cfg.fps, cfg.bitrate = q.height, q.fps, q.bitrate
end

--- 装载模块, 定下输出参数, 装全局钩子. 只做一次, 由第一次 M.set_enabled(true) 触发.
---@return boolean ok 可以录制
local function setup()
  if setup_done then
    return ready
  end
  setup_done = true
  if BB_SETTINGS.headless or BB_SETTINGS.render_on_api then
    M.status = "unavailable (headless/render_on_api)"
    sendWarnMessage("Recording disabled: headless and render_on_api modes have no frames to capture", LOGGER)
    return false
  end

  Cuts = assert(SMODS.load_file("record/cuts.lua", MOD_ID))()
  Timeline = assert(SMODS.load_file("record/timeline.lua", MOD_ID))()
  Audio = assert(SMODS.load_file("record/audio.lua", MOD_ID))()
  Post = assert(SMODS.load_file("record/post.lua", MOD_ID))()

  -- Android 上只走 MediaCodec (没有 ffmpeg). 清晰度, 帧率与码率的默认值与取舍见 record/quality.lua.
  local android = love._os == "Android"
  Quality = assert(SMODS.load_file("record/quality.lua", MOD_ID))()
  if WINDOWS then
    WinProc = assert(SMODS.load_file("record/win_proc.lua", MOD_ID))()
  end
  apply_quality()
  cfg.pre = env_number("BALATROBOT_RECORD_PRE", 0.6)
  cfg.post = env_number("BALATROBOT_RECORD_POST", 0.8)
  -- 文件名前缀, 回放时为 "replay-", 与原局的录像区分. 游戏内回放在录像还没初始化时就先 M.set_prefix,
  -- 这里不能覆盖它, 只在没设过时取环境变量.
  if cfg.prefix == nil then
    cfg.prefix = (os.getenv("BALATROBOT_RECORD_PREFIX") or ""):gsub("[^%w%-_]", "")
  end
  local dir = os.getenv("BALATROBOT_RECORD_DIR")
  cfg.dir = (dir and dir ~= "") and dir:gsub("/+$", "") or (love.filesystem.getSaveDirectory() .. "/recordings")
  local created, err = SMODS.NFS.createDirectory(cfg.dir)
  if not created then
    M.status = "unavailable (output dir)"
    sendErrorMessage("Recording disabled: " .. tostring(err), LOGGER)
    return false
  end
  fix_permissions(cfg.dir)
  -- 编码后端: Android 上用 MediaCodec, 其余平台用 ffmpeg.
  if android then
    local ok_backend, backend = pcall(function()
      return assert(SMODS.load_file("record/android/backend.lua", MOD_ID))()
    end)
    if not ok_backend then
      sendWarnMessage("装载 Android 编码后端失败: " .. tostring(backend), LOGGER)
    else
      local usable, why = backend.available()
      if usable then
        cfg.android = backend
        cfg.backend = "android"
      else
        sendWarnMessage("Android 硬件编码不可用: " .. tostring(why), LOGGER)
      end
    end
  end
  if not cfg.backend then
    cfg.ffmpeg = find_ffmpeg()
    if cfg.ffmpeg then
      cfg.codec = pick_codec(cfg.ffmpeg)
      cfg.backend = "ffmpeg"
    end
  end
  ready = true

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
      "Recording ready: %d fps, height %d, bitrate %s, padding %.1f/%.1fs, dir %s, backend %s%s",
      cfg.fps,
      cfg.height,
      cfg.bitrate > 0 and (cfg.bitrate .. " Mbps") or "auto",
      cfg.pre,
      cfg.post,
      cfg.dir,
      tostring(cfg.backend or "none"),
      cfg.backend == "ffmpeg" and (" (" .. tostring(cfg.ffmpeg) .. ", codec " .. tostring(cfg.codec) .. ")") or ""
    ),
    LOGGER
  )
  if not cfg.backend then
    sendWarnMessage("没有可用的编码后端 (Android 上见上面的原因, 桌面上设 BALATROBOT_FFMPEG), 只写时间轴 JSON", LOGGER)
  end
  return true
end

---@param options {activity: table, toast: table, animating: fun(): boolean, mod_path: string, config_enabled: boolean?, config_keep: string?, config_quality: table?}
--- activity / toast / animating: bbcore 的 BB_ACTIVITY, BB_TOAST, BB_OVERLAY.animating.
--- config_enabled: 设置页的录像开关. 设了 BALATROBOT_RECORD 环境变量时以环境变量为准 (Android 没有环境变量).
--- config_keep: 设置页的保留方式, "keep" 时合成成功后保留中间文件. 设了 BALATROBOT_RECORD_KEEP 时以它为准.
--- config_quality: 设置页的 {height, fps, bitrate}, 0 为默认. 设了对应环境变量的项以环境变量为准.
function M.init(options)
  deps = options
  local q = options.config_quality or {}
  cfg.wanted = { height = q.height, fps = q.fps, bitrate = q.bitrate }
  local mode = os.getenv("BALATROBOT_RECORD")
  local wanted
  if mode ~= nil and mode ~= "" then
    wanted = ENABLE_VALUES[mode] == true
  else
    wanted = options.config_enabled == true
  end
  -- 保留方式与是否开启无关, 先记下来, 之后由 M.set_enabled 装载时使用.
  local keep = os.getenv("BALATROBOT_RECORD_KEEP")
  if keep == nil or keep == "" then
    keep = options.config_keep
  end
  cfg.keep = keep == "keep"
  if not wanted then
    -- 录像关着: 不装载也不挂钩子, 需要时 (游戏内回放选了录像) 由 M.set_enabled 补上.
    M.status = "off"
    return
  end
  M.set_enabled(true, "startup")
end

--- 运行时开关录制. 打开时如果启动时判定为关 (或未准备好), 现补上初始化; 关闭时结束当前录像段.
---@param value boolean
---@param reason string?
---@return boolean enabled
function M.set_enabled(value, reason)
  value = value and true or false
  if value then
    if not setup() then
      return false
    end
    M.enabled = true
    M.status = cfg.backend == "android" and "on (MediaCodec)"
      or (cfg.backend == "ffmpeg" and "on" or "on, no ffmpeg (timeline only)")
    if reason then
      sendInfoMessage("Recording enabled by " .. reason, LOGGER)
    end
    return true
  end
  if M.enabled then
    sendInfoMessage("Recording disabled by " .. tostring(reason or "request"), LOGGER)
  end
  M.enabled = false
  M.status = "off"
  M.end_segment("disabled")
  return false
end

--- 运行时改保留方式: "keep" 时合成成功后保留中间文件. 合成参数在开始录制时定下, 只影响之后开始的录像段.
---@param mode string?
function M.set_keep(mode)
  cfg.keep = mode == "keep"
end

--- 运行时改清晰度, 帧率或码率 (设置页). 从下一个录像段起生效, 正在录的一段不变.
--- 录像还没装载时只记下来, 装载时一并生效. 设了对应环境变量的项仍以环境变量为准.
---@param key "height"|"fps"|"bitrate"
---@param value number 可选值之一, 0 为默认
function M.set_quality(key, value)
  cfg.wanted = cfg.wanted or {}
  cfg.wanted[key] = value
  if Quality then
    apply_quality()
  end
end

--- 运行时改输出文件名前缀 (游戏内回放录成 replay-*, 与原局录像区分). 只影响之后开始的录像段.
---@param prefix string
function M.set_prefix(prefix)
  cfg.prefix = tostring(prefix or ""):gsub("[^%w%-_]", "")
end

---@return string
function M.get_prefix()
  return cfg.prefix or ""
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

  -- 活动: 请求处理中, 通知在屏幕上, 开局动画, 手动操作, 额外活动来源; 之后动画还没停下的部分也算,
  -- 但距上一次活动最多 SETTLE_MAX 秒. 暂停期间什么都不算.
  if not s.cuts.paused then
    local activity = deps.activity
    local busy = activity.busy(t)
      or deps.toast.active()
      or wall < START_GRACE
      or t - last_input < 1
      or extra_active(t)
    if busy then
      s.last_busy = t
    end
    if busy or (t - s.last_busy < SETTLE_MAX and animating()) then
      s.cuts:mark(wall)
    end
  end

  track_state(s)
  s.timeline:sync_cuts(s.cuts, wall)
  -- 剪辑区间变多时覆盖草稿脚本 (仅 ffmpeg 后端), 崩溃后合成的剪辑版尽量接近局末的结果
  if #s.cuts.list ~= s.draft_cuts then
    write_draft(s)
  end
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
