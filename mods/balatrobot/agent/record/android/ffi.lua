--[[
Android 录像用的 media 绑定层: libmediandk 的 MediaCodec / MediaMuxer / MediaExtractor.

只声明要用到的符号. 非 Android 或库加载失败时 M.load() 返回 false 并给出原因, 调用方退回原路径
(桌面上是 ffmpeg). 任何一步失败都不应影响游戏, 所以这里不做 assert.

颜色转换 (RGBA -> NV12) 不在这里: 那是跨平台的纯计算, 放在 bbnet 里 (见 agent/net/bbnet.lua 的
rgba_to_nv12), 免得为它单独养一个原生库和一套构建.

时间戳单位:
- MediaCodec 的输入输出时间戳都是微秒.
- AMediaMuxer_writeSampleData 用编码器给出的 presentationTimeUs.
]]

local M = {}

---@class BBNativeMedia
---@field codec table MediaCodec 相关函数与常量
---@field format table AMediaFormat 相关函数
---@field muxer table AMediaMuxer 相关函数
---@field extractor table AMediaExtractor 相关函数

local ffi

-- MediaCodec 的缓冲区标志与返回码 (media/NdkMediaCodec.h).
local BUFFER_FLAG = {
  KEY_FRAME = 1,
  CODEC_CONFIG = 2,
  END_OF_STREAM = 4,
  PARTIAL_FRAME = 8,
}

local INFO = {
  TRY_AGAIN_LATER = -1,
  OUTPUT_FORMAT_CHANGED = -2,
  OUTPUT_BUFFERS_CHANGED = -3,
}

-- AMediaFormat 的键名. 这些字符串是 Android 的稳定契约, 直接写字面量.
local KEYS = {
  mime = "mime",
  width = "width",
  height = "height",
  bit_rate = "bit-rate",
  frame_rate = "frame-rate",
  i_frame_interval = "i-frame-interval",
  color_format = "color-format",
  max_input_size = "max-input-size",
  sample_rate = "sample-rate",
  channel_count = "channel-count",
  aac_profile = "aac-profile",
  profile = "profile",
  level = "level",
  csd0 = "csd-0",
  csd1 = "csd-1",
}

-- 颜色格式与配置常量.
local VALUE = {
  -- COLOR_FormatYUV420SemiPlanar (NV12): 硬件编码器普遍支持, 也是 bbnet 颜色转换的输出.
  COLOR_FormatYUV420SemiPlanar = 21,
  -- COLOR_FormatYUV420Flexible: 老设备上有些只认这个.
  COLOR_FormatYUV420Flexible = 0x7F420888,
  -- AACObjectLC
  AAC_Object_LC = 2,
  -- AMediaCodec configure 的标志
  CONFIGURE_FLAG_ENCODE = 1,
}

M.BUFFER_FLAG = BUFFER_FLAG
M.INFO = INFO
M.KEYS = KEYS
M.VALUE = VALUE

--- 需要的类型: cdef 之后逐个核对, 确认声明真的生效.
--- 只看 cdef 的返回值不够: 模块被加载两次时重复声明会报 "attempt to redefine", 那其实说明已经声明好了;
--- 反过来, 声明文本漏了某个类型 (例如 Android 特有的 media_status_t) 时又必须报错而不是静默跳过.
local NEEDED_TYPES = {
  "media_status_t",
  "AMediaFormat",
  "AMediaCodec",
  "AMediaCodecBufferInfo",
  "AMediaMuxer",
  "AMediaExtractor",
}

---@param lib table ffi 模块
---@return boolean declared
---@return string? missing 第一个还没声明的类型
local function types_declared(lib)
  for _, name in ipairs(NEEDED_TYPES) do
    if not pcall(lib.typeof, name) then
      return false, name
    end
  end
  return true
end

