--[[
合成脚本: 从中间文件 <stem>.video.mp4 与 <stem>.pcm 生成 <stem>-full.mp4 (画面直接复制 + 声音, 与墙钟等长).

两种写法 (opts.dialect), 内容一致:
- "sh" (默认): <stem>.post.sh, macOS / Linux.
- "cmd": <stem>.post.cmd, Windows 的批处理. 后台运行由调用方 (record/win_proc.lua) 启动, 不开窗口.

脚本有两种:
- 草稿 (draft): 开局时写出, 只写不执行. 游戏崩溃后用它补做合成
  (sh <stem>.post.sh, Windows 上直接运行 <stem>.post.cmd, 或 scripts/recordings_recover.py).
  声音在运行时按 .pcm 是否非空决定.
  默认不删中间文件, 带 --clean 且全部成功时才删, 即使在录制中被误执行也只会得到一份不完整的视频,
  不会破坏还在写的中间文件.
- 局末 (final): 局末覆盖草稿并在后台运行, 游戏继续运行或退出都不影响.
  成功后删除中间文件与脚本自身 (保留方式为 keep 时只删脚本); 失败时保留, 可以手动重跑.
两种脚本都以退出码表示是否全部成功 (Windows 上删掉脚本自身后退出码不可靠, 以产物为准).
写入先写临时文件再改名, 不会留下写了一半的脚本.
]]

local M = {}

-- ==========================================================================
-- 两种写法的差异: 引号, 失败标记, 判断, 删除
-- ==========================================================================

local SH = { ext = ".post.sh" }

--- 单引号包住, 内部的单引号改写成 '\''.
function SH.quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
SH.fail = " || ok=0"

local CMD = { ext = ".post.cmd" }

--- 批处理里的路径: 改成反斜杠 (del 等内部命令把 / 当成开关), 双引号包住, % 写成 %%.
--- 路径里不会有双引号 (Windows 文件名不允许).
function CMD.quote(s)
  local path = tostring(s):gsub("/", "\\"):gsub("%%", "%%%%")
  return '"' .. path .. '"'
end
CMD.fail = " || set ok=0"

local DIALECTS = { sh = SH, cmd = CMD }

---@param opts table
---@return table
local function dialect(opts)
  return DIALECTS[opts.dialect or "sh"] or SH
end

--- 合成命令, with_audio 表示是否混入 .pcm. 画面直接复制, 只编码声音.
---@return string[] lines
local function commands(opts, with_audio)
  local d = dialect(opts)
  local q = d.quote
  local ff = q(opts.ffmpeg) .. " -y -hide_banner -loglevel error"
  local video = q(opts.base .. ".video.mp4")
  local full = q(opts.base .. "-full.mp4")
  local log = q(opts.base .. ".ffmpeg.txt")
  if not with_audio then
    return { ff .. " -i " .. video .. " -c copy -movflags +faststart " .. full .. " 2>>" .. log .. d.fail }
  end
  local audio_in = " -f s16le -ar 44100 -ac 2 -i " .. q(opts.base .. ".pcm")
  -- 崩溃后画面只到最后一个完整的分片 (约 2 秒一个), 声音每秒落盘, 通常更长; 草稿按短的一方截齐.
  -- 局末两者等长, 不需要.
  local shortest = opts.draft and " -shortest" or ""
  return {
    ff .. " -i " .. video .. audio_in
      .. " -map 0:v -map 1:a -c:v copy -c:a aac -b:a 160k" .. shortest .. " -movflags +faststart " .. full
      .. " 2>>" .. log .. d.fail,
  }
end

