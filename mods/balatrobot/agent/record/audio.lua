--[[
录音 (主线程侧): 把发给声音线程的指令同时转给录音线程, 由它混出与画面同步的 PCM.
见 record/audio_thread.lua. 时间戳都是相对本局开始的墙钟秒数, 与视频帧同一个起点.
]]

local M = {}

local target = nil -- 正在录音的会话: {thread, messages, status, started}
local installed = false

--- 把 G.SOUND_MANAGER.channel 换成转发代理. 游戏只调用它的 push, 其余方法原样转交.
---@return boolean
local function install_tap()
  if installed then
    return true
  end
  local manager = G.SOUND_MANAGER
  if not (G.F_SOUND_THREAD and manager and manager.channel) then
    return false
  end
  local real = manager.channel
  local proxy = setmetatable({}, {
    __index = function(_, key)
      local value = real[key]
      if type(value) == "function" then
        return function(_, ...)
          return value(real, ...)
        end
      end
      return value
    end,
  })
  function proxy:push(request) ---@diagnostic disable-line: duplicate-set-field
    local r = real:push(request)
    local t = target
    if t and type(request) == "table" then
      t.messages:push({ t = love.timer.getTime() - t.started, request = request })
    end
    return r
  end
  manager.channel = proxy
  installed = true
  return true
end

---@param mod_path string
---@param path string PCM 输出路径
---@param started number 本局开始的 love.timer 时间
---@return table? handle
---@return string? err
function M.start(mod_path, path, started)
  if not install_tap() then
    return nil, "sound thread not available"
  end
  local source = SMODS.NFS.read(mod_path .. "agent/record/audio_thread.lua")
  local thread = love.thread.newThread(love.filesystem.newFileData(source, "bb_audio_thread.lua"))
  local messages = love.thread.newChannel()
  local status = love.thread.newChannel()
  thread:start(messages, status, path)
  target = { thread = thread, messages = messages, status = status, started = started, path = path }
  -- 本局开始前已在播放的音乐由下一次 modulate 重新开始, 这里不用补.
  return target
end

--- 每帧推进时间, 没有新声音时也按时写出静音.
function M.tick()
  local t = target
  if t then
    t.messages:push({ t = love.timer.getTime() - t.started })
  end
end

--- 结束录音, 时长写到 seconds 为止 (与视频等长).
---@param handle table
---@param seconds number
function M.stop(handle, seconds)
  if target == handle then
    target = nil
  end
  handle.messages:push({ t = seconds })
  handle.messages:push("stop")
end

return M
