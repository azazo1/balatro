--[[
局末后处理: 录制结束后在后台生成两份视频, 游戏继续运行或退出都不影响.
- <stem>-full.mp4: 画面 (直接复制) + 声音, 与墙钟等长.
- <stem>-cut.mp4: 从同一份素材剪掉 cuts 里的区间, 重新编码.
中间文件 <stem>.video.mp4 与 <stem>.pcm 成功后删除. 失败时保留, 连同 <stem>.post.sh, 可以手动重跑.
]]

local M = {}

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function fmt(x)
  return string.format("%.3f", x)
end

--- ffmpeg select 表达式: 保留不在任何剪辑区间里的帧. 没有剪辑区间时返回 nil.
---@param cuts {start: number, stop: number}[]
---@return string?
function M.keep_expr(cuts)
  if #cuts == 0 then
    return nil
  end
  local parts = {}
  for _, cut in ipairs(cuts) do
    -- 半开区间 [start, stop), 剪掉的帧数与 cut_time 的换算一致
    parts[#parts + 1] = "gte(t," .. fmt(cut.start) .. ")*lt(t," .. fmt(cut.stop) .. ")"
  end
  return "not(" .. table.concat(parts, "+") .. ")"
end

---@param opts {ffmpeg: string, codec_args: string, base: string, fps: integer, audio: boolean, cuts: table}
---@return string script
function M.script(opts)
  local ff = shell_quote(opts.ffmpeg) .. " -y -hide_banner -loglevel error"
  local video = shell_quote(opts.base .. ".video.mp4")
  local pcm = shell_quote(opts.base .. ".pcm")
  local full = shell_quote(opts.base .. "-full.mp4")
  local cut = shell_quote(opts.base .. "-cut.mp4")
  local log = shell_quote(opts.base .. ".ffmpeg.txt")
  local audio_in = opts.audio and (" -f s16le -ar 44100 -ac 2 -i " .. pcm) or ""
  local lines = {
    "#!/bin/sh",
    "# 由 agent/record/post.lua 生成: 合成完整版与剪辑版视频. 失败时可以手动重跑.",
    "trap '' INT HUP TERM",
    "sleep 1", -- 等游戏退出时编码线程写完最后几帧
    "ok=1",
  }
  -- 完整版: 画面直接复制, 只编码声音
  if opts.audio then
    lines[#lines + 1] = ff .. " -i " .. video .. audio_in
      .. " -map 0:v -map 1:a -c:v copy -c:a aac -b:a 160k -movflags +faststart " .. full .. " 2>>" .. log .. " || ok=0"
  else
    lines[#lines + 1] = ff .. " -i " .. video .. " -c copy -movflags +faststart " .. full .. " 2>>" .. log .. " || ok=0"
  end
  -- 剪辑版: 声音按一帧的长度切块, 与画面在同样的帧边界上取舍, 多次剪辑后也不会错位
  local expr = M.keep_expr(opts.cuts)
  if not expr then
    lines[#lines + 1] = "[ $ok = 1 ] && cp " .. full .. " " .. cut .. " || ok=0"
  else
    local graph = "[0:v]select='" .. expr .. "',setpts=N/FRAME_RATE/TB[v]"
    local maps = " -map '[v]'"
    if opts.audio then
      local samples = math.floor(44100 / opts.fps + 0.5)
      graph = graph .. ";[1:a]asetnsamples=n=" .. samples .. ":p=0,aselect='" .. expr .. "',asetpts=N/SR/TB[a]"
      maps = maps .. " -map '[a]' -c:a aac -b:a 160k"
    end
    lines[#lines + 1] = ff .. " -i " .. video .. audio_in .. " -filter_complex " .. shell_quote(graph) .. maps
      .. " " .. opts.codec_args .. " -pix_fmt yuv420p -r " .. opts.fps .. " -movflags +faststart " .. cut
      .. " 2>>" .. log .. " || ok=0"
  end
  lines[#lines + 1] = "if [ $ok = 1 ]; then"
  lines[#lines + 1] = "  rm -f " .. video .. " " .. pcm .. " \"$0\""
  lines[#lines + 1] = "  [ -s " .. log .. " ] || rm -f " .. log
  lines[#lines + 1] = "fi"
  return table.concat(lines, "\n") .. "\n"
end

--- 写出脚本并在后台运行. 用 perl 的 setsid 脱离游戏的进程组, 终端里按 Ctrl-C 或关掉游戏都不会打断它.
---@param opts table 同 M.script
---@return boolean ok
---@return string? err
function M.spawn(opts)
  local path = opts.base .. ".post.sh"
  local file, err = io.open(path, "wb")
  if not file then
    return false, tostring(err)
  end
  file:write(M.script(opts))
  file:close()
  local quoted = shell_quote(path)
  local detach = "if command -v perl >/dev/null 2>&1; then "
    .. "perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/sh " .. quoted .. " </dev/null >/dev/null 2>&1 & "
    .. "else nohup /bin/sh " .. quoted .. " </dev/null >/dev/null 2>&1 & fi"
  os.execute(detach)
  return true
end

return M
