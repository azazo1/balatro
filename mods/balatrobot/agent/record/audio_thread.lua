--[[
录音线程: 按游戏发给声音线程的同一组指令, 离线混出一份 PCM (s16le, 44100Hz, 双声道).

LÖVE 的 OpenAL 输出没有办法直接截取, 系统录音又要授权和虚拟声卡. 游戏的全部声音都经
G.SOUND_MANAGER.channel 发给 engine/sound_manager.lua, 这里收到同样的指令 (带时间戳), 用同样的
规则算音量与音调, 自己解码 resources/sounds 里的 ogg 混音. 与实际听到的基本一致, 差别:
- 不乘总音量 (Options 里的 Master), 静音玩时录像仍有声音; 音乐, 音效各自的音量照常生效.
- smods 注册的自定义音效没有数据, 跳过.

参数: messages (Channel), status (Channel), path (输出文件).
messages 元素: {t = 秒, request = 原指令}, {t = 秒} (只推进时间), "stop".
]]

local messages, status, path = ...

require("love.sound")
require("love.filesystem")
local ffi = require("ffi")

local RATE = 44100
local BLOCK = 1024
local GAIN = 0.8 -- 多个音效叠加时留一点余量
local SPLASH_STATE = 13 -- G.STATES.SPLASH
local STREAM_BUFFER = 16384 -- 流式解码每块的采样数

local out = io.open(path, "wb")
if not out then
  status:push({ kind = "error", message = "cannot open " .. tostring(path) })
  return
end

local mix = ffi.new("float[?]", BLOCK * 2)
local pcm = ffi.new("int16_t[?]", BLOCK * 2)
local rendered = 0 -- 已写出的采样帧数

-- ==========================================================================
-- 声源
-- ==========================================================================

local static_cache = {} -- sound_code -> {data, ptr, frames, channels, rate}

local function is_stream(code)
  return code:find("music") or code:find("ambient")
end

local function load_static(code)
  local cached = static_cache[code]
  if cached ~= nil then
    return cached or nil
  end
  local ok, data = pcall(love.sound.newSoundData, "resources/sounds/" .. code .. ".ogg")
  if not ok or data:getBitDepth() ~= 16 then
    static_cache[code] = false
    return nil
  end
  cached = {
    data = data,
    ptr = ffi.cast("int16_t*", data:getFFIPointer()),
    frames = data:getSampleCount(),
    channels = data:getChannelCount(),
    rate = data:getSampleRate(),
  }
  static_cache[code] = cached
  return cached
end

local function file_exists(code)
  return love.filesystem.getInfo("resources/sounds/" .. code .. ".ogg") ~= nil
end

--- 让 voice 从头开始播放. 返回 false 表示没有这个声音 (例如 smods 自定义音效).
local function rewind(voice)
  voice.pos = 0
  voice.playing = false
  if voice.stream then
    if voice.decoder then
      voice.decoder:release()
    end
    local ok, decoder = pcall(love.sound.newDecoder, "resources/sounds/" .. voice.code .. ".ogg", STREAM_BUFFER)
    if not ok or decoder:getBitDepth() ~= 16 then
      voice.decoder = nil
      return false
    end
    voice.decoder = decoder
    voice.channels = decoder:getChannelCount()
    voice.rate = decoder:getSampleRate()
    local chunk = decoder:decode()
    if not chunk then
      return false
    end
    if voice.chunk then
      voice.chunk:release()
    end
    voice.chunk = chunk
    voice.ptr = ffi.cast("int16_t*", chunk:getFFIPointer())
    voice.frames = chunk:getSampleCount()
  else
    local source = load_static(voice.code)
    if not source then
      return false
    end
    voice.ptr, voice.frames, voice.channels, voice.rate = source.ptr, source.frames, source.channels, source.rate
  end
  voice.playing = true
  return true
end

--- 流式声源读完当前块时取下一块, 没有了就停止.
local function next_chunk(voice)
  if not voice.decoder then
    voice.playing = false
    return false
  end
  local chunk = voice.decoder:decode()
  if not chunk then
    voice.playing = false
    return false
  end
  if voice.chunk then
    voice.chunk:release()
  end
  voice.chunk = chunk
  voice.ptr = ffi.cast("int16_t*", chunk:getFFIPointer())
  voice.frames = chunk:getSampleCount()
  return true
