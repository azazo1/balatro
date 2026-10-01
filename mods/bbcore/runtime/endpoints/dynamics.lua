-- 本仓库新增: 当前局的动态值 (只读).
-- 手册 (docs/game/) 是版本快照, 里面凡是会随局面变化的值都只能写成占位, 例如古老小丑的
-- [本回合目标花色], 城堡的 (当前为+[当前筹码]筹码). 这里把游戏此刻的真实值交出来:
--
-- - targets: 每回合重新抽的认牌目标 (古老小丑的花色, 偶像的花色与点数, 邮件回扣的点数, 城堡的花色,
--   待办清单的牌型) 与盲注公牛要用的 "最常打出的牌型".
-- - jokers / consumables: 持有卡的效果文本, 取游戏自己生成的那一份 (与 gamestate 的 Card.value.effect 同源),
--   成长值 (拉面的当前倍率, 公交车的当前倍率, 城堡的当前筹码...) 与概率都已代入, 就是玩家悬停看到的文字.
--   卡面本身不显示当前值的只有超新星 (看各牌型本赛局的打出次数): 那个数在 gamestate 的 hands[].played 里.
-- - hand: 手牌里带增强, 版本或蜡封的牌的效果文本 (玻璃牌的破碎概率等).
--
-- 只读, 任何阶段都能调用, 不算 agent 活动 (BB_ACTIVITY.PASSIVE), 也不写进回放文件.

---@class Request.Endpoint.Dynamics.Params

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

---@param area table? 例如 G.jokers
---@param filter fun(card: table): boolean? 只收某些牌
---@return table[]
local function collect(area, filter)
  local out = {}
  for i, card in ipairs(area and area.cards or {}) do
    if not filter or filter(card) then
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
-- Dynamics Endpoint
-- ==========================================================================

---@type Endpoint
return {
  name = "dynamics",

  description = "Current per-round targets and live card values (growth, targets, probabilities)",

  schema = {},

  requires_state = nil,

  ---@param _ Request.Endpoint.Dynamics.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    sendDebugMessage("Init dynamics()", "BB.ENDPOINTS")
    local game = G and G.GAME
    local round = (game and game.current_round) or {}
    local jokers = G and G.jokers

    local out = {
      targets = targets(round, jokers),
      jokers = collect(jokers),
      consumables = collect(G and G.consumeables),
      -- 手牌只列带增强, 版本或蜡封的: 其余牌的实时文本就是点数花色, 摘要里已经有了
      hand = collect(G and G.hand, function(card)
        local ability = card.ability or {}
        return (ability.effect and ability.effect ~= "Base") or card.edition or card.seal
      end),
    }
    local most_played = round.most_played_poker_hand
    if most_played then
      out.most_played_poker_hand = {
        poker_hand = most_played,
        poker_hand_name = localized(most_played, "poker_hands"),
      }
    end

    sendDebugMessage("Return dynamics()", "BB.ENDPOINTS")
    send_response(out)
  end,
}
