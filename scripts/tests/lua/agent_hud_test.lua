-- 右上角 HUD 与输入阻挡的纯逻辑测试, 用 luajit 在仓库根目录运行: just test-agent
local Hud = dofile("mods/bbcore/ui/hud.lua")
Hud.init({ widgets = {} })

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

sendErrorMessage = function() end

do -- 点在框上
  local rect = { x = 10, y = 20, w = 30, h = 40 }
  check("框内算命中", Hud.point_in_rect(10, 20, rect) and Hud.point_in_rect(40, 60, rect))
  check("框外不算", not Hud.point_in_rect(9, 20, rect) and not Hud.point_in_rect(10, 61, rect))
end

do -- 挡住时只放行 HUD, Esc/F9, 移动光标
  local blocking = false
  Hud.bind("agent", function()
    return blocking and { buttons = { { label = "暂停" } }, blocking = true } or nil
  end)
  check("没开阻挡时放行点击", Hud.should_pass("mousepressed", 1, 1, 1))
  blocking = true
  check("开了阻挡时丢掉点击", not Hud.should_pass("mousepressed", 1, 1, 1))
  check("挡住时仍放行 Esc", Hud.should_pass("keypressed", "escape"))
  check("挡住时仍放行 F9", Hud.should_pass("keypressed", "f9"))
  check("挡住时仍放行移动光标", Hud.should_pass("mousemoved", 1, 1))
  check("挡住时丢掉滚轮", not Hud.should_pass("wheelmoved", 0, 1))
  blocking = false
  check("关掉阻挡后点击放行", Hud.should_pass("mousepressed", 1, 1, 1))
end

do -- 回放输入锁对 HUD 放行
  local passed = 0
  local saved_love, saved_hud = love, BB_HUD
  love = {
    timer = { getTime = function() return 0 end },
    mouse = { setVisible = function() end },
    mousepressed = function()
      passed = passed + 1
    end,
  }
  BB_HUD = {
    hit = function(x, y)
      return x == 12 and y == 8
    end,
  }
  local InputLock = dofile("mods/bbreplay/replay/input_lock.lua")
  InputLock.install()
  love.mousepressed(12, 8, 1)
  check("点在 HUD 上放行", passed == 1, tostring(passed))
  love.mousepressed(0, 0, 1)
  check("点在别处仍丢掉", passed == 1, tostring(passed))
  InputLock.release()
  love, BB_HUD = saved_love, saved_hud
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
