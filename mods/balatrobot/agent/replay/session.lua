--[[
游戏内回放的存档隔离与收尾.

命令行回放用临时存档 (Balatro-Replay) 隔离; 游戏内回放不能这么做, 因为运行中切换存档标识会和后台的
存档线程冲突 (存档线程按 setIdentity 定下的目录写). 改成拦截写入:

- 出口一: `G.SAVE_MANAGER.channel` 上的请求. 游戏把要写的东西 push 进这个通道, 存档线程 demand 出来
  再写盘. 回放期间把这个通道换成丢弃推送的桩, 线程就收不到新请求.
- 出口二: 主线程直接调用的 `compress_and_save` (game.lua, functions/misc_functions.lua, 以及 mod 自己的
  快照恢复). 回放期间换成丢弃调用的版本, 只有指名的临时存档文件放行.
- 两个出口都不碰录像输出: 录像, 时间轴和回放文件有自己的目录, 不走存档写入.

于是磁盘上的存档, 进度和设置在整个回放期间不变, 回放中途崩溃也一样.

开始前先等存档线程把已经排队的请求做完: 看通道里还有没有请求, 再看几个存档文件的修改时间有没有稳定下来.
结束后按设计从磁盘重新读回当前档位 (load_profile), 设置恢复成开始前记下的副本.
]]

local M = {}

local LOGGER = "BB.AGENT.REPLAY"

---@class BBReplaySessionDeps
---@field recorder table agent/record/recorder.lua, 提供 current
---@field toast table agent/toast.lua

local deps = {}
local active = false
local real_channel = nil
local real_compress_and_save = nil
local allowed_temp = nil -- 放行的临时存档文件名 (相对存档目录)
local temp_files = {} -- 需要删掉的临时文件
local dropped_channel = 0
local dropped_compress = 0
local settings_before = nil
local profile_before = nil
local snapshot_before = nil -- 回放开始前的内存状态 (解锁, 发现, profile, 设置)

local SETTING_KEYS = {
  "GAMESPEED",
  "screenshake",
  "reduced_motion",
  "colourblind_option",
  "SOUND",
  "GRAPHICS",
  "language",
  "ambient_sounds",
  "music_volume",
  "sound_volume",
}

---@param options BBReplaySessionDeps
function M.init(options)
  deps = options or {}
end

---@return boolean
function M.is_active()
  return active
end

---@return {dropped_channel: integer, dropped_compress: integer}
function M.stats()
  return { dropped_channel = dropped_channel, dropped_compress = dropped_compress }
end

--- 丢弃推送的通道桩. 存档线程从 love.thread 取真实的通道, 拿不到这里的桩, 所以只影响主线程的写入请求.
local function stub_channel()
  local stub = {}
  function stub.push()
    dropped_channel = dropped_channel + 1
    return false
  end
  function stub.pop()
    return nil
  end
  function stub.getCount()
    return 0
  end
  function stub.clear()
    return true
  end
  return stub
end

--- 回放期间顶替 compress_and_save 的函数: 只有指名的临时文件放行.
---@param file string
---@param data any
local function dropping_compress_and_save(file, data)
  if allowed_temp and file == allowed_temp then
    return real_compress_and_save(file, data)
  end
  dropped_compress = dropped_compress + 1
end

--- 安装写入拦截: 丢掉存档写入, 只放行 allowed_temp 指名的临时文件.
function M.install_guards()
  local manager = G and G.SAVE_MANAGER
  if manager and manager.channel and not real_channel then
    real_channel = manager.channel
    manager.channel = stub_channel()
  end
  if compress_and_save ~= dropping_compress_and_save then
    real_compress_and_save = compress_and_save
    compress_and_save = dropping_compress_and_save
  end
end

--- 卸载写入拦截, 把真实实现放回去.
function M.remove_guards()
  local manager = G and G.SAVE_MANAGER
  if manager and real_channel then
    manager.channel = real_channel
    real_channel = nil
  end
  if real_compress_and_save then
    compress_and_save = real_compress_and_save
  end
