--[[
Android 录像在主线程上的 media 绑定: 只用来判断这台设备能不能建出 H.264 编码器.
真正的编码在 android/encoder_thread.lua 里 (独立的 Lua 状态, 自己 cdef 与加载库).

非 Android 或库加载失败时 M.load() 返回 false 并给出原因, 调用方退回原路径.
任何一步失败都不应影响游戏, 所以这里不做 assert.
]]

local M = {}

-- 运行时加载自己的模块要显式给出 mod id (SMODS.load_file 只在首次加载 mod 时可以省).
local MOD_ID = "bbreplay"

--- cdef 之后逐个核对类型是否真的声明成功.
--- 只看 cdef 的返回值不够: 同一个 Lua 状态里重复声明会报 "attempt to redefine", 那其实说明已经声明好了;
--- 反过来, 声明文本漏了某个类型 (例如 Android 特有的 media_status_t) 时又必须报错而不是静默跳过.
---@param lib table ffi 模块
---@param needed string[]
---@return string? missing 第一个还没声明的类型
local function missing_type(lib, needed)
  for _, name in ipairs(needed) do
    if not pcall(lib.typeof, name) then
      return name
    end
  end
  return nil
end

---@return boolean ok
---@return string? err
local function cdef(lib, Cdef)
  local ok, err = pcall(lib.cdef, Cdef.CDECL)
  local missing = missing_type(lib, Cdef.NEEDED_TYPES)
  if not missing then
    return true
  end
  if ok then
    -- cdef 没报错, 但类型不全: 说明声明块本身有问题
    return false, "声明之后仍缺少类型: " .. missing
  end
  return false, tostring(err) .. " (缺少类型: " .. missing .. ")"
end

--- 加载 media 库. 成功后 M.media 为库命名空间.
--- opts 只给单测注入用: 开发机上没有 libmediandk, 但 cdef 本身可以真跑 (声明文本有错时 ffi.cdef
--- 会失败), 所以测试传真的 ffi 模块加一个桩库.
---@param opts {ffi: table?, lib: table?, cdef: table?}?
---@return boolean ok
---@return string? err
function M.load(opts)
  opts = opts or {}
  local Cdef = opts.cdef or assert(SMODS.load_file("record/android/cdef.lua", MOD_ID))()
  local ok, ffi_lib = true, opts.ffi
  if not ffi_lib then
    ok, ffi_lib = pcall(require, "ffi")
  end
  if not ok then
    return false, "ffi 不可用"
  end
  local defined, cdef_err = cdef(ffi_lib, Cdef)
  if not defined then
    return false, "ffi.cdef 失败: " .. tostring(cdef_err)
  end
  local ok_media, media = true, opts.lib
  if not media then
    ok_media, media = pcall(ffi_lib.load, "mediandk")
  end
  if not ok_media then
    return false, "加载 libmediandk 失败: " .. tostring(media)
  end
  M.media = media
  return true
end

--- 这台设备能不能建出这个 mime 的编码器 (建出来马上删掉). 需要先 M.load() 成功.
---
--- NDK 没有稳定的 C 接口能枚举编码器: AMediaCodecList 是 C++ 的类 (符号被 mangle),
--- AMediaCodecStore_* 是 API 36 (Android 16) 才有的, 设备上多半没有. 所以这里用创建试探,
--- 它也正好是真正要用到的能力.
---@param mime string 例如 "video/avc"
---@return boolean
function M.has_encoder(mime)
  local codec = M.media.AMediaCodec_createEncoderByType(mime)
  if codec == nil then
    return false
  end
  M.media.AMediaCodec_delete(codec)
  return true
end

return M
