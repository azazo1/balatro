-- Android media 绑定层的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 用真的 ffi 模块跑 cdef, 声明文本有错 (例如漏了 media_status_t) 就会失败;
-- 库本身用桩代替 (开发机上没有 libmediandk).

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

--- 桩库: 只回答探测需要的函数. 真实语义: createEncoderByType 建不出来就返回 NULL.
---@param h264 boolean 有没有 H.264 编码器
local function stub_lib(h264)
  local handle = ffi.new("char[1]")
  return {
    AMediaCodec_createEncoderByType = function(mime)
      if mime == "video/avc" and h264 then
        return ffi.cast("AMediaCodec *", handle)
      end
      return nil
    end,
    AMediaCodec_delete = function()
      return 0
    end,
  }
end

do -- 首次加载: cdef 文本必须真能被 LuaJIT 解析
  local Media = dofile("mods/balatrobot/agent/record/android/ffi.lua")
  local ok, err = Media.load({ ffi = ffi, cdef = Cdef, lib = stub_lib(true) })
  check("加载 media 库", ok, tostring(err))
  check("有 H.264 编码器", Media.has_encoder("video/avc") == true)
end

do -- 同一个 Lua 状态里再加载一次: 重复声明报错, 但类型都在, 应按已声明处理
  local Media = dofile("mods/balatrobot/agent/record/android/ffi.lua")
  local ok, err = Media.load({ ffi = ffi, cdef = Cdef, lib = stub_lib(false) })
  check("重复声明仍能加载", ok, tostring(err))
  check("没有编码器时如实报告", Media.has_encoder("video/avc") == false)
end

do -- cdef 失败且类型缺失时给出原因而不是崩
  local Media = dofile("mods/balatrobot/agent/record/android/ffi.lua")
  local bad = {
    cdef = function()
      error("cannot parse")
    end,
    typeof = function()
      error("undeclared")
    end,
    load = function()
      error("should not be reached")
    end,
  }
  local ok, err = Media.load({ ffi = bad, cdef = Cdef })
  check("cdef 失败时返回 false 与原因", ok == false and type(err) == "string", tostring(err))
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("media 绑定全部通过")