end

local function release(voice)
  voice.playing = false
  if voice.decoder then
    voice.decoder:release()
    voice.decoder = nil
  end
  if voice.chunk then
    voice.chunk:release()
    voice.chunk = nil
  end
end

-- ==========================================================================
-- 混音
-- ==========================================================================

--- 把 voice 的 n 帧叠加进 mix. 音量在块内线性过渡, 避免跳变的咔哒声.
local function render_voice(voice, n)
  local g0, g1 = voice.gain, voice.target
  voice.gain = g1
  if g0 <= 0 and g1 <= 0 then
    -- 静音也要推进位置: 各段音乐同时播放, 靠音量切换, 位置必须保持同步.
    local step = voice.pitch * voice.rate / RATE
    local pos = voice.pos + step * n
    while voice.playing and pos >= voice.frames do
      pos = pos - voice.frames
      if not next_chunk(voice) then
        return
      end
    end
    voice.pos = pos
    return
  end
  local step = voice.pitch * voice.rate / RATE
  local pos = voice.pos
  local stereo = voice.channels == 2
  for i = 0, n - 1 do
    if pos >= voice.frames then
      pos = pos - voice.frames
      if not next_chunk(voice) then
        voice.pos = 0
        return
      end
    end
    local p = voice.ptr
    local idx = math.floor(pos)
    local frac = pos - idx
    local nxt = idx + 1 < voice.frames and idx + 1 or idx
    local g = (g0 + (g1 - g0) * (i / n)) / 32768
    if stereo then
      local l = p[idx * 2] + (p[nxt * 2] - p[idx * 2]) * frac
      local r = p[idx * 2 + 1] + (p[nxt * 2 + 1] - p[idx * 2 + 1]) * frac
      mix[i * 2] = mix[i * 2] + l * g
      mix[i * 2 + 1] = mix[i * 2 + 1] + r * g
    else
      local v = (p[idx] + (p[nxt] - p[idx]) * frac) * g
      mix[i * 2] = mix[i * 2] + v
      mix[i * 2 + 1] = mix[i * 2 + 1] + v
    end
    pos = pos + step
  end
  voice.pos = pos
end

-- 与 sound_manager.lua 的 SOURCES 相同: sound_code -> voice 列表
local SOURCES = {}
for _, filename in ipairs(love.filesystem.getDirectoryItems("resources/sounds")) do
  if filename:sub(-4) == ".ogg" then
    SOURCES[filename:sub(1, -5)] = {}
  end
end

local function render_block(n)
  ffi.fill(mix, n * 2 * ffi.sizeof("float"))
  for _, list in pairs(SOURCES) do
    for _, voice in ipairs(list) do
      if voice.playing then
        render_voice(voice, n)
      end
    end
  end
  for i = 0, n * 2 - 1 do
    local v = mix[i] * GAIN
    if v > 1 then
      v = 1
    elseif v < -1 then
      v = -1
    end
    pcm[i] = v * 32767
  end
  out:write(ffi.string(pcm, n * 2 * 2))
end

--- 混音到时间 t (秒).
local function render_to(t)
  local target = math.floor(t * RATE)
  while rendered < target do
    local n = math.min(BLOCK, target - rendered)
    render_block(n)
    rendered = rendered + n
  end
end

-- ==========================================================================
-- 与 engine/sound_manager.lua (含 smods 补丁) 相同的规则
-- ==========================================================================

local current_track = nil