local function sh_script(opts)
  local q = SH.quote
  local video = q(opts.base .. ".video.mp4")
  local pcm = q(opts.base .. ".pcm")
  local log = q(opts.base .. ".ffmpeg.txt")
  local lines = { "#!/bin/sh" }
  if opts.draft then
    lines[#lines + 1] = "# bb-post: draft"
    lines[#lines + 1] = "# 由 record/post.lua 在录制中写出, 游戏崩溃时用于补做合成: sh <本文件> [--clean]."
    lines[#lines + 1] = "# 默认保留中间文件, 带 --clean 且全部成功时删除."
  else
    lines[#lines + 1] = "# bb-post: final"
    lines[#lines + 1] = "# 由 record/post.lua 在局末写出并运行: 合成 -full.mp4. 失败时可以手动重跑."
    if opts.keep then
      lines[#lines + 1] = "# 保留方式为 keep: 成功后不删中间文件."
    end
    lines[#lines + 1] = "trap '' INT HUP TERM"
    lines[#lines + 1] = "sleep 1" -- 等游戏退出时编码线程写完最后几帧
  end
  lines[#lines + 1] = "ok=1"
  if opts.audio == "auto" then
    lines[#lines + 1] = "if [ -s " .. pcm .. " ]; then"
    for _, line in ipairs(commands(opts, true)) do
      lines[#lines + 1] = "  " .. line
    end
    lines[#lines + 1] = "else"
    for _, line in ipairs(commands(opts, false)) do
      lines[#lines + 1] = "  " .. line
    end
    lines[#lines + 1] = "fi"
  else
    for _, line in ipairs(commands(opts, opts.audio == true)) do
      lines[#lines + 1] = line
    end
  end
  -- 草稿只在显式要求时清理: 录制中被误执行也不会删掉还在写的中间文件.
  -- 局末默认清理; 保留方式为 keep 时只删脚本自身, 中间文件留着供事后重跑.
  if opts.keep and not opts.draft then
    lines[#lines + 1] = "[ $ok = 1 ] && rm -f \"$0\""
  else
    lines[#lines + 1] = opts.draft and "if [ $ok = 1 ] && [ \"${1:-}\" = --clean ]; then" or "if [ $ok = 1 ]; then"
    lines[#lines + 1] = "  rm -f " .. video .. " " .. pcm .. " \"$0\""
    lines[#lines + 1] = "fi"
  end
  lines[#lines + 1] = "[ $ok = 1 ] && { [ -s " .. log .. " ] || rm -f " .. log .. "; }"
  lines[#lines + 1] = "[ $ok = 1 ]"
  return table.concat(lines, "\n") .. "\n"
end

--- 批处理版. 和 sh 版的流程一致; 分支用 goto 而不是括号块, 删除脚本自身放在最后一行.
local function cmd_script(opts)
  local q = CMD.quote
  local video = q(opts.base .. ".video.mp4")
  local pcm = q(opts.base .. ".pcm")
  local log = q(opts.base .. ".ffmpeg.txt")
  local lines = {
    "@echo off",
    -- 路径可能有中文, 先切到 UTF-8 代码页再往下读.
    "chcp 65001 >nul",
    "setlocal",
  }
  if opts.draft then
    lines[#lines + 1] = "rem bb-post: draft"
    lines[#lines + 1] = "rem 由 record/post.lua 在录制中写出, 游戏崩溃时用于补做合成: 运行本文件 [--clean]."
    lines[#lines + 1] = "rem 默认保留中间文件, 带 --clean 且全部成功时删除."
  else
    lines[#lines + 1] = "rem bb-post: final"
    lines[#lines + 1] = "rem 由 record/post.lua 在局末写出并在后台运行: 合成 -full.mp4. 失败时可以手动重跑."
    if opts.keep then
      lines[#lines + 1] = "rem 保留方式为 keep: 成功后不删中间文件."
    end
    -- 没有 sleep; ping 本机两次约等 1 秒, 等游戏退出时编码线程写完最后几帧.
    lines[#lines + 1] = "ping -n 2 127.0.0.1 >nul"
  end
  lines[#lines + 1] = "set ok=1"
  if opts.audio == "auto" then
    -- 文件不存在时 %%~zF 为空, 先判断存在, 否则 if 的比较会报语法错误.
    lines[#lines + 1] = "set size=0"
    lines[#lines + 1] = "if exist " .. pcm .. " for %%F in (" .. pcm .. ") do set size=%%~zF"
    lines[#lines + 1] = "if %size% GTR 0 goto with_audio"
    for _, line in ipairs(commands(opts, false)) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = "goto merged"
    lines[#lines + 1] = ":with_audio"
    for _, line in ipairs(commands(opts, true)) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ":merged"
  else
    for _, line in ipairs(commands(opts, opts.audio == true)) do
      lines[#lines + 1] = line
    end
  end
  lines[#lines + 1] = "if not %ok%==1 exit /b 1"
  -- 加引号比较: 文件不存在时 %%~zF 为空, 不加引号会变成 "if ==0" 的语法错误, 整个脚本中止.
  lines[#lines + 1] = "if exist " .. log .. " for %%F in (" .. log .. ') do if "%%~zF"=="0" del ' .. log .. " 2>nul"
  if opts.draft then
    -- 草稿只在带 --clean 时清理, 也不删自己 (留着可以再跑).
    lines[#lines + 1] = 'if not "%~1"=="--clean" exit /b 0'
    lines[#lines + 1] = "del " .. video .. " " .. pcm .. " 2>nul"
    lines[#lines + 1] = "exit /b 0"
  else
    if not opts.keep then
      lines[#lines + 1] = "del " .. video .. " " .. pcm .. " 2>nul"
    end
    -- 删掉正在运行的脚本自身: 先 (goto) 跳出脚本上下文, 不会再去读已删除的文件.
    lines[#lines + 1] = '(goto) 2>nul & del "%~f0"'
  end
  return table.concat(lines, "\r\n") .. "\r\n"
end

--- 生成合成脚本.
--- audio: true/false 在生成时确定; "auto" 在运行时按 .pcm 是否非空决定 (草稿用, 写脚本时录音还没结束).
--- keep: true 时合成成功也保留中间文件 (设置页的 "保留方式: keep"), 只删脚本自身.
--- dialect: "sh" (默认) 或 "cmd".
---@param opts {ffmpeg: string, base: string, audio: boolean|"auto", draft: boolean?, keep: boolean?, dialect: string?}
---@return string script
function M.script(opts)
  if dialect(opts) == CMD then
    return cmd_script(opts)
  end
  return sh_script(opts)
end

--- 脚本的文件路径: <base>.post.sh 或 <base>.post.cmd.
---@param opts table 同 M.script
---@return string
function M.path(opts)
  return opts.base .. dialect(opts).ext
end

--- 用 tmp 覆盖 path. Windows 上 rename 不能覆盖已有文件, 失败时先删掉旧的再改名.
---@param tmp string
---@param path string
---@return boolean ok
---@return string? err
function M.replace(tmp, path)
  local ok, err = os.rename(tmp, path)
  if ok then
    return true
  end
  os.remove(path)
  ok, err = os.rename(tmp, path)
  if ok then
    return true
  end
  os.remove(tmp)
  return false, tostring(err)
end

--- 写出合成脚本 (先写临时文件再改名), 不运行.
---@param opts table 同 M.script
---@return string? path
---@return string? err
function M.write(opts)
  local path = M.path(opts)
  local tmp = path .. ".tmp"
  local file, err = io.open(tmp, "wb")
  if not file then
    return nil, tostring(err)
  end
  file:write(M.script(opts))
  file:close()
  local ok, replace_err = M.replace(tmp, path)
  if not ok then
    return nil, replace_err
  end
  return path
end

--- 写出局末脚本 (覆盖草稿) 并在后台运行.
--- launch: 后台启动脚本的函数 launch(path) -> ok, err. 不给时用 sh: perl 的 setsid 脱离游戏的进程组,
--- 终端里按 Ctrl-C 或关掉游戏都不会打断它. Windows 由调用方传入 (record/win_proc.lua).
---@param opts table 同 M.script, draft 被忽略
---@param launch (fun(path: string): boolean, string?)?
---@return boolean ok
---@return string? err
function M.spawn(opts, launch)
  local final = {}
  for k, v in pairs(opts) do
    final[k] = v
  end
  final.draft = false
  local path, err = M.write(final)
  if not path then
    return false, err
  end
  if launch then
    return launch(path)
  end
  local quoted = SH.quote(path)
  local detach = "if command -v perl >/dev/null 2>&1; then "
    .. "perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/sh " .. quoted .. " </dev/null >/dev/null 2>&1 & "
    .. "else nohup /bin/sh " .. quoted .. " </dev/null >/dev/null 2>&1 & fi"
  os.execute(detach)
  return true
end

return M
