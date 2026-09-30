-- 回放文件纯逻辑的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Format = dofile("mods/balatrobot/agent/replay/format.lua")

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
  check("讲解写进回放", Format.recorded("notify") and Format.recorded("continue"))
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
