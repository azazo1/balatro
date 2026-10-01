--[[
Android 录像的编码后端: 用 MediaCodec 编码, 由 android/encoder_thread.lua 在线程里完成.

对外的形状与桌面的 start_encoder 一致 (返回 thread, frames, status), 这样 recorder 那边
session.thread / session.frames / session.status 的用法不用分平台:

- recorder 往 frames 通道推 {image = ImageData, count = 重复次数}, 结束时推 "stop".
- 线程往 status 通道推 {kind = "error"|"done", ...}.

与桌面的差别:
- 桌面把原始 RGBA 直接交给 ffmpeg 的标准输入; 这里在线程里先转成 NV12 再喂给编码器.
- 桌面用 fragmented mp4 抗崩溃; AMediaMuxer 只写普通 mp4, moov 在收尾时才写. 所以录制中途崩溃
  会丢掉这一局的视频, 这是 Android 上目前的取舍 (见 docs/recording.md).
]]

local M = {}

-- 运行时加载自己的模块要显式给出 mod id (SMODS.load_file 只在首次加载 mod 时可以省).
local MOD_ID = "bbreplay"

--- 能不能用: libmediandk 可用且建得出 H.264 编码器. 只在 Android 上调用.
---@return boolean ok
---@return string? reason
function M.available()
  local ok, media = pcall(function()
    return assert(SMODS.load_file("record/android/ffi.lua", MOD_ID))()
  end)
  if not ok then
    return false, tostring(media)
  end
  local loaded, err = media.load()
  if not loaded then
    return false, tostring(err)
  end
  if not media.has_encoder("video/avc") then
    return false, "这台设备没有 H.264 编码器"
  end
  return true
end

--- 码率估算: 约 0.15 bit/像素/帧, 限制在 1~12 Mbps.
--- 540p24 得约 1.9 Mbps. 卡面文字边缘多, 给低了会糊.
local function bitrate(width, height, fps)
  local want = math.floor(width * height * fps * 0.15)
  return math.max(1000000, math.min(12000000, want))
end

--- 启动编码线程.
---@param mod_path string mod 目录 (取线程脚本)
---@param video_path string 输出 mp4 路径
---@param width integer
---@param height integer
---@param fps integer
---@return boolean ok
---@return table|string thread_or_error
---@return table? frames 仅成功时给出
---@return table? status 仅成功时给出
function M.start(mod_path, video_path, width, height, fps)
  local ok_cdef, Cdef = pcall(function()
    return assert(SMODS.load_file("record/android/cdef.lua", MOD_ID))()
  end)
  if not ok_cdef then
    return false, "读取 C 声明失败: " .. tostring(Cdef)
  end

  local source_ok, source = pcall(SMODS.NFS.read, mod_path .. "record/android/encoder_thread.lua")
  if not source_ok or type(source) ~= "string" then
    return false, "读取编码线程脚本失败: " .. tostring(source)
  end

  local options = {
    path = video_path,
    width = width,
    height = height,
    fps = fps,
    bitrate = bitrate(width, height, fps),
  }
  local thread = love.thread.newThread(love.filesystem.newFileData(source, "bb_android_encoder.lua"))
  local frames = love.thread.newChannel()
  local status = love.thread.newChannel()
  thread:start(Cdef.CDECL, options, frames, status)
  return true, thread, frames, status
end

return M
