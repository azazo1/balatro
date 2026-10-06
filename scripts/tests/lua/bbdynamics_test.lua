-- 动态值端点 (bbcore/runtime/endpoints/dynamics.lua) 的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 端点只在 execute 里读全局, 所以这里搭一个最小假游戏, 并用真的 gamestate 取效果文本 (端点是它的调用方).
local Dynamics = dofile("mods/bbcore/runtime/endpoints/dynamics.lua")
BB_GAMESTATE = dofile("mods/bbcore/src/lua/utils/gamestate.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local MISC = {
  suits_singular = { Spades = "黑桃", Hearts = "红桃", Clubs = "梅花", Diamonds = "方片" },
  suits_plural = { Spades = "黑桃", Hearts = "红桃", Clubs = "梅花", Diamonds = "方片" },
  ranks = { Ace = "A", Queen = "Q", King = "K", ["2"] = "2", ["3"] = "3" },
  poker_hands = { ["Two Pair"] = "两对", Pair = "对子" },
}

--- 假日志 (端点开头会写一行调试日志)
function sendDebugMessage() end

-- 假错误码 (端点参数非法时用它)
BB_ERROR_NAMES = { BAD_REQUEST = "BAD_REQUEST", INVALID_STATE = "INVALID_STATE" }

--- 假本地化: 带分类的两参调用查词表, 表参数 (raw_descriptions) 这里用不到, 返回错误由调用方兜住.
function localize(args, category)
  if type(args) == "string" then
    return (MISC[category] or {})[args] or "ERROR"
  end
  return "ERROR"
end

--- 假卡牌: 效果文本由 generate_UIBox_ability_table 给出, 与游戏里的取法一致.
---@param key string
---@param name string
---@param effect string?
---@param extra table?
local function card(key, name, effect, extra)
  local self = { config = { center = { key = key, name = name } }, ability = extra or {} }
  if key:match("^[HDCS]_") then
    self.config.card_key = key
  end
  self.generate_UIBox_ability_table = function()
    if not effect then
      return { main = {} }
    end
    return { main = { { { n = "T", config = { text = effect } } } } }
  end
  return self
end

G = {
  GAME = {
    current_round = {
      ancient_card = { suit = "Spades" },
      idol_card = { suit = "Hearts", rank = "Queen" },
      mail_card = { rank = "Ace" },
      castle_card = { suit = "Clubs" },
      most_played_poker_hand = "Pair",
    },
  },
  P_CENTERS = {
    j_ancient = { name = "古老小丑" },
    j_idol = { name = "偶像" },
    j_mail = { name = "邮件回扣" },
    j_castle = { name = "城堡" },
    j_todo_list = { name = "待办清单" },
  },
  jokers = {
    cards = {
      card("j_ramen", "拉面", "X4.2倍率 每弃掉一张牌 失去X0.01倍率"),
      card("j_todo_list", "待办清单", "如果出牌牌型为两对 获得$4", { to_do_poker_hand = "Two Pair" }),
    },
  },
  consumeables = { cards = { card("c_mercury", "水星", "升级对子 (等级2)") } },
  hand = {
    cards = {
      card("H_K", "红桃K", "底注 +2 倍率"),
      card("S_T", "黑桃10", "X2 倍率 1/4 概率破碎", { effect = "Glass Card" }),
    },
  },
}

---@param card table
---@param suit string
---@param value string
---@return table 一张扑克牌 (base 带花色与点数)
local function playing(suit, value)
  return { base = { suit = suit, value = value }, config = { card_key = ({ Hearts = "H", Spades = "S", Clubs = "C", Diamonds = "D" })[suit] .. "_" .. value } }
end

G.deck = {
  cards = {
    playing("Hearts", "King"), playing("Hearts", "Queen"), playing("Spades", "Ace"),
    playing("Clubs", "Ace"), playing("Diamonds", "Ace"),
  },
}
G.discard = { cards = { playing("Hearts", "2"), playing("Spades", "3") } }

---@param args table?
---@return table 端点的返回
local function collect(args)
  local out
  Dynamics.execute(args or {}, function(response)
    out = response
  end)
  return out
end

do -- 认牌目标: 结构化给出花色与点数, 并带上持有小丑的中文名
  local result = collect()
  local by = {}
  for _, t in ipairs(result.targets) do
    by[t.key] = t
  end
  check("古老小丑的目标花色", by.j_ancient and by.j_ancient.suit == "Spades" and by.j_ancient.suit_name == "黑桃", by.j_ancient and by.j_ancient.suit_name)
  check(
    "偶像的花色与点数",
    by.j_idol and by.j_idol.suit == "Hearts" and by.j_idol.rank == "Queen" and by.j_idol.rank_name == "Q",
    by.j_idol and (by.j_idol.suit .. by.j_idol.rank)
  )
  check("邮件回扣的点数", by.j_mail and by.j_mail.rank == "Ace" and by.j_mail.rank_name == "A")
  check("城堡的花色", by.j_castle and by.j_castle.suit == "Clubs" and by.j_castle.suit_name == "梅花")
  check(
    "待办清单的牌型",
    by.j_todo_list and by.j_todo_list.poker_hand == "Two Pair" and by.j_todo_list.poker_hand_name == "两对",
    by.j_todo_list and by.j_todo_list.poker_hand_name
  )
  check("持有时用卡牌自己的名字", by.j_ramen == nil and by.j_ancient.name == "古老小丑")
  check("最常打出的牌型", result.most_played_poker_hand.poker_hand == "Pair" and result.most_played_poker_hand.poker_hand_name == "对子")
