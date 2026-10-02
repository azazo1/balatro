-- bbcore 输入门的纯逻辑测试, 用 luajit 在仓库根目录运行: just test-agent
sendInfoMessage = function() end
sendDebugMessage = function() end
sendErrorMessage = function() end

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local Events = dofile("mods/bbcore/runtime/input/events.lua")
local Gate = dofile("mods/bbcore/runtime/input/gate.lua")
Gate.init({ events = Events })

-- 假的 LÖVE: 原版回调只记下收到的事件.
local got = {}
local mx, my = 500, 300
local fake = { mouse = {} }
for _, name in ipairs(Events.NAMES) do
  fake[name] = function(a, b)
    got[#got + 1] = { name = name, a = a, b = b }
  end
end
fake.mouse.getPosition = function()
  return mx, my
end

-- 假的控制器: 记下轴按键的松开, update_axis 被调用的次数.
local axis_calls, released = 0, {}
local Controller = {
  update_axis = function()
    axis_calls = axis_calls + 1
    return "button"
  end,
  button_release = function(_, button)
    released[#released + 1] = button
  end,
}
local controller = setmetatable({
  axis_buttons = { l_trig = { previous = "", current = "triggerleft" }, r_trig = { previous = "", current = "" } },
}, { __index = Controller })

Gate.install({ love = fake, controller_class = Controller })

-- HUD 占着 x >= 1000 的区域.
local hud_events = {}
Gate.set_hud({
  hit = function(x)
    return x >= 1000
  end,
  press = function(ev)
    hud_events[#hud_events + 1] = "press"
  end,
  release = function(ev)
    hud_events[#hud_events + 1] = "release"
  end,
})

local policy = nil
Gate.add_policy("test", function()
  return policy
end)
local seen = {}
Gate.observe("test", function(ev, outcome)
  seen[#seen + 1] = ev.kind .. "=" .. outcome
end)

local function reset()
  got, hud_events, seen = {}, {}, {}
end

---@return string[]
local function names()
  local out = {}
  for i, e in ipairs(got) do
    out[i] = e.name
  end
  return table.concat(out, ",")
end

do -- 没有策略时全部交给游戏, 点在 HUD 上的除外
  reset()
  fake.mousepressed(10, 10, 1)
  fake.mousereleased(10, 10, 1)
  fake.keypressed("a", "a", false)
  check("没有策略时交给游戏", names() == "mousepressed,mousereleased,keypressed", names())
  reset()
  fake.mousepressed(1200, 10, 1)
  fake.mousereleased(1200, 10, 1)
  check("点在 HUD 上不交给游戏", #got == 0 and table.concat(hud_events, ",") == "press,release", names())
  check("观察者看到去向", seen[1] == "press=hud" and seen[2] == "release=hud", table.concat(seen, ","))
end

do -- 策略: 丢弃大部分, 按 pass 放行
  reset()
  policy = {
    pass = function(ev)
      return ev.kind == "move" or (ev.kind == "key_press" or ev.kind == "key_release") and ev.key == "escape"
    end,
  }
  fake.mousepressed(10, 10, 1)
  fake.mousereleased(10, 10, 1)
  fake.wheelmoved(0, 1)
  fake.keypressed("escape", "escape", false)
  fake.keyreleased("escape", "escape")
  fake.mousemoved(20, 20, 1, 1, false)
  check("策略放行 Esc 与移动, 其余丢弃", names() == "keypressed,keyreleased,mousemoved", names())
  check("被丢弃的观察者也看得到", seen[1] == "press=drop", table.concat(seen, ","))
  reset()
  fake.mousepressed(1200, 10, 1)
  fake.mousereleased(1200, 10, 1)
  check("锁着时 HUD 仍能点", #got == 0 and #hud_events == 2)
  policy = nil
end

do -- 按下与松开成对: 松开跟着按下走, 不看松开那一刻的落点和策略
  reset()
  fake.mousepressed(10, 10, 1)
  fake.mousereleased(1200, 10, 1) -- 拖到 HUD 上松手
  check("在牌上按下, 拖到 HUD 上松手, 游戏收到松开", names() == "mousepressed,mousereleased" and #hud_events == 0, names())
  reset()
  fake.mousepressed(10, 10, 1)
  policy = { pass = function() return false end }
  fake.mousereleased(10, 10, 1)
  check("按住期间上锁, 游戏仍收到松开", names() == "mousepressed,mousereleased", names())
  reset()
  fake.keypressed("a", "a", false)
  policy = nil
  fake.keyreleased("a", "a")
  check("锁着时按下被丢, 解锁后松开也丢 (游戏没见过这次按下)", #got == 0, names())
  reset()
  fake.mousepressed(1200, 10, 1)
  fake.mousereleased(10, 10, 1)
  check("在 HUD 上按下, 拖出去松手, 松开仍归 HUD", #got == 0 and table.concat(hud_events, ",") == "press,release")
end

do -- 停放光标: 游戏读到左上角, 光标在 HUD 上时仍是真实位置
  policy = { pass = function() return false end, park = true }
  mx, my = 500, 300
  local x, y = fake.mouse.getPosition()
  check("停放时游戏读到左上角", x == Gate.PARK_X and y == Gate.PARK_Y, tostring(x) .. "," .. tostring(y))
  local rx, ry = Gate.real_position()
  check("真实位置不经停放", rx == 500 and ry == 300)
  mx = 1200
  x = fake.mouse.getPosition()
  check("光标在 HUD 上时回报真实位置", x == 1200)
  check("getX 也经停放", (function()
    mx = 500
    return fake.mouse.getX() == Gate.PARK_X
  end)())
  policy = nil
  check("没有策略时不停放", fake.mouse.getX() == 500)
end

do -- 摇杆: 策略拦摇杆时不轮询, 按住的扳机先松开
  axis_calls, released = 0, {}
  policy = { block_axis = true }
  local result = controller:update_axis(0.016)
  check("拦摇杆时不轮询", axis_calls == 0 and result == nil)
  check("按住的扳机被松开", released[1] == "triggerleft" and controller.axis_buttons.l_trig.current == "", tostring(released[1]))
  controller:update_axis(0.016)
  check("只松开一次", #released == 1, tostring(#released))
  policy = nil
  controller:update_axis(0.016)
  check("不拦时照常轮询", axis_calls == 1)
end

do -- 归一化: 触摸以 mousepressed(istouch) 进来, 手柄键用原始键名
  local ev = Events.classify("mousepressed", 1, 2, 1, true)
  check("触摸的按下", ev.kind == "press" and ev.touch == true and ev.button == 1)
  local pad = Events.classify("gamepadpressed", "js", "start")
  check("手柄键", pad.kind == "pad_press" and pad.button == "start" and pad.source == "gamepad")
  check("同一手柄同一键成对", Events.capture_key(pad) == Events.capture_key(Events.classify("gamepadreleased", "js", "start")))
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
