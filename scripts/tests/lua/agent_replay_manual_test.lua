-- 手动操作换算的纯逻辑单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Manual = dofile("mods/balatrobot/agent/replay/manual.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function join(list)
  local out = {}
  for i, v in ipairs(list or {}) do
    out[i] = tostring(v)
  end
  return table.concat(out, ",")
end

local a, b, c, d = { id = "a" }, { id = "b" }, { id = "c" }, { id = "d" }

do -- 选中的牌按在手里的位置升序, 与点选的先后无关 (play 接口按下标依次点选)
  local indices = Manual.highlighted_indices({ a, b, c, d }, { d, b })
  check("选中: 升序下标", join(indices) == "1,3", join(indices))
  check("选中: 有牌不在手里时放弃", Manual.highlighted_indices({ a, b }, { c }) == nil)
end

do -- 排列: 与 rearrange 接口同义, 第 i 个是新位置上的牌原来的下标
  local order = Manual.permutation({ a, b, c }, { c, a, b })
  check("排列: 新位置的原下标", join(order) == "2,0,1", join(order))
  check("排列: 没变时不记", Manual.permutation({ a, b }, { a, b }) == nil)
  check("排列: 牌数变了不算排序", Manual.permutation({ a, b }, { a }) == nil)
  check("排列: 换了牌不算排序", Manual.permutation({ a, b }, { a, c }) == nil)

  local applied = Manual.apply_order({ a, b, c }, order)
  check("重排: 照排列还原", applied and applied[1] == c and applied[2] == a and applied[3] == b)
  check("重排: 下标重复时拒绝", Manual.apply_order({ a, b }, { 0, 0 }) == nil)
  check("重排: 长度不符时拒绝", Manual.apply_order({ a, b }, { 0 }) == nil)
end

do -- 拖动检测: 只在拖动结束的那一帧比较, 平时的顺序变化 (发牌后排序, 排序按钮) 不记
  local st = {}
  local hand = { a, b, c }
  Manual.track({ hand = hand }, false, st)
  local changes = Manual.track({ hand = { b, a, c } }, false, st)
  check("拖动检测: 没拖动时的变化不记", #changes == 0)

  Manual.track({ hand = { b, a, c } }, true, st)
  changes = Manual.track({ hand = { a, c, b } }, false, st)
  check("拖动检测: 拖动结束时记下顺序变化", #changes == 1 and changes[1].area == "hand", tostring(#changes))
  check("拖动检测: 相对拖动前的顺序", changes[1] and join(changes[1].order) == "1,2,0", changes[1] and join(changes[1].order))

  Manual.track({ jokers = { a, b } }, true, st)
  changes = Manual.track({ jokers = { a } }, false, st)
  check("拖动检测: 拖走卖掉不算排序", #changes == 0)
end

do -- 按钮函数的钩子: 用桩代替游戏, 装上钩子后模拟人点按钮
  local function area(cards)
    local a = { cards = cards, highlighted = {} }
    for _, c in ipairs(cards) do
      c.area = a
    end
    return a
  end
  local h1, h2, h3 = { id = "h1" }, { id = "h2" }, { id = "h3" }
  local j1, j2 = { id = "j1" }, { id = "j2" }
  local shop1, voucher1, booster1, booster2, cons1 = {}, {}, {}, {}, {}
  G = {
    hand = area({ h1, h2, h3 }),
    jokers = area({ j1, j2 }),
    consumeables = area({ cons1 }),
    shop_jokers = area({ shop1 }),
    shop_vouchers = area({ voucher1 }),
    shop_booster = area({ booster1, booster2 }),
  }
  local calls = {}
  G.FUNCS = {}
  for _, name in ipairs({
    "play_cards_from_highlighted", "discard_cards_from_highlighted", "select_blind", "skip_blind",
    "reroll_shop", "cash_out", "toggle_shop", "use_card", "sell_card", "skip_booster", "reroll_boss",
    "sort_hand_suit", "sort_hand_value",
  }) do
    G.FUNCS[name] = function(e)
      calls[#calls + 1] = { name = name, e = e }
    end
  end
  -- 买了直接用: 原函数在里面再调 use_card (游戏里是在事件中, 此时卡已离开商店)
  G.FUNCS.buy_from_shop = function(e)
    calls[#calls + 1] = { name = "buy_from_shop", e = e }
    G.FUNCS.use_card(e)
  end
  -- 与 game/engine/ui.lua 一样: 点按钮就是调用 config.button 指向的函数
  UIElement = {
    click = function(self)
      G.FUNCS[self.config.button](self)
    end,
  }
  sendWarnMessage = function() end

  local recorded = {}
  local M2 = dofile("mods/balatrobot/agent/replay/manual.lua")
  M2.install({
    record = function(fields)
      recorded[#recorded + 1] = fields
    end,
  })
  local function last()
    return recorded[#recorded] or {}
  end
  --- 人点一个按钮
  local function click(button, ref, id)
    UIElement.click({ config = { button = button, ref_table = ref, id = id } })
  end

  G.hand.highlighted = { h3, h1 }
  click("play_cards_from_highlighted")
  check("钩子: 出牌记选中的下标", last().method == "play" and join(last().params.cards) == "0,2", join(last().params and last().params.cards))
  check("钩子: 原函数照常执行", calls[#calls].name == "play_cards_from_highlighted")

  local before = #recorded
  G.FUNCS.discard_cards_from_highlighted(nil, true)
  G.FUNCS.select_blind({})
  check("钩子: 不经过点击的调用不记 (接口, The Hook 弃牌)", #recorded == before)
  check("钩子: 不经过点击时原函数照常执行", calls[#calls].name == "select_blind")

  click("use_card", booster2)
  check("钩子: 买卡包照接口回放", last().method == "buy" and last().params.pack == 1)
  click("use_card", voucher1)
  check("钩子: 买优惠券照接口回放", last().method == "buy" and last().params.voucher == 0)
  G.hand.highlighted = { h2 }
  click("use_card", cons1)
  local p = last().params or {}
  check("钩子: 用消耗牌记成 press 并带目标", last().method == "press" and p.fn == "use_card" and p.area == "consumeables" and p.index == 0 and join(p.targets) == "1")

  before = #recorded
  click("use_card", { id = "not_in_any_area" })
  check("钩子: 不在认识的区域里的牌不记", #recorded == before)

  click("buy_from_shop", shop1, "buy_and_use")
  p = last().params or {}
  check("钩子: 买了直接用记成一步", #recorded == before + 1 and p.fn == "buy_from_shop" and p.id == "buy_and_use" and p.index == 0)
  check("钩子: 里面那次 use_card 照常执行", calls[#calls].name == "use_card")

  click("sell_card", j2)
  p = last().params or {}
  check("钩子: 卖小丑", p.fn == "sell_card" and p.area == "jokers" and p.index == 1)
  click("sort_hand_value")
  check("钩子: 排序按钮", last().method == "press" and last().params.fn == "sort_hand_value")
  click("reroll_boss")
  check("钩子: 重掷 Boss", last().params.fn == "reroll_boss")

  -- 回放: 按记下的步骤调用同一个按钮函数, 目标牌先选好
  local unhighlighted = 0
  G.hand.unhighlight_all = function()
    unhighlighted = unhighlighted + 1
    G.hand.highlighted = {}
  end
  G.hand.add_to_highlighted = function(_, card)
    table.insert(G.hand.highlighted, card)
  end
  G.hand.highlighted = { h1, h3 }
  local ok = M2.apply_local("press", { fn = "use_card", area = "consumeables", index = 0, targets = { 1 } })
  local call = calls[#calls]
  check("回放 press: 调用按钮函数", ok == true and call.name == "use_card" and call.e.config.ref_table == cons1)
  check("回放 press: 先换成原局选中的牌", unhighlighted == 1 and #G.hand.highlighted == 1 and G.hand.highlighted[1] == h2)

  local applied = M2.apply_local("press", { fn = "use_card", area = "pack_cards", index = 0 })
  check("回放 press: 卡包还没打开时下一帧再试", applied == nil)
  check("回放 press: 不在名单里的函数不调用", M2.apply_local("press", { fn = "start_run" }) == false)
  check("回放 press: 不认识的区域不碰", M2.apply_local("press", { fn = "sell_card", area = "SETTINGS", index = 0 }) == false)
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("手动操作换算全部通过")
