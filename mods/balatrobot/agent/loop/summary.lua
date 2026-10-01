--[[
把 gamestate (bbcore 的 src/lua/utils/gamestate.lua 的输出) 转成给模型看的中文精简文本. 纯逻辑, 不依赖游戏.

- 下标从 0 开始, 与动作参数一致, 每行开头写 [下标].
- 小丑, 消耗牌, 优惠券, 商店与卡包里的牌第一次出现时附上中文名与效果, 之后只写名字,
  名字与效果来自注入的 describe(key) (游戏内由手册 catalog 提供), 查不到时用 gamestate 里的 label 与 effect.
- 整副牌只给张数, 不列出; 牌型只列出等级高于 1 或本局打过的.
]]

local M = {}

local SUIT = { H = "红桃", D = "方片", C = "梅花", S = "黑桃" }
local RANK = { T = "10" }
local EDITION = { FOIL = "闪箔", HOLO = "镭射", POLYCHROME = "多彩", NEGATIVE = "负片" }
local SEAL = { RED = "红色蜡封", BLUE = "蓝色蜡封", GOLD = "金色蜡封", PURPLE = "紫色蜡封" }
local ENHANCEMENT = {
  BONUS = "奖励牌",
  MULT = "倍率牌",
  WILD = "万能牌",
  GLASS = "玻璃牌",
  STEEL = "钢铁牌",
  STONE = "石头牌",
  GOLD = "黄金牌",
  LUCKY = "幸运牌",
}
local STATE = {
  MENU = "主菜单",
  BLIND_SELECT = "选择盲注",
  SELECTING_HAND = "出牌",
  HAND_PLAYED = "计分中",
  DRAW_TO_HAND = "抽牌中",
  ROUND_EVAL = "结算",
  SHOP = "商店",
  SMODS_BOOSTER_OPENED = "打开补充包",
  GAME_OVER = "游戏结束",
}
local BLIND_STATUS = {
  CURRENT = "进行中",
  SELECT = "待选择",
  UPCOMING = "未到",
  DEFEATED = "已击败",
  SKIPPED = "已跳过",
}
local BLIND_TYPE = { SMALL = "小盲注", BIG = "大盲注", BOSS = "Boss" }
local HAND_ZH = {
  ["Flush Five"] = "同花五条",
  ["Flush House"] = "同花葫芦",
  ["Five of a Kind"] = "五条",
  ["Straight Flush"] = "同花顺",
  ["Four of a Kind"] = "四条",
  ["Full House"] = "葫芦",
  ["Flush"] = "同花",
  ["Straight"] = "顺子",
  ["Three of a Kind"] = "三条",
  ["Two Pair"] = "两对",
  ["Pair"] = "对子",
  ["High Card"] = "高牌",
}
local EFFECT_MAX = 60 -- 效果说明的最大字数

---@param text string
---@param limit integer
---@return string
local function clip(text, limit)
  local chars = {}
  for ch in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = ch
    if #chars > limit then
      break
    end
  end
  if #chars <= limit then
    return table.concat(chars)
  end
  return table.concat(chars, "", 1, limit - 1) .. "…"
end

