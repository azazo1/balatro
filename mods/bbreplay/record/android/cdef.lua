--[[
media 绑定层的 C 声明, 主线程 (android/ffi.lua) 与编码线程 (android/encoder_thread.lua) 共用一份.

单独成文件的原因: 编码线程是独立的 Lua 状态, 那里没有 SMODS, 拿不到 mod 里的模块, 声明文本只能
作为参数传给线程. 两份声明是不可能保持同步的, 所以只留这一份.

本文件是纯数据, 不依赖任何全局, 可以直接用 luajit 加载做检查.

声明覆盖三处: libmediandk (MediaCodec/Muxer), libc (Muxer 按 fd 写), libbbnet (颜色转换).
只声明实际调用的函数. 必须与真实导出符号一致: ffi.cdef 只声明不校验, 名字写错要到真机上第一次
调用才发现. scripts/tests/test_media_symbols.py 用 NDK sysroot 的库逐个核对.
]]

local M = {}

M.CDECL = [[
    typedef int32_t media_status_t;

    // ---- AMediaFormat ----
    typedef struct AMediaFormat AMediaFormat;
    AMediaFormat *AMediaFormat_new(void);
    void AMediaFormat_delete(AMediaFormat *format);
    void AMediaFormat_setString(AMediaFormat *format, const char *name, const char *value);
    void AMediaFormat_setInt32(AMediaFormat *format, const char *name, int32_t value);
    void AMediaFormat_setFloat(AMediaFormat *format, const char *name, float value);

    // ---- AMediaCodec ----
    typedef struct AMediaCodec AMediaCodec;

    typedef struct AMediaCodecBufferInfo {
      int32_t offset;
      int32_t size;
      int64_t presentationTimeUs;
      uint32_t flags;
    } AMediaCodecBufferInfo;

    AMediaCodec *AMediaCodec_createEncoderByType(const char *mime);
    AMediaCodec *AMediaCodec_createCodecByName(const char *name);
    media_status_t AMediaCodec_configure(AMediaCodec *codec, const AMediaFormat *format,
                                         void *surface, void *crypto, uint32_t flags);
    media_status_t AMediaCodec_start(AMediaCodec *codec);
    media_status_t AMediaCodec_stop(AMediaCodec *codec);
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
    ssize_t AMediaMuxer_addTrack(AMediaMuxer *muxer, const AMediaFormat *format);
    media_status_t AMediaMuxer_start(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_stop(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_delete(AMediaMuxer *muxer);
    media_status_t AMediaMuxer_writeSampleData(AMediaMuxer *muxer, size_t trackIndex,
                                               const uint8_t *data, const AMediaCodecBufferInfo *info);

    // ---- libc: 输出文件描述符 (AMediaMuxer 按 fd 写) ----
    // 不用变参声明 open: LuaJIT 把变参里的 Lua 数字按 double 传, mode 会按 4 字节读成 0,
    // 文件权限就成了 0000 (连自己都读不到). 显式写死 mode 参数, 并换成 bb_ 前缀的名字,
    // 免得和别处已声明的 open 冲突 (android_storage.lua 的 chmod 等也是这么做的).
    int bb_open(const char *path, int flags, int mode) __asm__("open");
    int bb_close(int fd) __asm__("close");

    // ---- libbbnet: 颜色转换 (画布数据交给硬件编码器之前要先转成 NV12) ----
    int bbnet_rgba_to_nv12(const uint8_t *rgba, int32_t width, int32_t height, int32_t rgba_stride,
                           uint8_t *dst, int32_t y_stride, int32_t uv_stride);
    int64_t bbnet_nv12_size(int32_t width, int32_t height);
]]

M.NEEDED_TYPES = {
  "media_status_t",
  "AMediaFormat",
  "AMediaCodec",
  "AMediaCodecBufferInfo",
  "AMediaMuxer",
}

return M
