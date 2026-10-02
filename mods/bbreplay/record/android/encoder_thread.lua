--[[
Android 录制编码线程: 从 frames 通道取 ImageData, 用 MediaCodec 硬件编码 H.264, 经 AMediaMuxer 写成 mp4.

参数: cdecl (C 声明文本, 来自 android/cdef.lua), options, frames (Channel), status (Channel).
frames 里的元素是 {image = ImageData, count = 重复次数}, 收到 "stop" 时写结束标记并收尾.
status 里推 {kind = "error"|"done", ...}.

为什么在原生侧做颜色转换: 540p 一帧 50 万像素, 逐像素在 Lua 里转达不到 24fps.
转换在 bbnet 里 (导出 bbnet_rgba_to_nv12), 这里只负责把指针交过去.

时间戳: 每个重复都算一帧, pts = 帧序号 * 帧间隔. 录制侧按墙钟重复上一帧, 所以视频长度与时间线一致.

整个线程体包在 xpcall 里: LÖVE 会把线程里未捕获的错误抛到主线程并直接崩掉游戏, 而出错的原因多半与
设备相关 (编码器不支持某个参数, 内存不足), 不该让玩家的对局陪葬. 任何失败都经由 status 通道报告.

本线程是独立的 Lua 状态, 没有 SMODS, 所以声明文本与参数都从外部传入.
]]

local cdecl, options, frames, status = ...

-- 线程里要先 require 才能调用通道传进来的 ImageData 的方法.
local ok_love, love_err = pcall(require, "love.image")
if not ok_love then
  status:push({ kind = "error", message = "love.image 不可用: " .. tostring(love_err) })
  return
end

local ffi = require("ffi")
local bit = require("bit")

local ok_cdef, cdef_err = pcall(ffi.cdef, cdecl)
if not ok_cdef then
  status:push({ kind = "error", message = "ffi.cdef 失败: " .. tostring(cdef_err) })
  return
end

local ok_media, media = pcall(ffi.load, "mediandk")
if not ok_media then
  status:push({ kind = "error", message = "加载 libmediandk 失败: " .. tostring(media) })
  return
end
local ok_net, net = pcall(ffi.load, "bbnet")
if not ok_net then
  status:push({ kind = "error", message = "加载 libbbnet 失败: " .. tostring(net) })
  return
end

-- media/NdkMediaCodec.h 与 NdkMediaMuxer.h 的常量.
local COLOR_FORMAT_NV12 = 21
local CONFIGURE_FLAG_ENCODE = 1
local FLAG_CODEC_CONFIG = 2
local FLAG_END_OF_STREAM = 4
local INFO_TRY_AGAIN_LATER = -1
local INFO_OUTPUT_FORMAT_CHANGED = -2
local MUXER_FORMAT_MPEG_4 = 0

-- libc: 直接写文件描述符 (AMediaMuxer 按 fd 写).
local O_WRONLY, O_CREAT, O_TRUNC = 0x1, 0x40, 0x200
local FD_MODE = tonumber("0644", 8)
local DEQUEUE_TIMEOUT_US = 10000 -- 10ms: 取不到就先去吐输出, 免得编码器内部积压

-- ==========================================================================
-- 需要收尾的资源. 放在这一层, 让 cleanup 在所有退出路径上都能碰到.
-- ==========================================================================

local codec, muxer, fd = nil, nil, -1
local muxing = false

--- 释放编码器, 封装器与文件. 可以重复调用.
--- 先停编码器再停封装: 封装器还要把已写样本的索引落到 moov, 这一步不能省.
local function cleanup()
  if codec then
    pcall(function()
      media.AMediaCodec_stop(codec)
      media.AMediaCodec_delete(codec)
    end)
    codec = nil
  end
  if muxer then
    if muxing then
      pcall(function()
        media.AMediaMuxer_stop(muxer)
      end)
    end
    pcall(function()
      media.AMediaMuxer_delete(muxer)
    end)
    muxer = nil
  end
  if fd >= 0 then
    pcall(function()
      ffi.C.bb_close(fd)
    end)
    fd = -1
  end
end

-- ==========================================================================
-- 编码
-- ==========================================================================

