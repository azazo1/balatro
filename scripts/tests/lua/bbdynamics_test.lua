-- 动态值端点 (bbcore/runtime/endpoints/dynamics.lua) 的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 端点只在 execute 里读全局, 所以这里搭一个最小假游戏.
local Dynamics = dofile("mods/bbcore/runtime/endpoints/dynamics.lua")

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
  ranks = { Ace = "A", Queen = "Q", King = "K" },
  poker_hands = { ["Two Pair"] = "两对", Pair = "对子" },
}

--- 假日志 (端点开头会写一行调试日志)
function sendDebugMessage() end

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

---@return table 端点的返回
local function collect()
  local out
  Dynamics.execute({}, function(response)
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
  G.jokers.cards[1].generate_UIBox_ability_table = function()
    error("boom")
  end
  local ok, result = pcall(collect)
  check("生成报错不崩", ok and result.jokers[1].effect == nil, tostring(result and result.jokers[1].effect))
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("all passed")
