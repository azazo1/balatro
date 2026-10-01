-- 录制编码线程: 从 frames 通道取 ImageData, 以原始 RGBA 写进 ffmpeg 的标准输入.
-- 参数: command, frames (Channel), status (Channel), win_source, output.
-- - 桌面 POSIX: command 是完整的 shell 命令 (含 stderr 重定向), 用 io.popen 打开.
-- - Windows: win_source 是 record/win_proc.lua 的源码, command 是 ffmpeg 的命令行, ffmpeg 的输出写到 output.
--   不用 io.popen: 它会弹控制台窗口, 而且文本模式会把画面里的 0x0A 改成 0x0D 0x0A.
-- frames 里的元素是 {image = ImageData, count = 重复次数}, 收到字符串 "stop" 时关闭管道并退出.

local command, frames, status, win_source, output = ...

require("love.image")
require("love.data")

local ffi = require("ffi")

-- 打开 ffmpeg, 返回 write(image) -> ok, err 与 close() -> ok, code, err.
local function open_pipe()
  if win_source then
    local Proc = assert(loadstring(win_source, "=win_proc.lua"))()
    local proc, err = Proc.spawn(command, { stdin = true, output = output })
    if not proc then
      return nil, err
    end
    local function write(image)
      -- 直接写 ImageData 的内存, 不复制成字符串.
      return Proc.write(proc, image:getFFIPointer(), image:getSize())
    end
    local function close()
      local code, wait_err = Proc.wait(proc, 30000)
      return code == 0, code, wait_err
    end
    return write, close
  end

  -- ffmpeg 异常退出后继续写入会触发 SIGPIPE, 默认会结束整个游戏进程. 忽略它, 让写入返回错误.
  pcall(function()
    ffi.cdef("typedef void (*bb_sighandler_t)(int); bb_sighandler_t signal(int sig, bb_sighandler_t handler);")
    ffi.C.signal(13, ffi.cast("bb_sighandler_t", 1)) -- SIGPIPE, SIG_IGN
  end)
  local pipe, open_err = io.popen(command, "w")
  if not pipe then
    return nil, open_err
  end
  local function write(image)
    return pipe:write(image:getString())
  end
  local function close()
    local closed, _, code = pipe:close()
    return closed and true or false, code
  end
  return write, close
end

local write, close = open_pipe()
if not write then
  status:push({ kind = "error", message = "failed to start ffmpeg: " .. tostring(close) })
  return
end

local written = 0
local failed = nil
while true do
  local item = frames:demand()
  if item == "stop" then
    break
  end
  local image = item.image
  if not failed then
    for _ = 1, item.count or 1 do
      local ok, err = write(image)
      if not ok then
        failed = tostring(err)
        status:push({ kind = "error", message = "ffmpeg pipe write failed: " .. failed })
        break
      end
      written = written + 1
    end
  end
  -- 每帧几 MB 的原生内存, 不等 GC, 用完立即释放.
  image:release()
end

local exit_ok, code, close_err = close()
status:push({
  kind = "done",
  frames = written,
  exit_ok = exit_ok,
  code = code,
  error = failed or close_err,
})