--- 跑完整段编码. 成功返回结果表, 失败返回 nil 与原因.
---@return {frames: integer, samples: integer, muxed: boolean}?
---@return string? err
local function run()
  local width, height, fps = options.width, options.height, options.fps
  -- 帧间隔 (微秒) 取整, 时间戳用帧序号乘出来, 保证是整数.
  local pts_step = math.floor(1000000 / fps + 0.5)

  local nv12_bytes = tonumber(net.bbnet_nv12_size(width, height))
  if nv12_bytes <= 0 then
    return nil, "尺寸非法: " .. tostring(width) .. "x" .. tostring(height)
  end

  --- 每次尝试都要一份新的 format: configure 会改动它, 失败的那份也要释放.
  local function build_format()
    local format = media.AMediaFormat_new()
    media.AMediaFormat_setString(format, "mime", "video/avc")
    media.AMediaFormat_setInt32(format, "width", width)
    media.AMediaFormat_setInt32(format, "height", height)
    media.AMediaFormat_setInt32(format, "bit-rate", options.bitrate)
    media.AMediaFormat_setInt32(format, "frame-rate", fps)
    -- 每秒一个关键帧.
    -- i-frame-interval 是 float 键 (Java 侧 MediaFormat.KEY_I_FRAME_INTERVAL 也是 float).
    media.AMediaFormat_setFloat(format, "i-frame-interval", 1.0)
    -- NV12 (COLOR_FormatYUV420SemiPlanar): 与 bbnet 的转换输出一致.
    -- 不换成 I420: 那是三平面布局, 喂 NV12 的数据会得到颜色错乱的视频.
    media.AMediaFormat_setInt32(format, "color-format", COLOR_FORMAT_NV12)
    return format
  end

  -- 按顺序试编码器, 第一个 configure 通过的使用.
  --
  -- 为什么要退到软件编码器: 实测高通设备上 createEncoderByType 返回的硬件编码器 (c2.qti.avc.encoder)
  -- 会以 err(-22, BAD_VALUE) 拒绝 configure, 同一份 format 交给软件编码器就能通过, 说明参数无误.
  -- 硬件编码器实例有限, 被别的应用 (例如系统录屏) 占用时就建不起来, 这时软编仍然可用.
  -- 软编占 CPU 较多, 所以放在最后.
  local candidates = {
    { label = "系统推荐", create = function()
      return media.AMediaCodec_createEncoderByType("video/avc")
    end },
    { label = "软件编码器(c2)", create = function()
      return media.AMediaCodec_createCodecByName("c2.android.avc.encoder")
    end },
    { label = "软件编码器(omx)", create = function()
      return media.AMediaCodec_createCodecByName("OMX.google.h264.encoder")
    end },
  }

  local failures = {}
  local chosen = nil
  for _, candidate in ipairs(candidates) do
    local handle = candidate.create()
    if handle == nil then
      failures[#failures + 1] = candidate.label .. ": 不存在"
    else
      local format = build_format()
      local code = media.AMediaCodec_configure(handle, format, nil, nil, CONFIGURE_FLAG_ENCODE)
      media.AMediaFormat_delete(format)
      if code == 0 then
        codec = handle
        chosen = candidate.label
        break
      end
      failures[#failures + 1] = string.format("%s: configure=%d", candidate.label, code)
      media.AMediaCodec_delete(handle)
    end
  end

  if not codec then
    return nil, string.format(
      "没有可用的 H.264 编码器 (%dx%d@%d, %d kbps): %s",
      width, height, fps, options.bitrate / 1000, table.concat(failures, "; ")
    )
  end

  local started = media.AMediaCodec_start(codec)
  if started ~= 0 then
    return nil, "AMediaCodec_start 返回 " .. tostring(started) .. " (" .. chosen .. ")"
  end

  fd = ffi.C.bb_open(options.path, O_WRONLY + O_CREAT + O_TRUNC, FD_MODE)
  if fd < 0 then
    return nil, "打不开输出文件: " .. tostring(options.path)
  end
  muxer = media.AMediaMuxer_new(fd, MUXER_FORMAT_MPEG_4)
  if muxer == nil then
    return nil, "AMediaMuxer_new 失败"
  end

  local info = ffi.new("AMediaCodecBufferInfo")
  local out_size = ffi.new("size_t[1]")
  local track = -1
  local written = 0
  local encode_error = nil

  --- 吐出一个输出缓冲: 第一次收到格式时加轨道并开始封装, 之后写样本.
  local function handle_output(index)
    if index == INFO_OUTPUT_FORMAT_CHANGED then
      local out_format = media.AMediaCodec_getOutputFormat(codec)
      if out_format == nil then
        encode_error = "AMediaCodec_getOutputFormat 返回空"
        return false
      end
      track = tonumber(media.AMediaMuxer_addTrack(muxer, out_format))
      media.AMediaFormat_delete(out_format)
      if track < 0 then
        encode_error = "AMediaMuxer_addTrack 失败"
        return false
      end
      local start_code = media.AMediaMuxer_start(muxer)
      if start_code ~= 0 then
        encode_error = "AMediaMuxer_start 返回 " .. tostring(start_code)
        return false
      end
      muxing = true
      return true
    end
    if index < 0 then -- 其余信息码 (TRY_AGAIN_LATER, OUTPUT_BUFFERS_CHANGED) 没有缓冲要处理
      return true
    end
    local buffer = media.AMediaCodec_getOutputBuffer(codec, index, out_size)
    if buffer ~= nil and info.size > 0 then
      if bit.band(info.flags, FLAG_CODEC_CONFIG) ~= 0 then
        -- 配置帧 (csd-0/csd-1) 不进 mp4: 它已经随 getOutputFormat 交给封装器了.
      elseif not muxing then
        encode_error = "编码器在轨道建立前就产出了数据"
      else
        -- 传缓冲基址, 偏移交给 info: AOSP 的 AMediaMuxer_writeSampleData 内部是
        -- new ABuffer(data + info->offset, info->size), 自己再加一次 offset 会错位.
        local wrote = media.AMediaMuxer_writeSampleData(muxer, track, buffer, info)
        if wrote ~= 0 then
          encode_error = "AMediaMuxer_writeSampleData 返回 " .. tostring(wrote)
        else
          written = written + 1
        end
      end
    end
    media.AMediaCodec_releaseOutputBuffer(codec, index, false)
    return encode_error == nil
  end

  --- 把编码器当前的输出都取出来.
  local function drain(wait_us)
    while true do
      local index = media.AMediaCodec_dequeueOutputBuffer(codec, info, wait_us)
      if index == INFO_TRY_AGAIN_LATER then
        return true
      end
      if not handle_output(index) then
        return false
      end
      wait_us = 0 -- 还有数据就继续取
    end
  end

  --- 编码一帧 (RGBA 指针 -> NV12 -> 编码器).
  local function encode_frame(rgba_ptr, pts)
    while true do
      if encode_error then
        return false
      end
      local index = media.AMediaCodec_dequeueInputBuffer(codec, DEQUEUE_TIMEOUT_US)
      if index >= 0 then
        local buffer = media.AMediaCodec_getInputBuffer(codec, index, out_size)
        if buffer == nil or tonumber(out_size[0]) < nv12_bytes then
          encode_error = "输入缓冲太小: " .. tostring(tonumber(out_size[0])) .. " < " .. tostring(nv12_bytes)
          return false
        end
        if net.bbnet_rgba_to_nv12(rgba_ptr, width, height, width * 4, buffer, width, width) ~= 0 then
          encode_error = "颜色转换失败"
          return false
        end
        local queued = media.AMediaCodec_queueInputBuffer(codec, index, 0, nv12_bytes, pts, 0)
        if queued ~= 0 then
          encode_error = "AMediaCodec_queueInputBuffer 返回 " .. tostring(queued)
          return false
        end
        return true
      end
      -- 没有空闲输入缓冲: 先把已编好的吐出来, 再试
      if not drain(0) then
        return false
      end
    end
  end

  --- 送结束标记并等编码器吐完.
  local function signal_end()
    while true do
      local index = media.AMediaCodec_dequeueInputBuffer(codec, DEQUEUE_TIMEOUT_US * 10)
      if index >= 0 then
        media.AMediaCodec_queueInputBuffer(codec, index, 0, 0, written * pts_step, FLAG_END_OF_STREAM)
        break
      end
      if not drain(0) then
        return false
      end
    end
    for _ = 1, 10000 do
      local index = media.AMediaCodec_dequeueOutputBuffer(codec, info, DEQUEUE_TIMEOUT_US * 10)
      if index == INFO_TRY_AGAIN_LATER then
        return true
      end
      local eos = index >= 0 and bit.band(info.flags, FLAG_END_OF_STREAM) ~= 0
      if not handle_output(index) then
        return false
      end
      if eos then
        return true
      end
    end
    return true
  end

  local frame_index = 0
  --- 出错时的结果: 原因加上已编码的帧数. 走到这里时 encode_error 已经设好.
  local function failed()
    return nil, tostring(encode_error) .. " (已编码 " .. tostring(frame_index) .. " 帧)"
  end

  while true do
    local item = frames:demand()
    if item == "stop" then
      break
    end
    -- ImageData 取成 Lua 字符串再转指针: 含 NUL 字节也照样传得过去.
    local rgba = item.image:getString()
    local ptr = ffi.cast("const uint8_t *", rgba)
    for _ = 1, item.count do
      if not encode_frame(ptr, frame_index * pts_step) then
        break
      end
      frame_index = frame_index + 1
    end
    -- 每帧几 MB, 不等 GC, 用完立即释放.
    item.image:release()
    -- 编码过程中也把输出吐掉, 免得编码器内部的缓冲一直涨
    if encode_error or not drain(0) then
      return failed()
    end
  end

  if frame_index > 0 and not signal_end() then
    return failed()
  end
  return {
    frames = frame_index,
    samples = written,
    muxed = muxing,
    encoder = chosen,
  }
end

-- ==========================================================================
-- 出错也不崩游戏: 整段包在 xpcall 里, 结果走 status 通道
-- ==========================================================================

local ok_run, outcome, message = xpcall(run, debug.traceback)
cleanup()

if not ok_run then
  status:push({ kind = "error", message = "编码线程出错: " .. tostring(outcome), path = options.path })
elseif not outcome then
  status:push({ kind = "error", message = tostring(message), path = options.path })
else
  status:push({
    kind = "done",
    frames = outcome.frames,
    samples = outcome.samples,
    muxed = outcome.muxed,
    encoder = outcome.encoder,
    path = options.path,
  })
end
