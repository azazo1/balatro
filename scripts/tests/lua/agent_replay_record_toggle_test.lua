-- 独立录制开关的关键链路, 文件系统和编码后端都留在内存中.
local failures = 0
local function check(name, condition)
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name)
  end
end

package.path = "mods/Steamodded/libs/json/?.lua;" .. package.path
local json = require("json")
local clock, files, directories, loads, captures, replaying, env
local hooks
os.getenv = function(name) return env[name] end
os.execute = function() return 1 end -- 不启动真实编码器
io.open = function(path, mode)
  assert(mode == "wb")
  return { write = function(_, text) files[path] = text end, close = function() end }
end
os.rename = function(src, dst)
  files[dst], files[src] = files[src], nil
  return true
end
sendInfoMessage, sendWarnMessage, sendErrorMessage = function() end, function() end, function() end

local function context(video, replay, overrides)
  clock, files, directories, loads, captures, replaying = 0, {}, {}, {}, 0, false
  env = overrides or {}
  hooks = {}
  love = {
    timer = { getTime = function() return clock end },
    filesystem = { getSaveDirectory = function() return "/virtual" end },
    graphics = {
      setCanvas = function() end,
      getPixelDimensions = function() return 1280, 720 end,
    },
  }
  G = {
    GAME = { pseudorandom = { seed = "TEST" }, stake = 1 },
    SETTINGS = {}, FUNCS = { exit_overlay_menu = function() end },
  }
  Game = { start_run = function() end, main_menu = function() end }
  BB_SETTINGS = { headless = false, render_on_api = false }
  SMODS = {
    NFS = {
      createDirectory = function(path) directories[path] = true; return true end,
      getInfo = function(path) return directories[path] or files[path] end,
    },
    load_file = function(path, id)
      assert(id == "bbreplay")
      loads[#loads + 1] = path
      if path == "record/timeline.lua" then
        return function()
          return { new = function()
            return {
              event = function(_, _, _, fields) return fields or {} end,
              set = function() end, set_duration = function() end,
              flush = function() return true end,
            }
          end }
        end
      end
      if path == "record/audio.lua" or path == "record/post.lua" then
        return function() return {} end
      end
      return assert(loadfile("mods/bbreplay/" .. path))
    end,
  }
  local activity = { on = function(kind, callback)
    hooks[kind] = hooks[kind] or {}
    table.insert(hooks[kind], callback)
  end }
  local Recorder = dofile("mods/bbreplay/record/recorder.lua")
  Recorder.init({ activity = activity, config_enabled = video })
  local Log = dofile("mods/bbreplay/replay/log.lua")
  Log.init({
    config_enabled = replay,
    activity = activity, recorder = Recorder,
    overlay = { kind = function() end },
    format = {
      VERSION = 1, comparable = function() return false end, recorded = function() return true end,
      deck_enum = function() return "RED" end, stake_enum = function() return "WHITE" end,
      tutorial_settings = function() return false end,
    },
    snapshot = { capture = function() captures = captures + 1; return { progress = "before" } end },
    replaying = function() return replaying end,
  })
  return Recorder, Log
end

local function replays()
  local out = {}
  for path, text in pairs(files) do
    if path:match("%.replay%.json$") then
      out[path] = json.decode(text)
    end
  end
  return out
end

for _, video in ipairs({ false, true }) do
  for _, replay in ipairs({ false, true }) do
    local Recorder, Log = context(video, replay)
    Game:start_run({})
    local session = Recorder.current()
    check("视频开关 " .. tostring(video) .. "/" .. tostring(replay), (session ~= nil) == video)
    Log.record_manual({ method = "select" })
    Game:main_menu()
    local path, data = next(replays())
    check("回放开关 " .. tostring(video) .. "/" .. tostring(replay), (data ~= nil) == replay)
    check("只在录回放时取快照", captures == (replay and 1 or 0))
    if replay then
      check("记录动作和菜单", #data.actions == 2 and data.snapshot.progress == "before")
      if video then
        check("视频与回放共用目录和起点", path == session.base .. ".replay.json"
          and data.source == session.stem and data.actions[1].wall == 0)
      else
        local codec_loaded = false
        for _, name in ipairs(loads) do
          if name == "record/audio.lua" or name == "record/timeline.lua" then codec_loaded = true end
        end
        check("只录回放不加载编码依赖", not codec_loaded)
      end
    end
  end
end

local Recorder, Log = context(true, true)
Game:start_run({})
Log.record_manual({ method = "select" })
Recorder.set_enabled(false, "test")
Log.record_manual({ method = "play" })
Game:main_menu()
local _, data = next(replays())
check("关闭视频后回放继续记录", Log.enabled and #data.actions == 3 and data.actions[2].method == "play")

Recorder, Log = context(true, true)
Game:start_run({})
Log.record_manual({ method = "select" })
Log.set_enabled(false, "test")
local _, stopped = next(replays())
Log.record_manual({ method = "play" })
Log.set_enabled(true, "test")
Log.record_manual({ method = "discard" })
Log.update()
check("关闭回放不关闭视频", Recorder.enabled and Recorder.current() ~= nil)
local _, unchanged = next(replays())
check("关闭时保存, 中途重开不写缺失的前半局", #unchanged.actions == 1 and stopped.result.reason == "disabled")
Game:start_run({})
check("重开后下一局正常录制", captures == 2)

Recorder, Log = context(false, true)
local start_hook = Game.start_run
Recorder.set_enabled(true, "test")
check("运行中开启视频不改变开局钩子顺序", Game.start_run == start_hook)
Game:start_run({})
local session = Recorder.current()
check("后开视频仍与回放同名", replays()[session.base .. ".replay.json"] ~= nil)
Game:main_menu()
Game:start_run({})
local next_session = Recorder.current()
check("同秒重开不覆盖旧局", session.base ~= next_session.base)

Recorder, Log = context(false, true)
replaying = true
Game:start_run({})
check("回放自己不录制文件也不取快照", next(replays()) == nil and captures == 0)

Recorder, Log = context(false, false, { BALATROBOT_RECORD_REPLAY = "on", BALATROBOT_RECORD_VIDEO = "off" })
check("回放环境开关不打开视频", Log.enabled and not Recorder.enabled)
Recorder, Log = context(true, true, { BALATROBOT_RECORD_REPLAY = "off", BALATROBOT_RECORD_VIDEO = "on" })
check("视频环境开关不打开回放", Recorder.enabled and not Log.enabled)

local saves = 0
SMODS.save_mod_config = function() saves = saves + 1 end
local Migrate = dofile("mods/bbreplay/migrate.lua")
for _, old in ipairs({ false, true }) do
  local mod = { config = { version = 1, record = old, record_video = false, record_replay = false } }
  Migrate.run(mod)
  check("旧开关迁移 " .. tostring(old), mod.config.record_video == old and mod.config.record_replay == old
    and mod.config.record == nil and mod.config.version == 2)
  mod.config.record_replay = not old
  local before = saves
  Migrate.run(mod)
  check("迁移幂等且保留独立设置", saves == before and mod.config.record_replay == not old)
end
SMODS.Mods = { balatrobot = { config = { record = true, record_keep = "keep" } } }
local mod = { config = { record_video = false, record_replay = false, record_keep = "skip" } }
Migrate.run(mod)
check("balatrobot 旧配置迁移两步", mod.config.record_video and mod.config.record_replay
  and mod.config.record_keep == "keep" and SMODS.Mods.balatrobot.config.record == nil)

-- 配置页按字段验证两个开关的回调, 不依赖显示文案.
local toggles, video_calls, replay_calls = {}, 0, 0
local function node(value) return value end
create_toggle = function(options)
  toggles[options.ref_value] = options
  return options
end
G.UIT, G.C = { ROOT = 1 }, { BLACK = {}, UI = { TEXT_INACTIVE = {} } }
local Settings = dofile("mods/bbreplay/ui/settings_tab.lua")
local settings_deps = {
  mod = mod,
  recorder = { status = "off", set_enabled = function() video_calls = video_calls + 1 end },
  replay_log = { status = "off", set_enabled = function() replay_calls = replay_calls + 1 end },
  replay = { status = "off" },
  widgets = { title = node, row = node, col = node, text = node, radio = node, live = node, localize_tree = node },
}
Settings.init(settings_deps)
Settings.build()
check("配置页独立绑定两个字段", toggles.record_video ~= nil and toggles.record_replay ~= nil)
toggles.record_video.callback(true)
check("视频回调只切换视频", video_calls == 1 and replay_calls == 0)
toggles.record_replay.callback(true)
check("回放回调只切换回放", video_calls == 1 and replay_calls == 1)
settings_deps.record_video_env, settings_deps.record_replay_env = "on", "off"
toggles = {}
Settings.build()
check("环境变量锁定各自的配置开关", next(toggles) == nil)

if failures > 0 then os.exit(1) end
print("独立录制开关全部通过")