---@param text string?
---@return string
local function squash(text)
  return (tostring(text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

---@param mod table?
---@return string 附加说明, 以空格开头; 没有时为空串
local function modifiers(mod, state)
  local parts = {}
  mod = mod or {}
  if mod.enhancement then
    parts[#parts + 1] = ENHANCEMENT[mod.enhancement] or mod.enhancement
  end
  if mod.edition then
    parts[#parts + 1] = EDITION[mod.edition] or mod.edition
  end
  if mod.seal then
    parts[#parts + 1] = SEAL[mod.seal] or mod.seal
  end
  if mod.eternal then
    parts[#parts + 1] = "永恒"
  end
  if mod.perishable then
    parts[#parts + 1] = "易腐 " .. mod.perishable .. " 回合"
  end
  if mod.rental then
    parts[#parts + 1] = "租赁"
  end
  state = state or {}
  if state.debuff then
    parts[#parts + 1] = "被削弱"
  end
  if state.hidden then
    parts[#parts + 1] = "背面朝上"
  end
  if #parts == 0 then
    return ""
  end
  return " (" .. table.concat(parts, ", ") .. ")"
end

---@param card table
---@return string
local function playing_card(card)
  local value = card.value or {}
  if value.rank and value.suit then
    return (SUIT[value.suit] or value.suit) .. (RANK[value.rank] or value.rank)
  end
  return card.label or card.key or "?"
end

--- 摘要器: 记住已经介绍过的卡, 同一局里只介绍一次.
---@param describe fun(key: string): {name: string?, effect: string?}?
---@return table
function M.new(describe)
  local self = { seen = {}, describe = describe or function() return nil end }

  --- 新的一局 (或压缩上下文) 时调用, 之后重新介绍.
  function self:forget()
    self.seen = {}
  end

  --- 非扑克牌的一行: 名字, 修饰, 价格, 第一次出现时附效果.
  ---@param card table
  ---@param price string? 例如 "$6" 或 "卖 $3"
  ---@return string
  function self:item(card, price)
    local info = self.describe(card.key or "") or {}
    local name = info.name or card.label or card.key or "?"
    local line = name .. modifiers(card.modifier, card.state)
    if price then
      line = line .. " " .. price
    end
    local key = card.key or name
    if not self.seen[key] then
      self.seen[key] = true
      local effect = squash(info.effect or (card.value and card.value.effect))
      if effect ~= "" then
        line = line .. ": " .. clip(effect, EFFECT_MAX)
      end
    end
    return line
  end

  ---@param title string
  ---@param area table?
  ---@param fmt fun(card: table): string
  ---@param out string[]
  local function list(title, area, fmt, out)
    if not area or type(area.cards) ~= "table" or #area.cards == 0 then
      return
    end
    local head = title
    if area.limit and area.limit > 0 then
      head = string.format("%s (%d/%d)", title, #area.cards, area.limit)
    end
    out[#out + 1] = head .. ":"
    for i, card in ipairs(area.cards) do
      out[#out + 1] = string.format("  [%d] %s", i - 1, fmt(card))
    end
  end

  ---@param gs table gamestate
  ---@return string
  function self:render(gs)
    local out = {}
    local state = gs.state or "UNKNOWN"
    out[#out + 1] = string.format(
      "阶段: %s | 底注 %s 回合 %s | 金钱 $%s",
      STATE[state] or state,
      tostring(gs.ante_num or 0),
      tostring(gs.round_num or 0),
      tostring(gs.money or 0)
    )
    if gs.overlay then
      out[#out + 1] = "弹窗: " .. tostring(gs.overlay)
    end
    if state == "MENU" then
      return table.concat(out, "\n")
    end

    local blinds = gs.blinds or {}
    for _, kind in ipairs({ "small", "big", "boss" }) do
      local b = blinds[kind]
      if b and b.name and b.name ~= "" then
        local line = string.format(
          "%s %s: 目标 %s, %s",
          BLIND_TYPE[b.type] or kind,
          b.name,
          tostring(b.score or 0),
          BLIND_STATUS[b.status] or tostring(b.status)
        )
        if b.effect and b.effect ~= "" then
          line = line .. ", 效果: " .. clip(squash(b.effect), EFFECT_MAX)
        end
        if b.tag_name and b.tag_name ~= "" and (b.status == "SELECT" or b.status == "UPCOMING") and kind ~= "boss" then
          line = line .. ", 跳过奖励: " .. b.tag_name
        end
        out[#out + 1] = line
      end
    end

    local round = gs.round or {}
    if state == "SELECTING_HAND" or state == "HAND_PLAYED" or state == "DRAW_TO_HAND" then
      out[#out + 1] = string.format(
        "本回合: 已得 %s 分, 剩余出牌 %s 次, 弃牌 %s 次",
        tostring(round.chips or 0),
        tostring(round.hands_left or 0),
        tostring(round.discards_left or 0)
      )
    elseif state == "SHOP" and round.reroll_cost then
      out[#out + 1] = "刷新价格: $" .. tostring(round.reroll_cost)
    end

    -- 上一手的计分结果 (bbcore 的 runtime/scoring.lua 记好的一行). 明细太长, 只在出牌那一步的结果里给一次.
    if round.last_hand and round.last_hand.line then
      out[#out + 1] = tostring(round.last_hand.line)
    end

    local hand = gs.hand
    if hand and hand.cards and #hand.cards > 0 then
      local parts = {}
      for i, card in ipairs(hand.cards) do
        parts[#parts + 1] = string.format("[%d]%s%s", i - 1, playing_card(card), modifiers(card.modifier, card.state))
      end
      local head = "手牌"
      if hand.highlighted_limit then
        head = string.format("手牌 (最多选 %d 张)", hand.highlighted_limit)
      end
      out[#out + 1] = head .. ": " .. table.concat(parts, " ")
    end

    list("小丑", gs.jokers, function(card)
      return self:item(card, card.cost and card.cost.sell and ("卖 $" .. card.cost.sell) or nil)
    end, out)
    list("消耗牌", gs.consumables, function(card)
      return self:item(card)
    end, out)
    if state == "SHOP" then
      list("商店", gs.shop, function(card)
        return self:item(card, "$" .. tostring(card.cost and card.cost.buy or "?"))
      end, out)
      list("优惠券", gs.vouchers, function(card)
        return self:item(card, "$" .. tostring(card.cost and card.cost.buy or "?"))
      end, out)
      list("补充包", gs.packs, function(card)
        return self:item(card, "$" .. tostring(card.cost and card.cost.buy or "?"))
      end, out)
    end
    if state == "SMODS_BOOSTER_OPENED" then
      list("卡包内容", gs.pack, function(card)
        if card.value and card.value.rank then
          return playing_card(card) .. modifiers(card.modifier, card.state)
        end
        return self:item(card)
      end, out)
    end

    if gs.cards and gs.cards.count then
      out[#out + 1] = "牌堆剩余: " .. tostring(#(gs.cards.cards or {})) .. " 张"
    end

    local levels = {}
    for name, h in pairs(gs.hands or {}) do
      if (h.level or 1) > 1 or (h.played or 0) > 0 then
        levels[#levels + 1] = { name = name, h = h }
      end
    end
    table.sort(levels, function(a, b)
      return (a.h.order or 0) < (b.h.order or 0)
    end)
    if #levels > 0 then
      local parts = {}
      for _, item in ipairs(levels) do
        parts[#parts + 1] = string.format(
          "%s Lv%d %dx%d",
          HAND_ZH[item.name] or item.name,
          item.h.level or 1,
          item.h.chips or 0,
          item.h.mult or 0
        )
      end
      out[#out + 1] = "牌型: " .. table.concat(parts, ", ")
    end

    local vouchers = {}
    for name in pairs(gs.used_vouchers or {}) do
      local info = self.describe(name) or {}
      vouchers[#vouchers + 1] = info.name or name
    end
    table.sort(vouchers)
    if #vouchers > 0 then
      out[#out + 1] = "已有优惠券: " .. table.concat(vouchers, ", ")
    end
    return table.concat(out, "\n")
  end

  return self
end

M.HAND_ZH = HAND_ZH
M.STATE = STATE

return M
