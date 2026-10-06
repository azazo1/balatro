-- 本仓库新增: 当前局的动态值 (只读).
-- 手册 (docs/game/) 是版本快照, 里面凡是会随局面变化的值都只能写成占位, 例如古老小丑的
-- [本回合目标花色], 城堡的 (当前为+[当前筹码]筹码). 这里把游戏此刻的真实值交出来:
--
-- - targets: 每回合重新抽的认牌目标 (古老小丑的花色, 偶像的花色与点数, 邮件回扣的点数, 城堡的花色,
--   待办清单的牌型) 与盲注公牛要用的 "最常打出的牌型".
-- - jokers / consumables: 持有卡的效果文本, 取游戏自己生成的那一份 (与 gamestate 的 Card.value.effect 同源),
--   背面朝上的牌跳过 (人悬停也看不到效果).
--   成长值 (拉面的当前倍率, 公交车的当前倍率, 城堡的当前筹码...) 与概率都已代入, 就是玩家悬停看到的文字.
--   卡面本身不显示当前值的只有超新星 (看各牌型本赛局的打出次数): 那个数在 gamestate 的 hands[].played 里.
-- - hand: 手牌里带增强, 版本或蜡封的牌的效果文本 (玻璃牌的破碎概率等).
-- - deck / discard: 摸牌堆与弃牌堆 (弃牌堆里是本回合弃掉与打出的牌), 按参数给统计或完整列表,
--   算同花与顺子的概率要用它. 默认不给, 避免每次调用都带上几十张牌.
--
-- 参数都是可选的: targets 与 cards 默认给 (布尔), deck 与 discard 取值 "stats" (张数与按花色点数的统计) 或
-- "list" (再加完整列表), 不给就完全不带这一项.
--
-- 只读, 任何阶段都能调用, 不算 agent 活动 (BB_ACTIVITY.PASSIVE), 也不写进回放文件.

---@class Request.Endpoint.Dynamics.Params
---@field targets boolean? 是否给认牌目标, 默认 true
---@field cards boolean? 是否给持有卡与手牌的实时效果, 默认 true
---@field deck string? "stats" 或 "list", 不给时不返回摸牌堆
---@field discard string? "stats" 或 "list", 不给时不返回弃牌堆

-- ==========================================================================
-- 取实时文本
-- ==========================================================================

--- 卡牌的效果文本用游戏自己生成的那一份 (中文按游戏语言), 取法与 gamestate 里的 Card.value.effect 相同:
--- 生成过程会创建 DynaText 对象, 那份实现里已经清理掉, 这里不重复一份免得漏掉清理.
---@param card table 游戏里的卡牌对象
---@return string?
local function live_effect(card)
  local describe = BB_GAMESTATE and BB_GAMESTATE.card_ui_description
  if not describe then
    return nil
  end
  local ok, text = pcall(describe, card)
  text = ok and text or nil
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return text ~= "" and text or nil
end

---@param card table 游戏里的卡牌对象
---@return string 卡牌名 (游戏语言)
local function card_name(card)
  local center = card.config and card.config.center
  return card.label or (center and center.name) or "?"
end

--- 一张卡的条目: 下标与摘要里的 [n] 一致.
---@param index integer
---@param card table
---@param extra table? 附加字段 (手牌带修饰时给)
---@return table
local function entry(index, card, extra)
  local item = {
    index = index - 1,
    key = (card.config and (card.config.card_key or (card.config.center and card.config.center.key))) or "",
    name = card_name(card),
    effect = live_effect(card),
  }
  for k, v in pairs(extra or {}) do
    item[k] = v
  end
  return item
end

---@param card table
---@return boolean
local function face_down(card)
  return card.facing == "back"
end