end

do -- 持有卡: 实时效果文本, 下标与摘要一致
  local result = collect()
  check("小丑逐张给效果", #result.jokers == 2 and result.jokers[1].effect == "X4.2倍率 每弃掉一张牌 失去X0.01倍率")
  check("小丑下标从 0 开始", result.jokers[1].index == 0 and result.jokers[2].index == 1)
  check("消耗牌也给", #result.consumables == 1 and result.consumables[1].name == "水星")
  check("卡牌 key", result.jokers[1].key == "j_ramen" and result.consumables[1].key == "c_mercury")
end

do -- 手牌: 只列带增强, 版本或蜡封的
  local result = collect()
  check("手牌只留特殊牌", #result.hand == 1 and result.hand[1].key == "S_T", tostring(#result.hand))
  check("手牌保留真实下标", result.hand[1].index == 1)
  check("增强牌的效果文本", result.hand[1].effect == "X2 倍率 1/4 概率破碎", tostring(result.hand[1].effect))
end

do -- 背面牌不进实时文本, 也不走观察层的身份字段
  G.hand.cards[2].facing = "back"
  G.jokers.cards[1].facing = "back"
  local result = collect()
  check("背面玻璃牌不在 hand", #result.hand == 0, tostring(#result.hand))
  check("背面小丑不在 jokers", #result.jokers == 1 and result.jokers[1].key == "j_todo_list", result.jokers[1] and result.jokers[1].key)
  G.jokers.cards[2].facing = "back"
  check("背面小丑不通过认牌目标泄露", #collect().targets == 0)
  local original = G.jokers.cards[2].ability.to_do_poker_hand
  G.jokers.cards[2].ability.to_do_poker_hand = "Straight Flush"
  check("改变背面待办目标不改变观察", #collect().targets == 0)
  G.jokers.cards[2].ability.to_do_poker_hand = original
  G.jokers.cards[2].facing = nil
  G.hand.cards[2].facing = nil
  G.jokers.cards[1].facing = nil

  local gs = {
    hand = {
      cards = {
        {
          id = 9,
          key = "H_K",
          set = "ENHANCED",
          label = "红桃K",
          value = { suit = "H", rank = "K", effect = "玻璃" },
          modifier = { enhancement = "GLASS", seal = "RED" },
          state = { hidden = true, debuff = true, highlight = true },
          cost = { sell = 3, buy = 0 },
        },
        { id = 2, key = "S_A", value = { suit = "S", rank = "A" }, modifier = {}, state = {}, cost = { sell = 1, buy = 0 } },
      },
    },
    jokers = {
      cards = {
        { id = 4, key = "j_joker", value = { effect = "+4" }, modifier = { eternal = true }, state = { hidden = true }, cost = { sell = 5, buy = 0 } },
      },
    },
  }
  BB_GAMESTATE.redact_hidden(gs)
  local h = gs.hand.cards[1]
  check(
    "观察层背面牌只留 hidden 与选中",
    h.state.hidden and h.state.highlight and not h.state.debuff and h.key == "" and h.id == 0 and h.value.suit == nil and h.modifier.enhancement == nil and h.cost.sell == 0
  )
  check("观察层正面牌不动", gs.hand.cards[2].key == "S_A" and gs.hand.cards[2].id == 2)
  check("观察层翻面小丑不漏卖价", gs.jokers.cards[1].key == "" and gs.jokers.cards[1].cost.sell == 0)
end

do -- 目标缺项 (本局还没有认牌小丑那一局, 或字段被清空) 时该项不出现
  G.GAME.current_round.ancient_card = { suit = nil }
  G.GAME.current_round.idol_card = {}
  G.GAME.current_round.mail_card = {}
  G.GAME.current_round.castle_card = {}
  G.jokers.cards[2].ability.to_do_poker_hand = nil
  local result = collect()
  check("缺项不出现在 targets 里", #result.targets == 0, tostring(#result.targets))
  check("其他字段照常", #result.jokers == 2 and #result.hand == 1)
end

do -- 生成效果文本抛错时不让端点崩掉
  local original = G.jokers.cards[1].generate_UIBox_ability_table
  G.jokers.cards[1].generate_UIBox_ability_table = function()
    error("boom")
  end
  local ok, result = pcall(collect)
  check("生成报错不崩", ok and result.jokers[1].effect == nil, tostring(result and result.jokers[1].effect))
  G.jokers.cards[1].generate_UIBox_ability_table = original
end

do -- 摸牌堆与弃牌堆: 默认不给, 传参才给, 统计与列表两档
  local plain = collect()
  check("默认不带牌堆", plain.deck == nil and plain.discard == nil)

  local stats = collect({ deck = "stats", discard = "stats" })
  check("stats 给张数", stats.deck.count == 5 and stats.discard.count == 2, tostring(stats.deck.count))
  check(
    "stats 按花色统计",
    stats.deck.by_suit["红桃"] == 2 and stats.deck.by_suit["黑桃"] == 1 and stats.deck.by_suit["方片"] == 1,
    tostring(stats.deck.by_suit["红桃"])
  )
  check("stats 按点数统计", stats.deck.by_rank["A"] == 3 and stats.deck.by_rank["K"] == 1, tostring(stats.deck.by_rank["A"]))
  check("stats 不带列表", stats.deck.cards == nil and stats.deck.truncated == nil)
  check("弃牌堆也算", stats.discard.by_suit["红桃"] == 1 and stats.discard.by_rank["3"] == 1)

  local list = collect({ deck = "list" })
  local by_key = {}
  for _, item in ipairs(list.deck.cards) do
    by_key[item.key] = item
  end
  check("list 带完整列表", #list.deck.cards == 5 and by_key.H_King ~= nil, tostring(#(list.deck.cards or {})))
  check(
    "列表项给花色点数与枚举",
    by_key.H_King.suit == "H" and by_key.H_King.suit_name == "红桃" and by_key.H_King.rank == "K",
    by_key.H_King.suit
  )
  check("list 也给统计", list.deck.by_rank["A"] == 3)
  check("只要牌堆时不给弃牌堆", list.discard == nil)
end

do -- 参数: 关掉 targets 与 cards, 非法取值报错
  local bare = collect({ targets = false, cards = false })
  check("可以关掉 targets", bare.targets == nil and bare.most_played_poker_hand == nil)
  check("可以关掉 cards", bare.jokers == nil and bare.consumables == nil and bare.hand == nil)

  local bad
  Dynamics.execute({ deck = "all" }, function(response)
    bad = response
  end)
  check("非法 detail 报 BAD_REQUEST", bad.message ~= nil and bad.name ~= nil, tostring(bad.message))
end

do -- 牌堆列表超过上限时截断并标出来
  local many = {}
  for i = 1, 70 do
    many[i] = playing("Spades", "Ace")
  end
  local saved = G.deck.cards
  G.deck.cards = many
  local result = collect({ deck = "list" })
  check("列表截到上限", #result.deck.cards == 60, tostring(#result.deck.cards))
  check("截断时标出来", result.deck.truncated == true)
  check("张数仍是真的", result.deck.count == 70, tostring(result.deck.count))
  G.deck.cards = saved
end

do -- 摸牌顺序和暗手身份变化不应进入公开牌堆信息
  local saved_deck, saved_hand = G.deck.cards, G.hand.cards
  G.deck.cards = { playing("Hearts", "King"), playing("Spades", "Ace"), playing("Diamonds", "3") }
  G.hand.cards = {}
  local function signature(p)
    local out = { tostring(p.count), tostring(p.unseen_count), tostring(p.hidden_in_hand) }
    for _, counts in ipairs({ p.by_suit, p.by_rank }) do
      local entries = {}
      for key, count in pairs(counts) do
        entries[#entries + 1] = key .. ":" .. count
      end
      table.sort(entries)
      out[#out + 1] = table.concat(entries, ",")
    end
    for _, item in ipairs(p.cards or {}) do
      out[#out + 1] = item.key .. ":" .. item.suit .. ":" .. item.rank
    end
    return table.concat(out, "|")
  end
  local first, last = G.deck.cards[1], G.deck.cards[3]
  local before = signature(collect({ deck = "list" }).deck)
  check("查询不改变实际摸牌顺序", G.deck.cards[1] == first and G.deck.cards[3] == last)
  G.deck.cards[1], G.deck.cards[3] = G.deck.cards[3], G.deck.cards[1]
  check("列表不泄露摸牌顺序", signature(collect({ deck = "list" }).deck) == before)

  local hidden = playing("Hearts", "2")
  hidden.facing = "back"
  G.hand.cards = { hidden }
  local pool = collect({ deck = "list" }).deck
  check("暗手并入未见集合但不改变实际牌堆张数", pool.count == 3 and pool.unseen_count == 4 and pool.hidden_in_hand == 1)
  G.deck.cards[2], G.hand.cards[1] = G.hand.cards[1], G.deck.cards[2]
  G.hand.cards[1].facing = "back"
  check("不按牌堆差值泄露暗手身份", signature(collect({ deck = "list" }).deck) == signature(pool))
  G.deck.cards, G.hand.cards = saved_deck, saved_hand
end

do -- 卡包候选也必须携带游戏当前的易腐剩余回合, 无需重复改已有提取逻辑
  local old = G
  G = { pack_cards = { cards = { card("j_joker", "小丑", nil, { perishable = true, perish_tally = 5 }) } } }
  local gs = BB_GAMESTATE.get_gamestate()
  check("卡包候选保留易腐寿命", gs.pack.cards[1].modifier.perishable == 5)
  G = old
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("all passed")