--- 注册 C 声明. lib 是 ffi 模块本身 (不能依赖 upvalue: cdef 要在 ffi 赋值之前调用).
--- NdkMediaError.h: typedef int32_t media_status_t, 返回 0 为 AMEDIA_OK.
--- ssize_t 由 LuaJIT 自带, 不需要自己声明 (重复声明会报 attempt to redefine).
local CDECL = [[
    typedef int32_t media_status_t;

    // ---- AMediaFormat ----
    typedef struct AMediaFormat AMediaFormat;
    AMediaFormat *AMediaFormat_new(void);
    void AMediaFormat_delete(AMediaFormat *format);
    void AMediaFormat_setString(AMediaFormat *format, const char *name, const char *value);
    void AMediaFormat_setInt32(AMediaFormat *format, const char *name, int32_t value);
    void AMediaFormat_setInt64(AMediaFormat *format, const char *name, int64_t value);
    void AMediaFormat_setBuffer(AMediaFormat *format, const char *name, const void *data, size_t size);
    bool AMediaFormat_getInt32(AMediaFormat *format, const char *name, int32_t *out);
    bool AMediaFormat_getInt64(AMediaFormat *format, const char *name, int64_t *out);
    const char *AMediaFormat_getString(AMediaFormat *format, const char *name, size_t *out_size);
    const char *AMediaFormat_toString(AMediaFormat *format);

    // ---- AMediaCodec ----
    typedef struct AMediaCodec AMediaCodec;

    typedef struct AMediaCodecBufferInfo {
      int32_t offset;
      int32_t size;
      int64_t presentationTimeUs;
      uint32_t flags;
    } AMediaCodecBufferInfo;

    AMediaCodec *AMediaCodec_createEncoderByType(const char *mime);
    AMediaCodec *AMediaCodec_createDecoderByType(const char *mime);
    media_status_t AMediaCodec_configure(AMediaCodec *codec, const AMediaFormat *format,
                                         void *surface, void *crypto, uint32_t flags);
    media_status_t AMediaCodec_start(AMediaCodec *codec);
    media_status_t AMediaCodec_stop(AMediaCodec *codec);
    media_status_t AMediaCodec_flush(AMediaCodec *codec);
    media_status_t AMediaCodec_delete(AMediaCodec *codec);
    uint8_t *AMediaCodec_getInputBuffer(AMediaCodec *codec, size_t index, size_t *out_size);
    uint8_t *AMediaCodec_getOutputBuffer(AMediaCodec *codec, size_t index, size_t *out_size);
    ssize_t AMediaCodec_dequeueInputBuffer(AMediaCodec *codec, int64_t timeoutUs);
    media_status_t AMediaCodec_queueInputBuffer(AMediaCodec *codec, size_t index, size_t offset,
                                                size_t size, uint64_t time, uint32_t flags);
    ssize_t AMediaCodec_dequeueOutputBuffer(AMediaCodec *codec, AMediaCodecBufferInfo *info,
                                            int64_t timeoutUs);
    media_status_t AMediaCodec_releaseOutputBuffer(AMediaCodec *codec, size_t index, bool render);
    AMediaFormat *AMediaCodec_getOutputFormat(AMediaCodec *codec);

    // ---- AMediaMuxer ----
    typedef struct AMediaMuxer AMediaMuxer;
    AMediaMuxer *AMediaMuxer_new(int fd, int32_t format);
    media_status_t AMediaMuxer_setOrientationHint(AMediaMuxer *muxer, int degrees);
    ssize_t AMediaMuxer_addTrack(AMediaMuxer *muxer, const AMediaFormat *format);
    media_status_t AMediaMuxer_start(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_stop(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_delete(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_writeSampleData(AMediaMuxer *muxer, size_t trackIndex,
                                               const uint8_t *data, const AMediaCodecBufferInfo *info);

    // ---- AMediaExtractor (剪辑时按关键帧取样本) ----
    typedef struct AMediaExtractor AMediaExtractor;
    AMediaExtractor *AMediaExtractor_new(void);
    media_status_t AMediaExtractor_setDataSourceFd(AMediaExtractor *ex, int fd, int64_t offset,
                                                   int64_t length);
    media_status_t AMediaExtractor_delete(AMediaExtractor *ex);
    size_t AMediaExtractor_getTrackCount(AMediaExtractor *ex);
    AMediaFormat *AMediaExtractor_getTrackFormat(AMediaExtractor *ex, size_t track);
    media_status_t AMediaExtractor_selectTrack(AMediaExtractor *ex, size_t track);
    void AMediaExtractor_unselectTrack(AMediaExtractor *ex, size_t track);
    ssize_t AMediaExtractor_readSampleData(AMediaExtractor *ex, uint8_t *buffer, size_t capacity);
    int64_t AMediaExtractor_getSampleTime(AMediaExtractor *ex);
    uint32_t AMediaExtractor_getSampleFlags(AMediaExtractor *ex);
    bool AMediaExtractor_advance(AMediaExtractor *ex);
    int AMediaExtractor_getSampleTrackIndex(AMediaExtractor *ex);

    // ---- libc: 输出文件描述符 (AMediaMuxer 按 fd 写) ----
    int open(const char *path, int flags, ...);
    int close(int fd);
]]

--- 声明一次即可; 被加载两次时第二次会报重复定义, 此时按已声明处理.
local function cdef(lib)
  local ok, err = pcall(lib.cdef, CDECL)
  local declared, missing = types_declared(lib)
  if declared then
    return true
  end
  if ok then
    -- cdef 没报错, 但类型不全: 说明声明块本身有问题
    return false, "声明之后仍缺少类型: " .. tostring(missing)
  end
  return false, tostring(err) .. " (缺少类型: " .. tostring(missing) .. ")"
end

--- 加载 media 库. 可重复调用, 结果缓存 (失败也缓存, 免得每次录像都重试).
--- opts.ffi 与 opts.lib 只给单测注入用: 开发机上没有 libmediandk, 但 cdef 本身是可以真跑的
--- (声明文本有错时 ffi.cdef 会失败), 所以测试传真的 ffi 模块加一个桩库.
---@param opts {ffi: table?, lib: table?}?
---@return boolean ok
---@return string? err
function M.load(opts)
  opts = opts or {}
  local injected = opts.ffi ~= nil or opts.lib ~= nil
  if M.available then
    return true
  end
  if M.failed_once and not injected then
    return false, M.error
  end
  M.failed_once = true
  local ok, ffi_lib = pcall(require, "ffi")
  if opts.ffi then
    ok, ffi_lib = true, opts.ffi
  end
  if not ok then
    M.error = "ffi 不可用"
    return false, M.error
  end
  local defined, cdef_err = cdef(ffi_lib)
  if not defined then
    M.error = "ffi.cdef 失败: " .. tostring(cdef_err)
    return false, M.error
  end
  -- 声明通过之后才能用 ffi 做别的事 (has_encoder 会用到 lib)
  ffi = ffi_lib
  -- Android 上按库名加载; 找不到时 ffmpeg 那条路也用不成, 直接报告.
  local ok_media, media
  if opts.lib then
    ok_media, media = true, opts.lib
  else
    ok_media, media = pcall(ffi_lib.load, "mediandk")
  end
  if not ok_media then
    M.error = "加载 libmediandk 失败: " .. tostring(media)
    return false, M.error
  end
  M.media = media
  M.available = true
  M.error = nil
  return true
end

---@return boolean 是否可用
function M.is_available()
  return M.available == true
end

--- 这台设备能不能建出这个 mime 的编码器. 马上就删掉, 只作为探测.
---
--- NDK 没有稳定的 C 接口能枚举编码器: AMediaCodecList 是 C++ 的类 (符号被 mangle),
--- AMediaCodecStore_* 是 API 36 (Android 16) 才有的, 设备上多半没有. 所以这里用创建试探,
--- 它也正好是真正要用到的能力.
---@param mime string 例如 "video/avc"
---@return boolean
function M.has_encoder(mime)
  if not M.available then
    return false
  end
  local codec = M.media.AMediaCodec_createEncoderByType(mime)
  if codec == nil then
    return false
  end
  M.media.AMediaCodec_delete(codec)
  return true
end

--- 一次自检: media 库是否加载, 能不能建出 H.264 与 AAC 编码器. 开销很小.
---@return {ok: boolean, error: string?, h264: boolean, aac: boolean}
function M.probe()
  local result = { ok = false, h264 = false, aac = false }
  local ok, err = M.load()
  if not ok then
    result.error = err
    return result
  end
  result.ok = true
  result.h264 = M.has_encoder("video/avc")
  result.aac = M.has_encoder("audio/mp4a-latm")
  return result
end

return M