---@param area table? 例如 G.jokers
---@param filter fun(card: table): boolean? 只收某些牌
---@return table[]
local function collect(area, filter)
  local out = {}
  for i, card in ipairs(area and area.cards or {}) do
    -- 背面朝上的牌人悬停也看不到效果, 不进实时文本
    if not face_down(card) and (not filter or filter(card)) then
      out[#out + 1] = entry(i, card)
    end
  end
  return out
end

-- ==========================================================================
-- 每回合变动的认牌目标
-- ==========================================================================

---@return string? 本地化名称, 取不到时为 nil
local function localized(value, category)
  if not value then
    return nil
  end
  local ok, text = pcall(localize, value, category)
  return ok and type(text) == "string" and text ~= "ERROR" and text or nil
end

--- 认牌目标: 每个条目带上它属于哪张牌, 模型对着摘要里的小丑名就能对上.
---@param round table G.GAME.current_round
---@param joker table? G.jokers
---@return table[]
local function targets(round, joker)
  local out = {}
  -- 不能按隐藏小丑的 key 单独删目标, 否则删除了哪项本身就泄露身份.
  for _, card in ipairs(joker and joker.cards or {}) do
    if face_down(card) then return out end
  end

  --- 找持有小丑的中文名 (没持有时不写, 但目标本身仍然给, 免得刚买下就查不到).
  ---@param key string
  ---@return string?
  local function owned(key)
    for _, card in ipairs(joker and joker.cards or {}) do
      if card.config and card.config.center and card.config.center.key == key then
        return card.label or card.config.center.name
      end
    end
    return nil
  end

  local function add(key, fields)
    local center = G.P_CENTERS and G.P_CENTERS[key]
    fields.key = key
    fields.name = owned(key) or (center and center.name) or key
    out[#out + 1] = fields
  end

  local ancient = round.ancient_card or {}
  if ancient.suit then
    add("j_ancient", { suit = ancient.suit, suit_name = localized(ancient.suit, "suits_singular") })
  end
  local idol = round.idol_card or {}
  if idol.suit or idol.rank then
    add("j_idol", {
      suit = idol.suit,
      suit_name = localized(idol.suit, "suits_singular"),
      rank = idol.rank,
      rank_name = localized(idol.rank, "ranks"),
    })
  end
  local mail = round.mail_card or {}
  if mail.rank then
    add("j_mail", { rank = mail.rank, rank_name = localized(mail.rank, "ranks") })
  end
  local castle = round.castle_card or {}
  if castle.suit then
    add("j_castle", { suit = castle.suit, suit_name = localized(castle.suit, "suits_singular") })
  end
  -- 待办清单的目标在牌自己身上 (每回合结束时重抽)
  for _, card in ipairs(joker and joker.cards or {}) do
    local hand = card.ability and card.ability.to_do_poker_hand
    if hand then
      add("j_todo_list", { poker_hand = hand, poker_hand_name = localized(hand, "poker_hands") })
      break
    end
  end
  return out
end

-- ==========================================================================
-- 摸牌堆与弃牌堆
-- ==========================================================================

-- 列表最多给这么多张 (牌组可能被复制到上百张), 超出时只给统计并标 truncated.
local PILE_LIST_MAX = 60

--- 一堆牌的一份快照: 张数, 按花色与点数的统计, 以及 (要的时候就给) 完整列表.
--- 花色与点数用游戏语言的名字, 与 targets 那边一致.
---@param area table? 例如 G.deck
---@param detail string "stats" 或 "list"
---@param hidden_hand table? 摸牌堆统计需合并的背面手牌
---@return table
local function pile(area, detail, hidden_hand)
  local original = (area and area.cards) or {}
  local cards = {}
  for _, card in ipairs(original) do
    cards[#cards + 1] = card
  end
  local hidden_count = 0
  for _, card in ipairs(hidden_hand and hidden_hand.cards or {}) do
    if face_down(card) then
      cards[#cards + 1] = card
      hidden_count = hidden_count + 1
    end
  end
  local out = { count = #original }
  if hidden_count > 0 then
    -- 与游戏未打牌预览一致, 合并暗手, 不用准确摸牌堆分布反推暗牌.
    out.unseen_count = #cards
    out.hidden_in_hand = hidden_count
  end
  local by_suit, by_rank = {}, {}
  for _, card in ipairs(cards) do
    local base = card.base or {}
    local suit = localized(base.suit, "suits_plural")
    local rank = localized(base.value, "ranks")
    if suit then
      by_suit[suit] = (by_suit[suit] or 0) + 1
    end
    if rank then
      by_rank[rank] = (by_rank[rank] or 0) + 1
    end
  end
  out.by_suit = by_suit
  out.by_rank = by_rank

  if detail == "list" then
    local list = {}
    for _, card in ipairs(cards) do
      local base = card.base or {}
      list[#list + 1] = {
        key = (card.config and card.config.card_key) or "",
        suit = BB_GAMESTATE and BB_GAMESTATE.suit_enum and BB_GAMESTATE.suit_enum(base.suit) or base.suit,
        suit_name = localized(base.suit, "suits_plural"),
        rank = BB_GAMESTATE and BB_GAMESTATE.rank_enum and BB_GAMESTATE.rank_enum(base.value) or base.value,
        rank_name = localized(base.value, "ranks"),
      }
    end
    -- 只排序响应副本, 再截断; 不泄露原顺序或下一张牌, 也不改变游戏牌堆.
    local function order_key(item)
      return item.key .. ":" .. tostring(item.suit) .. ":" .. tostring(item.rank)
    end
    table.sort(list, function(a, b)
      return order_key(a) < order_key(b)
    end)
    if #list > PILE_LIST_MAX then
      out.truncated = true
      for i = #list, PILE_LIST_MAX + 1, -1 do
        list[i] = nil
      end
    end
    out.cards = list
  end
  return out
end

-- ==========================================================================
-- Dynamics Endpoint
-- ==========================================================================

-- 取值只有这两个, 别的都算参数错误 (校验器只管类型, 取值范围端点自己把关).
local DETAIL = { stats = true, list = true }

---@type Endpoint
return {
  name = "dynamics",

  description = "Current per-round targets and live card values (growth, targets, probabilities)",

  schema = {
    targets = {
      type = "boolean",
      required = false,
      description = "Give the per-round targets, defaults to true",
    },
    cards = {
      type = "boolean",
      required = false,
      description = "Give live effect texts of held cards and special cards in hand, defaults to true",
    },
    deck = {
      type = "string",
      required = false,
      description = "摸牌堆: stats 给张数与分布, list 给排序后的列表, 不含抽牌顺序. 有暗手时统计与列表合并暗手, 另给 unseen_count 和 hidden_in_hand",
    },
    discard = {
      type = "string",
      required = false,
      description = "Discard pile (discarded and played this round) detail: 'stats' or 'list'. Omit for none",
    },
  },

  requires_state = nil,

  ---@param args Request.Endpoint.Dynamics.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    sendDebugMessage("Init dynamics()", "BB.ENDPOINTS")
    args = args or {}
    for _, field in ipairs({ "deck", "discard" }) do
      local detail = args[field]
      if detail ~= nil and not DETAIL[detail] then
        send_response({
          message = "Field '" .. field .. "' must be 'stats' or 'list'",
          name = BB_ERROR_NAMES.BAD_REQUEST,
        })
        return
      end
    end

    local game = G and G.GAME
    local round = (game and game.current_round) or {}
    local jokers = G and G.jokers

    -- targets 与 cards 默认都给, 显式传 false 时才省掉
    local out = {}
    if args.targets ~= false then
      out.targets = targets(round, jokers)
      local most_played = round.most_played_poker_hand
      if most_played then
        out.most_played_poker_hand = {
          poker_hand = most_played,
          poker_hand_name = localized(most_played, "poker_hands"),
        }
      end
    end
    if args.cards ~= false then
      out.jokers = collect(jokers)
      out.consumables = collect(G and G.consumeables)
      -- 手牌只列带增强, 版本或蜡封的: 其余牌的实时文本就是点数花色, 摘要里已经有了
      out.hand = collect(G and G.hand, function(card)
        local ability = card.ability or {}
        return (ability.effect and ability.effect ~= "Base") or card.edition or card.seal
      end)
    end
    if args.deck then
      out.deck = pile(G and G.deck, args.deck, G and G.hand)
    end
    if args.discard then
      out.discard = pile(G and G.discard, args.discard)
    end

    sendDebugMessage("Return dynamics()", "BB.ENDPOINTS")
    send_response(out)
  end,
}
