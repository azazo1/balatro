--[[
Android 录像的编码后端: 用 MediaCodec 硬件编码, 由 android/encoder_thread.lua 在线程里完成.

对外的形状与桌面的 start_encoder 一致 (返回 thread, frames, status), 这样 recorder 那边
session.thread / session.frames / session.status 的用法不用分平台:

- recorder 往 frames 通道推 {image = ImageData, count = 重复次数}, 结束时推 "stop".
- 线程往 status 通道推 {kind = "error"|"done"|"debug", ...}.

与桌面的差别:
- 桌面把原始 RGBA 直接交给 ffmpeg 的标准输入; 这里在线程里先转成 NV12 再喂给编码器.
- 桌面用 fragmented mp4 抗崩溃; AMediaMuxer 只写普通 mp4, moov 在收尾时才写. 所以录制中途崩溃
  会丢掉这一局的视频, 这是 Android 上目前的取舍 (见 docs/builtin-agent.md).
]]

local M = {}

-- 运行时加载自己的模块要显式给出 mod id (SMODS.load_file 只在首次加载 mod 时可以省).
local MOD_ID = "balatrobot"

local log = function(fmt, ...)
  print("[bb_record_android] " .. string.format(fmt, ...))
end

--- 加载 media 绑定层. 失败时返回 nil 与原因.
---@return table? media
---@return string? err
local function load_media()
  local ok, media = pcall(function()
    return assert(SMODS.load_file("agent/record/android/ffi.lua", MOD_ID))()
  end)
  if not ok then
    return nil, tostring(media)
  end
  return media
end

--- 能不能用硬件编码: Android + libmediandk 可用 + 有 H.264 编码器.
---@return boolean ok
---@return string? reason
function M.available()
  if love._os ~= "Android" then
    return false, "只用于 Android"
  end
  local media, err = load_media()
  if not media then
    return false, err
  end
  local probe = media.probe()
  if not probe.ok then
    return false, tostring(probe.error)
  end
  if not probe.h264 then
    return false, "这台设备没有 H.264 编码器"
  end
  return true
end

--- 码率估算: 约 0.15 bit/像素/帧, 限制在 1~12 Mbps.
--- 540p30 得约 2.3 Mbps. 卡面文字边缘多, 给低了会糊.
---@param width integer
---@param height integer
---@param fps integer
---@return integer
function M.bitrate(width, height, fps)
  local want = math.floor(width * height * fps * 0.15)
  return math.max(1000000, math.min(12000000, want))
end

--- 启动编码线程.
---@param mod_path string mod 目录 (取线程脚本与 C 声明)
---@param video_path string 输出 mp4 路径
---@param width integer
---@param height integer
---@param fps integer
---@param extra {debug: boolean?}? debug 为真时线程会上报各阶段进度
---@return boolean ok
---@return table|string thread_or_error
---@return table? frames 仅成功时给出
---@return table? status 仅成功时给出
function M.start(mod_path, video_path, width, height, fps, extra)
  local ok_cdef, Cdef = pcall(function()
    return assert(SMODS.load_file("agent/record/android/cdef.lua", MOD_ID))()
  end)
  if not ok_cdef then
    return false, "读取 C 声明失败: " .. tostring(Cdef)
  end

  local options = {
    path = video_path,
    width = width,
    height = height,
    fps = fps,
    bitrate = M.bitrate(width, height, fps),
    rgba_stride = width * 4,
    debug = (extra or {}).debug == true,
  }

  local source_ok, source = pcall(SMODS.NFS.read, mod_path .. "agent/record/android/encoder_thread.lua")
  if not source_ok or type(source) ~= "string" then
    return false, "读取编码线程脚本失败: " .. tostring(source)
  end

  local thread = love.thread.newThread(love.filesystem.newFileData(source, "bb_android_encoder.lua"))
  local frames = love.thread.newChannel()
  local status = love.thread.newChannel()
  thread:start(Cdef.CDECL, options, frames, status)
  log("编码线程已启动: %dx%d@%d, %d kbps, %s", width, height, fps, options.bitrate / 1000, video_path)
  return true, thread, frames, status
end

return M
