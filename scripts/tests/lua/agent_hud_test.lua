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

do -- 窗口像素要加上 letterbox, 否则点在可见按钮上对不上
  local t = { x = 10, y = 2, w = 3, h = 4 }
  local no_pad = Hud.screen_rect(t, { x = 0, y = 0 })
  check("没有 letterbox 时就是房间坐标", no_pad.x == 10 and no_pad.y == 2 and no_pad.w == 3 and no_pad.h == 4)
  local pad = Hud.screen_rect(t, { x = 1.5, y = 0.5 })
  check("letterbox 加到像素上", pad.x == 11.5 and pad.y == 2.5 and pad.w == 3 and pad.h == 4)
  local offset = Hud.window_offset()
  check("没有 ROOM 时略缩进", offset.x < 0 and offset.y > 0)
end

do -- 认按钮看 func: 禁用或选中时 bb_button_state 会把 config.button 清空, 按钮不能因此消失
  check("禁用的按钮仍是按钮", Hud.is_button({ config = { func = "bb_button_state", button = nil } }))
  check("状态文字不是按钮", not Hud.is_button({ config = { func = "bb_hud_status" } }))
end

do -- HUD 按钮松开才点: 按下与松开落在同一颗上才触发, 拖出去取消
  local clicks = 0
  local node = {
    config = { func = "bb_button_state" },
    T = { x = 0, y = 0, w = 2, h = 1 },
    click = function()
      clicks = clicks + 1
    end,
  }
  -- button_at 遍历 view.box; 用一个装着这颗按钮的假框 (hud.update 建框要 UIBox, 这里直接塞).
  G = { ROOM = { T = { x = 0, y = 0 } }, TILESCALE = 1, TILESIZE = 10 }
  Hud._set_box({ T = { x = 0, y = 0, w = 2, h = 1 }, UIRoot = { children = { node } } })
  Hud.press({ kind = "press", x = 5, y = 5, button = 1 })
  check("按下时不点", clicks == 0)
  Hud.release({ kind = "release", x = 6, y = 5, button = 1 })
  check("松开在同一颗上才点", clicks == 1, tostring(clicks))
  Hud.press({ kind = "press", x = 5, y = 5, button = 1 })
  Hud.release({ kind = "release", x = 50, y = 5, button = 1 })
  check("拖出去松手不点", clicks == 1, tostring(clicks))
  Hud.press({ kind = "press", x = 5, y = 5, button = 2 })
  Hud.release({ kind = "release", x = 5, y = 5, button = 2 })
  check("右键不点", clicks == 1, tostring(clicks))
  Hud._set_box(nil)
  G = nil
end

do -- agent 锁操作: 何时生效, 放行哪些, F9 与手动操作检测
  local runner = { state = "running", on_state = {} }
  function runner.is_busy() return runner.state ~= "stopped" end
  function runner.is_active() return runner.state == "running" end
  local menu, hotkeys, manuals = false, 0, 0
  local gate = {}
  function gate.add_policy(_, fn) gate.policy = fn end
  function gate.observe(_, fn) gate.observer = fn end
  sendInfoMessage = function() end
  local Lock = dofile("mods/balatrobot/agent/input.lua")
  Lock.init({
    runner = runner,
    input = gate,
    menu_open = function() return menu end,
    hotkey = function() hotkeys = hotkeys + 1 end,
    manual = function() manuals = manuals + 1 end,
  })
  local policy = gate.policy()
  check("运行中默认锁着", policy ~= nil and policy.block_axis)
  check("锁着时丢掉点击", not policy.pass({ kind = "press" }))
  check("锁着时放行 Esc, F9, 移动, 手柄 start", policy.pass({ kind = "key_press", key = "escape" })
    and policy.pass({ kind = "key_press", key = "f9" })
    and policy.pass({ kind = "move" })
    and policy.pass({ kind = "pad_press", source = "gamepad", button = "start" }))
  check("锁着时丢掉手柄 a", not policy.pass({ kind = "pad_press", source = "gamepad", button = "a" }))
  menu = true
  check("开着菜单时不拦", gate.policy() == nil)
  menu = false
  Lock.toggle()
  check("解锁后不拦", gate.policy() == nil)

  gate.observer({ kind = "key_press", key = "f9" }, "game")
  gate.observer({ kind = "key_press", key = "f9" }, "drop")
  check("F9 只在交给游戏时触发", hotkeys == 1, tostring(hotkeys))

  gate.observer({ kind = "press", x = 1, y = 1, button = 1 }, "game")
  gate.observer({ kind = "press", x = 1, y = 1, button = 1 }, "hud")
  gate.observer({ kind = "pad_press", source = "gamepad", button = "start" }, "game")
  check("点了游戏算手动, 点 HUD 和手柄 start 不算", manuals == 1, tostring(manuals))
  menu = true
  gate.observer({ kind = "press", x = 1, y = 1, button = 1 }, "game")
  menu = false
  runner.state = "paused"
  gate.observer({ kind = "press", x = 1, y = 1, button = 1 }, "game")
  check("菜单里或暂停时的点击不算", manuals == 1, tostring(manuals))

  runner.on_state[1]("running", "stopped")
  check("重新开始时锁上", Lock.locked())
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
