-- 录制编码线程: 从 frames 通道取 ImageData, 以原始 RGBA 写进 ffmpeg 的标准输入.
-- 参数: command (完整的 shell 命令), frames (Channel), status (Channel).
-- frames 里的元素是 {image = ImageData, count = 重复次数}, 收到字符串 "stop" 时关闭管道并退出.

local command, frames, status = ...

require("love.image")
require("love.data")

-- ffmpeg 异常退出后继续写入会触发 SIGPIPE, 默认会结束整个游戏进程. 忽略它, 让写入返回错误.
pcall(function()
  local ffi = require("ffi")
  if ffi.os ~= "Windows" then
    ffi.cdef("typedef void (*bb_sighandler_t)(int); bb_sighandler_t signal(int sig, bb_sighandler_t handler);")
    ffi.C.signal(13, ffi.cast("bb_sighandler_t", 1)) -- SIGPIPE, SIG_IGN
  end
end)

local pipe, open_err = io.popen(command, "w")
if not pipe then
  status:push({ kind = "error", message = "failed to start ffmpeg: " .. tostring(open_err) })
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
    local bytes = image:getString()
    for _ = 1, item.count or 1 do
      local ok, err = pipe:write(bytes)
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

local closed, _, code = pipe:close()
status:push({ kind = "done", frames = written, exit_ok = closed and true or false, code = code, error = failed })
