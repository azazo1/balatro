-- 录像开关运行时可用的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 起因: 设置页打开 "录制对局" 时崩过 (SMODS.load_file 在运行时必须显式给出 mod id, 否则报
-- "No ID was provided!"), 这里把 M.set_enabled 这条路径真正跑一遍.

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
Game = {}
BB_SETTINGS = { headless = false, render_on_api = false }

local logs = { info = {}, warn = {}, error = {}, debug = {} }
sendInfoMessage = function(msg) logs.info[#logs.info + 1] = msg end
sendWarnMessage = function(msg) logs.warn[#logs.warn + 1] = msg end
sendErrorMessage = function(msg) logs.error[#logs.error + 1] = msg end
sendDebugMessage = function(msg) logs.debug[#logs.debug + 1] = msg end

--- 记录每次加载的 (path, id), 并返回一个空模块.
local loads = {}
SMODS = {
  current_mod = nil, -- 运行中通常已经不是本 mod, 正是省 id 会失败的情形
  load_file = function(path, id)
    loads[#loads + 1] = { path = path, id = id }
    return function()
      return {}
    end
  end,
  NFS = { createDirectory = function() return true end },
}

local Recorder = dofile("mods/balatrobot/agent/record/recorder.lua")
Recorder.init({
  activity = { on = function() end },
  toast = { active = function() return false end, duration_for = function() return 2.5 end },
  mod_path = "mods/balatrobot/",
  config_enabled = false,
  config_keep = "skip",
})

check("默认不装载 (开关关着)", Recorder.enabled == false and Recorder.ready == false and #loads == 0)

local ok = Recorder.set_enabled(true, "settings")
check("运行时打开录像返回成功", ok == true, tostring(Recorder.status))
check("装载了四个录像模块", #loads == 4, tostring(#loads))
local missing = {}
for _, call in ipairs(loads) do
  if not call.id or call.id == "" then
    missing[#missing + 1] = call.path
  end
end
check("每次加载都带 mod id", #missing == 0, table.concat(missing, ", "))
check("加载的是本 mod", loads[1] and loads[1].id == "balatrobot", loads[1] and tostring(loads[1].id))
check("没有报错", #logs.error == 0, logs.error[1])
check("打开后状态可用", Recorder.ready == true)

-- 再关一次: 不应该重复装载, 也不应该报错.
local before = #loads
Recorder.set_enabled(false, "settings")
check("关闭后不再可用", Recorder.enabled == false)
check("关闭不重新装载", #loads == before, tostring(#loads - before))

-- 再打开一次复用已装载的模块
Recorder.set_enabled(true, "settings again")
check("再次打开复用模块", #loads == before and Recorder.enabled == true)

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("录像开关全部通过")