end
--- 放行一个临时存档文件 (读档开局的回放要把它交给 load). 结束时自动删掉.
---@param name string 相对存档目录的路径
function M.allow_temp(name)
  allowed_temp = name
  temp_files[#temp_files + 1] = name
end

--- 等存档线程把排队的请求做完.
--- - 通道里还有请求就继续等.
--- - 通道空了以后再看几个存档文件的修改时间: 线程可能正在写最后一个请求, 等它们稳定下来.
--- 超过 limit 秒就放弃等待, 记一行警告继续.
---@param paths string[] 相对存档目录的存档文件
---@param limit number?
---@return boolean drained
function M.drain(paths, limit)
  local channel = G and G.SAVE_MANAGER and G.SAVE_MANAGER.channel
  local started = love.timer.getTime()
  local last_change = started
  local stamps = {}
  limit = limit or 5
  paths = paths or {}
  while love.timer.getTime() - started < limit do
    local pending = channel and channel.getCount and channel:getCount() or 0
    local changed = false
    for _, path in ipairs(paths) do
      local info = love.filesystem.getInfo(path)
      local stamp = info and (info.modtime or 0) or 0
      if stamps[path] ~= stamp then
        stamps[path] = stamp
        changed = true
      end
    end
    local now = love.timer.getTime()
    if changed or pending > 0 then
      last_change = now
    elseif now - last_change > 0.4 then
      return true
    end
    love.timer.sleep(0.05)
  end
  sendWarnMessage("存档线程还在写, 没有等完就开始回放", LOGGER)
  return false
end

--- 记下开始前的设置与档位, 结束后恢复.
local function remember_settings()
  local settings = {}
  for _, key in ipairs(SETTING_KEYS) do
    settings[key] = G.SETTINGS[key]
  end
  settings_before = settings
  profile_before = G.SETTINGS.profile
end

---@return string[] warnings
function M.restore_settings()
  local warnings = {}
  if not settings_before then
    return warnings
  end
  for key, value in pairs(settings_before) do
    if G.SETTINGS[key] ~= value then
      warnings[#warnings + 1] = string.format("设置 %s 已恢复", key)
    end
    G.SETTINGS[key] = value
  end
  if profile_before and G.SETTINGS.profile ~= profile_before then
    G.SETTINGS.profile = profile_before
  end
  return warnings
end

--- 收尾: 删临时文件, 从磁盘读回当前档位的进度, 按开始前的快照恢复解锁与设置, 卸载写入拦截.
--- 恢复都在拦截还装着的时候做: 期间游戏标脏的保存请求会被丢掉, 之后 (拦截已卸载) 才会按恢复后的状态落盘.
---@return string[] warnings
function M.finish()
  local warnings = {}
  for _, name in ipairs(temp_files) do
    love.filesystem.remove(name)
  end
  temp_files = {}
  allowed_temp = nil
  if G and G.load_profile and G.SETTINGS then
    local ok, err = pcall(function()
      G:load_profile(G.SETTINGS.profile or 1)
    end)
    if not ok then
      warnings[#warnings + 1] = "读回进度失败: " .. tostring(err)
      sendWarnMessage("读回进度失败: " .. tostring(err), LOGGER)
    end
  end
  if snapshot_before and deps.snapshot then
    local ok, err = pcall(deps.snapshot.apply, snapshot_before, { write_notify = false })
    if not ok then
      warnings[#warnings + 1] = "恢复解锁进度失败: " .. tostring(err)
      sendWarnMessage("恢复解锁进度失败: " .. tostring(err), LOGGER)
    end
    snapshot_before = nil
  end
  for _, text in ipairs(M.restore_settings()) do
    warnings[#warnings + 1] = text
  end
  M.remove_guards()
  active = false
  sendInfoMessage(
    string.format(
      "回放结束, 已丢弃 %d 次存档请求与 %d 次存档写入",
      dropped_channel,
      dropped_compress
    ),
    LOGGER
  )
  return warnings
end

--- 开始一次游戏内回放: 等存档线程写完, 记下设置与内存状态, 装上写入拦截.
---@param paths string[] 需要等稳定下来的存档文件
---@return boolean ok
---@return string? reason
function M.begin(paths)
  if active then
    return false, "回放已经在进行"
  end
  dropped_channel, dropped_compress = 0, 0
  remember_settings()
  if deps.snapshot then
    local ok, captured = pcall(deps.snapshot.capture)
    if ok then
      snapshot_before = captured
    else
      sendWarnMessage("开始前没取到存档进度快照: " .. tostring(captured), LOGGER)
    end
  end
  M.drain(paths, 5)
  M.install_guards()
  active = true
  sendInfoMessage("回放期间丢弃存档写入, 磁盘上的存档不会被改动", LOGGER)
  return true
end

return M
