-- 回放文件纯逻辑的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Format = dofile("mods/bbreplay/replay/format.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function card(key, modifier)
  return { key = key, modifier = modifier or {} }
end

local function state(hand, jokers, money)
  return {
    state = "SELECTING_HAND",
    ante_num = 1,
    round_num = 1,
    money = money or 4,
    cards = { cards = { card("H_2"), card("H_3") } },
    hand = { cards = hand },
    jokers = { cards = jokers or {} },
  }
end

do -- 摘要: 顺序和修饰都要区分, 否则下标错位或版本不同也比不出来
  local a = Format.digest(state({ card("S_A"), card("H_K") }))
  local b = Format.digest(state({ card("H_K"), card("S_A") }))
  check("相同状态摘要相同", a == Format.digest(state({ card("S_A"), card("H_K") })))
  check("手牌顺序不同摘要不同", a ~= b)
  local foil = Format.digest(state({ card("S_A", { edition = "FOIL" }), card("H_K") }))
  local sealed = Format.digest(state({ card("S_A", { seal = "RED" }), card("H_K") }))
  check("版本与蜡封区分", a ~= foil and foil ~= sealed and a ~= sealed)
  local diff = Format.diff(a, Format.digest(state({ card("S_A"), card("H_K") }, nil, 9)))
  check("diff 指出不同的项", diff == "money: 4 -> 9", tostring(diff))
  check("diff 相同时为 nil", Format.diff(a, a) == nil)
end

do -- original 节奏: 间隔以上一次实际执行的操作为参照, 跳过的步骤不改变参照点
  local action = { wall = 30 }
  check("间隔为到参照点的差", Format.original_gap(action, 12.5) == 17.5)
  check("负间隔按 0", Format.original_gap({ wall = 3 }, 5) == 0)
  check("原局失败的操作不重做", not Format.should_run({ ok = false }))
  check("原局没等到响应的操作仍执行", Format.should_run({}))
end

do -- 开局参数
  check("牌组 key 转枚举", Format.deck_enum("b_red") == "RED" and Format.deck_enum("b_abandoned") == "ABANDONED")
  check("非原版牌组不转", Format.deck_enum("b_mymod_deck") == nil)
  check("赌注转枚举", Format.stake_enum(1) == "WHITE" and Format.stake_enum(8) == "GOLD")
  check("开局与存档不写进回放", not Format.recorded("start") and not Format.recorded("save"))
  check("只读查询不写进回放", not Format.recorded("dynamics") and not Format.recorded("lookup"))
  check("讲解写进回放", Format.recorded("notify") and Format.recorded("continue"))
end

do -- 一局正在拆掉时取的摘要 (真机上输掉后点回主菜单) 不拿来比
  check("摘要: 状态未知的不比", not Format.usable_digest("state=UNKNOWN ante=nil deck=0"))
  check("摘要: 正常的照比", Format.usable_digest("state=GAME_OVER ante=1 deck=40"))
  check("摘要: 没有摘要不比", not Format.usable_digest(nil))
end

do -- 教程局: 开局前的设置里还有强制内容, 或者教程没完成
  check("教程: 未完成", Format.tutorial_settings({ tutorial_complete = false }))
  check("教程: 还有强制的商店牌", Format.tutorial_settings({ tutorial_complete = true, tutorial_progress = { forced_shop = { "j_joker" } } }))
  check("教程: 完成且没有强制内容", not Format.tutorial_settings({ tutorial_complete = true, tutorial_progress = {} }))
  check("教程: 旧文件按种子判断", Format.is_tutorial({ seed = "TUTORIAL", seeded = false }))
  check("教程: 人手动输入的同名种子不算", not Format.is_tutorial({ seed = "TUTORIAL", seeded = true }))
  check("教程: 有记录时以记录为准", not Format.is_tutorial({ seed = "TUTORIAL", seeded = false, tutorial = false }))
end

do -- 中止的按住时长: 触摸按 love.touch 的当前状态算 (主循环不分发 touchpressed), HUD 上的手指不算
  local clock, fingers, positions = 100, {}, {}
  local focused = true
  local saved_love = love
  love = {
    timer = { getTime = function() return clock end },
    touch = {
      getTouches = function() return fingers end,
      getPosition = function(id) return positions[id][1], positions[id][2] end,
    },
    mouse = { setVisible = function() end },
    window = { hasFocus = function() return focused end },
  }
  -- 假的输入门: 记下策略与观察者, HUD 占着 x >= 1000.
  local gate = { policies = {}, observers = {} }
  function gate.add_policy(id, fn) gate.policies[id] = fn end
  function gate.observe(id, fn) gate.observers[id] = fn end
  function gate.hud_hit(x) return type(x) == "number" and x >= 1000 end
  local InputLock = dofile("mods/bbreplay/replay/input_lock.lua")
  InputLock.init({ input = gate })
  check("没上锁时没有策略", gate.policies.replay() == nil)
  InputLock.install()
  local policy = gate.policies.replay()
  check("上锁后丢弃点击, 停放光标, 拦摇杆", policy and not policy.pass({ kind = "press" }) and policy.park and policy.block_axis)

  -- 只有手指按下, 没有任何 touchpressed 事件 (与 game/main.lua 的 love.run 一致).
  fingers, positions = { "f1" }, { f1 = { 10, 10 } }
  InputLock.abort_progress()
  clock = clock + 0.75
  local half = InputLock.abort_progress()
  clock = clock + 0.8
  local full = InputLock.abort_progress()
  fingers = {}
  local released = InputLock.abort_progress()
  check(
    "长按 1.5 秒中止不依赖 touchpressed",
    math.abs(half - 0.5) < 1e-9 and full == 1 and released == 0,
    string.format("half=%s full=%s released=%s", half, full, released)
  )

  fingers, positions = { "f2" }, { f2 = { 1200, 10 } }
  InputLock.abort_progress()
  clock = clock + 2
  check("按在 HUD 上的手指不算中止", InputLock.abort_progress() == 0)
  fingers = {}

  -- Esc 的按下由观察者看到 (事件本身被丢弃).
  gate.observers.replay({ kind = "key_press", key = "escape" }, "drop")
  clock = clock + 0.5
  local esc_half = InputLock.abort_progress()
  focused = false
  local unfocused = InputLock.abort_progress()
  focused = true
  check("按住 Esc 计时, 失焦时清零", math.abs(esc_half - 0.5) < 1e-9 and unfocused == 0, tostring(esc_half))

  gate.observers.replay({ kind = "pad_press", source = "gamepad", joystick = "js", button = "back" }, "drop")
  clock = clock + 1
  check("按住手柄 back 1 秒中止", InputLock.abort_progress() == 1)
  gate.observers.replay({ kind = "pad_release", source = "gamepad", joystick = "js", button = "back" }, "drop")
  check("松开后清零", InputLock.abort_progress() == 0)

  InputLock.release()
  check("解锁后没有策略", gate.policies.replay() == nil)
  love = saved_love
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
