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
---@field codec_list table AMediaCodecList 相关函数

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

local function cdef()
  local ok, err = pcall(ffi.cdef, [[
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
    media_status_t AMediaCodec_release(AMediaCodec *codec);
    uint8_t *AMediaCodec_getInputBuffer(AMediaCodec *codec, size_t index, size_t *out_size);
    uint8_t *AMediaCodec_getOutputBuffer(AMediaCodec *codec, size_t index, size_t *out_size);
    ssize_t AMediaCodec_dequeueInputBuffer(AMediaCodec *codec, int64_t timeoutUs);
    media_status_t AMediaCodec_queueInputBuffer(AMediaCodec *codec, size_t index, size_t offset,
                                                size_t size, uint64_t time, uint32_t flags);
    ssize_t AMediaCodec_dequeueOutputBuffer(AMediaCodec *codec, AMediaCodecBufferInfo *info,
                                            int64_t timeoutUs);
    media_status_t AMediaCodec_releaseOutputBuffer(AMediaCodec *codec, size_t index, bool render);
    AMediaFormat *AMediaCodec_getOutputFormat(AMediaCodec *codec);

    // ---- AMediaCodecList ----
    size_t AMediaCodecList_getCodecCount(void);
    media_status_t AMediaCodecList_getCodecNameByType(const char *mime, size_t index, bool encoder,
                                                      char *name, size_t nameSize);

    // ---- AMediaMuxer ----
    typedef struct AMediaMuxer AMediaMuxer;
    AMediaMuxer *AMediaMuxer_new(int fd, int32_t format);
    media_status_t AMediaMuxer_setOrientationHint(AMediaMuxer *muxer, int degrees);
    ssize_t AMediaMuxer_addTrack(AMediaMuxer *muxer, const AMediaFormat *format);
    media_status_t AMediaMuxer_start(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_stop(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_release(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_writeSampleData(AMediaMuxer *muxer, size_t trackIndex,
                                               const uint8_t *data, const AMediaCodecBufferInfo *info);

    // ---- AMediaExtractor (剪辑时按关键帧取样本) ----
    typedef struct AMediaExtractor AMediaExtractor;
    AMediaExtractor *AMediaExtractor_new(void);
    media_status_t AMediaExtractor_setDataSourceFd(AMediaExtractor *ex, int fd, int64_t offset,
                                                   int64_t length);
    media_status_t AMediaExtractor_release(AMediaExtractor *ex);
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
  ]])
  return ok, err
end

--- 加载 native 库. 可重复调用, 结果缓存.
---@return boolean ok
---@return string? err
function M.load()
  if M.available then
    return true
  end
  if M.failed_once then
    return false, M.error
  end
  M.failed_once = true
  local ok, ffi_lib = pcall(require, "ffi")
  if not ok then
    M.error = "ffi 不可用"
    return false, M.error
  end
  local defined, cdef_err = cdef()
  if not defined then
    M.error = "ffi.cdef 失败: " .. tostring(cdef_err)
    return false, M.error
  end
  -- Android 上按库名加载; 找不到时 ffmpeg 那条路也用不成, 直接报告.
  local ok_media, media = pcall(ffi_lib.load, "mediandk")
  if not ok_media then
    M.error = "加载 libmediandk 失败: " .. tostring(media)
    return false, M.error
  end
  ffi = ffi_lib
  M.media = media
  M.available = true
  M.error = nil
  return true
end

---@return boolean 是否可用
function M.is_available()
  return M.available == true
end

--- mime 对应的编码器名字列表, 用于日志与排查. 不创建编码器实例.
---@param mime string 例如 "video/avc"
---@return string[]
function M.encoder_names(mime)
  local names = {}
  if not M.available then
    return names
  end
  local count = M.media.AMediaCodecList_getCodecCount()
  local buf = ffi.new("char[256]")
  for i = 0, count - 1 do
    local status = M.media.AMediaCodecList_getCodecNameByType(mime, i, true, buf, 256)
    if status == 0 then
      names[#names + 1] = ffi.string(buf)
    end
  end
  return names
end

--- 一次自检: media 库是否加载, 有哪些编码器. 开销很小 (不创建编码器实例).
---@return {ok: boolean, error: string?, h264: string[], aac: string[]}
function M.probe()
  local result = { ok = false, h264 = {}, aac = {} }
  local ok, err = M.load()
  if not ok then
    result.error = err
    return result
  end
  result.ok = true
  result.h264 = M.encoder_names("video/avc")
  result.aac = M.encoder_names("audio/mp4a-latm")
  return result
end

return M
