-- 录像开关运行时可用的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 录像可能在运行中才装载 (设置页打开开关), 此时 SMODS.load_file 必须显式给出 mod id, 否则报
-- "No ID was provided!". 这里把 M.set_enabled 这条路径真正跑一遍.

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

package.preload.json = function() -- 时间线只在 flush 时用到, 测试不写文件
  return { encode = function() return "{}" end }
end

-- 录制器在模块加载时会取 love.graphics.setCanvas, 所以这几个全局要在 dofile 之前就位.
love = {
  graphics = { setCanvas = function() end, getDimensions = function() return 1280, 720 end },
  filesystem = { getSaveDirectory = function() return "/tmp/bb-record-test" end },
  timer = { getTime = function() return os.clock() end },
}
Game = {
  start_run = function() end,
  main_menu = function() end,
}
BB_SETTINGS = { headless = false, render_on_api = false }

local logs = { info = {}, warn = {}, error = {}, debug = {} }
sendInfoMessage = function(msg) logs.info[#logs.info + 1] = msg end
sendWarnMessage = function(msg) logs.warn[#logs.warn + 1] = msg end
sendErrorMessage = function(msg) logs.error[#logs.error + 1] = msg end
sendDebugMessage = function(msg) logs.debug[#logs.debug + 1] = msg end

--- 记录每次加载的 (path, id), 并返回一个空模块. quality.lua 是纯逻辑, 装载时就要用, 加载真的.
local loads = {}
SMODS = {
  current_mod = nil, -- 运行中通常已经不是本 mod, 正是省 id 会失败的情形
  load_file = function(path, id)
    loads[#loads + 1] = { path = path, id = id }
    if path == "record/quality.lua" then
      return function()
        return dofile("mods/bbreplay/record/quality.lua")
      end
    end
    return function()
      return {}
    end
  end,
  NFS = { createDirectory = function() return true end },
}

local Recorder = dofile("mods/bbreplay/record/recorder.lua")
Recorder.init({
  activity = { on = function() end },
  toast = { active = function() return false end, duration_for = function() return 2.5 end },
  animating = function() return false end,
  mod_path = "mods/bbreplay/",
  config_enabled = false,
  config_keep = "skip",
})

check("开关关着时不装载", Recorder.enabled == false and #loads == 0)

-- 游戏内回放的顺序: 录像还没初始化时先设前缀再打开, 初始化不能把前缀冲掉
Recorder.set_prefix("replay-")
local ok = Recorder.set_enabled(true, "settings")
check("运行时打开录像", ok == true and Recorder.enabled == true and #logs.error == 0, tostring(logs.error[1]))
check("初始化保留先设的前缀", Recorder.get_prefix() == "replay-", Recorder.get_prefix())
local wrong = {}
for _, call in ipairs(loads) do
  if call.id ~= "bbreplay" then
    wrong[#wrong + 1] = call.path
  end
end
check("每次加载都带本 mod 的 id", #loads > 0 and #wrong == 0, table.concat(wrong, ", "))

-- 关掉再打开: 复用已装载的模块, 不重复装钩子
local before = #loads
Recorder.set_enabled(false, "settings")
check("关闭", Recorder.enabled == false)
-- 钩子还在: 游戏内回放选 "不录" 就是这条路径, 开局不能再写出视频.
local run_ok, run_err = pcall(Game.start_run, Game, {})
check(
  "关闭后开局不录像",
  run_ok == true and Recorder.current() == nil and Recorder.enabled == false,
  tostring(run_err)
)
Recorder.set_enabled(true, "settings again")
check("再次打开复用模块", #loads == before and Recorder.enabled == true, tostring(#loads - before))

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("录像开关全部通过")
