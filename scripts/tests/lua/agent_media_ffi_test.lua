-- Android media 绑定层的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 起因: 点 "录制对局" 时崩过两次 (setup 里读不存在的 ffi upvalue; media_status_t 没声明).
-- 这里用真的 ffi 模块跑 cdef, 声明文本有错就会失败; 库本身用桩代替 (开发机上没有 libmediandk).

local Media = dofile("mods/balatrobot/agent/record/android/ffi.lua")
-- 声明文本与需要的类型来自 cdef.lua (编码线程用同一份); 测试里直接加载它注入.
local Cdef = dofile("mods/balatrobot/agent/record/android/cdef.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local ffi = require("ffi")

--- 桩库: cdef 之后所有调用都落到这里, 只回答探测需要的函数.
--- 真实语义: createEncoderByType 建不出来就返回 NULL, 所以要删掉时才有对象.
---@param available {h264: boolean?, aac: boolean?}
local function stub_lib(available)
  local live = {}
  return {
    AMediaCodec_createEncoderByType = function(mime)
      local ok = (mime == "video/avc" and available.h264) or (mime == "audio/mp4a-latm" and available.aac)
      if not ok then
        return nil
      end
      -- 返回一个真指针 (用一块真分配的内存冒充), 让 delete 有东西可接
      local handle = ffi.new("char[1]")
      live[handle] = true
      return ffi.cast("AMediaCodec *", handle)
    end,
    AMediaCodec_delete = function(codec)
      live[codec] = nil
      return 0
    end,
  }
end

do -- 加载成功: cdef 文本必须真能被 LuaJIT 解析 (media_status_t 之类的类型漏声明时这里就会失败)
  local ok, err = Media.load({ ffi = ffi, cdef = Cdef, lib = stub_lib({ h264 = true, aac = true }) })
  check("加载 media 库", ok, tostring(err))
  check("加载后标记可用", Media.is_available() == true)
end

do -- 探测: 能不能建出 H.264 与 AAC 编码器
  local probe = Media.probe()
  check("探测成功", probe.ok, tostring(probe.error))
  check("报告有 H.264 编码器", probe.h264 == true)
  check("报告有 AAC 编码器", probe.aac == true)
  check("能单独判断 H.264", Media.has_encoder("video/avc") == true)
end

do -- 设备上没有对应编码器时: 探测仍然成功, 但如实报告为 false
  local fresh = dofile("mods/balatrobot/agent/record/android/ffi.lua")
  local ok, err = fresh.load({ ffi = ffi, cdef = Cdef, lib = stub_lib({ h264 = false, aac = false }) })
  check("没有编码器也能通过加载", ok, tostring(err))
  local probe = fresh.probe()
  check("没有 H.264 编码器时报告 false", probe.ok and probe.h264 == false, tostring(probe.error))
  check("没有 AAC 编码器时报告 false", probe.aac == false)
end

do -- 没有 ffi 时给出原因而不是崩
  local fresh = dofile("mods/balatrobot/agent/record/android/ffi.lua")
  -- 用一个 cdef 会失败的对象冒充 ffi 模块
  local bad = {
    cdef = function()
      error("cannot parse")
    end,
    load = function()
      error("should not be reached")
    end,
  }
  local ok, err = fresh.load({ ffi = bad, cdef = Cdef })
  check("cdef 失败时返回 false", ok == false)
  check("cdef 失败时说明原因", type(err) == "string" and err:find("cdef", 1, true) ~= nil, tostring(err))
  check("cdef 失败时不可用", fresh.is_available() == false)
end

do -- 常量表: 编码器配置要用到的键与颜色格式
  check("NV12 颜色格式是 21", Media.VALUE.COLOR_FormatYUV420SemiPlanar == 21)
  check("编码标志存在", Media.VALUE.CONFIGURE_FLAG_ENCODE == 1)
  check("关键帧标志是 1", Media.BUFFER_FLAG.KEY_FRAME == 1)
  check("结束标志是 4", Media.BUFFER_FLAG.END_OF_STREAM == 4)
  check("格式变更返回码是 -2", Media.INFO.OUTPUT_FORMAT_CHANGED == -2)
  check("mime 键名", Media.KEYS.mime == "mime" and Media.KEYS.color_format == "color-format")
  -- AMediaCodecBufferInfo 的布局必须是 offset, size, presentationTimeUs, flags
  local info = ffi.new("AMediaCodecBufferInfo")
  check("缓冲区信息可分配", info ~= nil)
  check("缓冲区信息是一个结构体", ffi.sizeof(info) >= 16, tostring(ffi.sizeof(info)))
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("media 绑定全部通过")