--- 与 SET_SFX 相同, 不乘总音量.
local function set_sfx(voice, args)
  local settings = args.sound_settings or {}
  if voice.code:find("music") then
    local dt = args.dt or 0
    if voice.code == args.desired_track then
      voice.current_volume = voice.current_volume or 1
      voice.current_volume = 1 * (dt * 3) + (1 - (dt * 3)) * voice.current_volume
    else
      voice.current_volume = voice.current_volume or 0
      voice.current_volume = 0 * (dt * 3) + (1 - (dt * 3)) * voice.current_volume
    end
    voice.target = voice.current_volume * voice.original_volume * ((settings.music_volume or 100) / 100)
    voice.pitch = voice.original_pitch * (args.pitch_mod or 1)
  else
    voice.pitch = voice.original_pitch
    local vol = voice.original_volume * ((settings.game_sounds_volume or 100) / 100)
    if voice.created_on_state == SPLASH_STATE then
      vol = vol * (args.splash_vol or 1)
    end
    if vol <= 0 then
      voice.playing = false
    else
      voice.target = vol
    end
  end
end

--- 与 PLAY_SOUND 相同.
local function play_sound(args)
  local code = args.sound_code
  if not code or not file_exists(code) then
    return nil
  end
  SOURCES[code] = SOURCES[code] or {}
  local voice
  for _, v in ipairs(SOURCES[code]) do
    if not v.playing then
      voice = v
      break
    end
  end
  if not voice then
    voice = { code = code, stream = is_stream(code) and true or false, gain = 0, target = 0 }
    table.insert(SOURCES[code], voice)
  end
  if not rewind(voice) then
    return nil
  end
  voice.original_pitch = args.per or 1
  voice.original_volume = args.vol or 1
  voice.created_on_state = args.state
  set_sfx(voice, args)
  voice.gain = voice.target -- 新声音直接以目标音量开始
  return voice
end

local function restart_music(args)
  for code, list in pairs(SOURCES) do
    if code:find("music") then
      for _, voice in ipairs(list) do
        release(voice)
      end
      SOURCES[code] = {}
      args.per = 0.7
      args.vol = 0.6
      args.sound_code = code
      play_sound(args)
    end
  end
end

--- 与 MODULATE 相同 (smods 补丁后的版本).
local function modulate(args)
  if args.desired_track ~= "" then
    local first = (SOURCES[current_track or ""] or {})[1]
    if not first or not first.playing then
      restart_music(args)
    end
  end
  for _, list in pairs(SOURCES) do
    local i = 1
    while i <= #list do
      if not list[i].playing then
        release(list[i])
        table.remove(list, i)
      else
        i = i + 1
      end
    end
    current_track = args.desired_track
    for _, voice in ipairs(list) do
      if voice.playing and voice.original_volume then
        set_sfx(voice, args)
      end
    end
  end
end

--- 与 AMBIENT 相同, 开始条件不乘总音量.
local function ambient(args)
  local settings = args.sound_settings or {}
  for code, list in pairs(SOURCES) do
    local control = args.ambient_control[code]
    if control then
      local start = control.vol * ((settings.game_sounds_volume or 100) / 100) > 0
      for _, voice in ipairs(list) do
        if voice.playing and voice.original_volume then
          voice.original_volume = control.vol
          set_sfx(voice, args)
          start = false
        end
      end
      if start then
        args.sound_code = code
        args.vol = control.vol
        args.per = control.per
        play_sound(args)
      end
    end
  end
end

local function handle(request)
  local kind = request.type
  if kind == "sound" then
    play_sound(request)
  elseif kind == "stop" then
    for _, list in pairs(SOURCES) do
      for _, voice in ipairs(list) do
        voice.playing = false
      end
    end
  elseif kind == "modulate" then
    modulate(request)
    if request.ambient_control then
      ambient(request)
    end
  elseif kind == "restart_music" then
    restart_music(request)
  elseif kind == "reset_states" then
    for _, list in pairs(SOURCES) do
      for _, voice in ipairs(list) do
        voice.created_on_state = request.state
      end
    end
  end
end

-- ==========================================================================
-- 主循环
-- ==========================================================================

local broken = nil
while true do
  local msg = messages:demand()
  if msg == "stop" then
    break
  end
  if not broken and type(msg) == "table" then
    local ok, err = pcall(function()
      render_to(msg.t or 0)
      if msg.request then
        handle(msg.request)
      end
    end)
    if not ok then
      broken = tostring(err)
      status:push({ kind = "error", message = "audio mixer failed: " .. broken })
    end
  end
end

out:close()
status:push({ kind = "done", seconds = rendered / RATE, error = broken })
