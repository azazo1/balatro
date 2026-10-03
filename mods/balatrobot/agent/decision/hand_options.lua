-- 从公开手牌生成有界的完整出牌候选, 不调用游戏计分或模组回调.
local M = { LIMIT = 48 }
local RANK = { T = 10, J = 11, Q = 12, K = 13, A = 14 }
local NAMES = { ["High Card"] = "高牌", Pair = "对子", ["Two Pair"] = "两对", ["Three of a Kind"] = "三条",
  Straight = "顺子", Flush = "同花", ["Full House"] = "葫芦", ["Four of a Kind"] = "四条",
  ["Straight Flush"] = "同花顺", ["Five of a Kind"] = "五条", ["Flush House"] = "同花葫芦", ["Flush Five"] = "同花五条" }
local ORDER = { "Flush Five", "Flush House", "Five of a Kind", "Straight Flush", "Four of a Kind", "Full House",
  "Flush", "Straight", "Three of a Kind", "Two Pair", "Pair", "High Card" }
local function clone(t) local out = {}; for i, v in ipairs(t) do out[i] = v end; return out end
local function rank(card)
  local value = card.value and card.value.rank
  local n = RANK[value] or tonumber(value)
  return n and n >= 2 and n <= 14 and n == math.floor(n) and n or nil
end
local function flags(gs)
  local out = {}
  for _, card in ipairs(gs.jokers and gs.jokers.cards or {}) do
    if not (card.state and (card.state.hidden or card.state.debuff)) then out[card.key or ""] = true end
  end
  return out
end
local function info(card, index)
  if not card or (card.state and card.state.hidden) then return { index = index, unknown = true, chips = 0 } end
  local enhancement = card.modifier and card.modifier.enhancement
  local stone, value = enhancement == "STONE", rank(card)
  local suit = card.value and card.value.suit
  return { index = index, rank = not stone and value or nil, suit = not stone and suit or nil,
    wild = enhancement == "WILD" and not (card.state and card.state.debuff),
    unknown = not stone and (not value or not suit), stone = stone,
    chips = card.state and card.state.debuff and 0 or (stone and 50 or (value == 14 and 11 or math.min(value or 0, 10))) }
end
local function higher(a, b)
  if a.chips ~= b.chips then return a.chips > b.chips end
  if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) > (b.rank or 0) end
  return a.index < b.index
end
local function suit_matches(card, suit, f)
  if card.stone or card.unknown then return false end
  if card.wild or card.suit == suit then return true end
  return f.j_smeared and ((card.suit == "H" or card.suit == "D") == (suit == "H" or suit == "D")) or false
end
local function groups(cards)
  local map, out = {}, {}
  for _, c in ipairs(cards) do
    if c.rank then map[c.rank] = map[c.rank] or {}; map[c.rank][#map[c.rank] + 1] = c end
  end
  for _, group in pairs(map) do table.sort(group, higher); out[#out + 1] = group end
  table.sort(out, function(a, b) return #a ~= #b and #a > #b or (#a == #b and a[1].rank > b[1].rank) end)
  return out
end
local function prefix(cards, n)
  local out = {}; for i = 1, math.min(n, #cards) do out[i] = cards[i].index end; return out
end
local function join(a, b)
  local out = clone(a); for _, v in ipairs(b) do out[#out + 1] = v end; return out
end
-- 每个高端点只取一条代表顺子, 不枚举全部子集. A 同时能作 1.
local function straights(cards, f)
  local map, out, need = {}, {}, f.j_four_fingers and 4 or 5
  for _, c in ipairs(cards) do
    if c.rank and (not map[c.rank] or higher(c, map[c.rank])) then map[c.rank] = c end
  end
  map[1] = map[14]
  for high = 14, need, -1 do
    if map[high] then
      local selected, last_missing = {}, false
      for r = high, 1, -1 do
        if map[r] then
          selected[#selected + 1] = map[r].index; last_missing = false
          if #selected == need then out[#out + 1] = selected; break end
        elseif f.j_shortcut and not last_missing then last_missing = true
        else break end
      end
    end
  end
  return out
end

-- 只作常规牌型和基础筹码参考, 不预测小丑, 增强, 留牌, 重触发或 Boss 的最终得分.
function M.preview(gs, indices)
  local all, selected, f = gs.hand and gs.hand.cards or {}, {}, flags(gs)
  for _, index in ipairs(indices) do
    local c = info(all[index + 1], index)
    if c.unknown then return { known = false, note = "包含背面或非标准牌, 牌型与得分未知" } end
    selected[#selected + 1] = c
  end
  if #selected == 0 or #selected > 5 then return { known = false, note = "未完成选牌或超过常规 5 张, 需按实际规则判断" } end
  local by_rank, need, flush = groups(selected), f.j_four_fingers and 4 or 5, false
  for _, suit in ipairs({ "H", "D", "C", "S" }) do
    local suited = {}; for _, c in ipairs(selected) do if suit_matches(c, suit, f) then suited[#suited + 1] = c end end
    if #suited >= need then flush = true; break end
  end
  local straight = #straights(selected, f) > 0
  local first, second = #(by_rank[1] or {}), #(by_rank[2] or {})
  local name, scoring = "High Card", {}
  if first >= 5 then name, scoring = flush and "Flush Five" or "Five of a Kind", prefix(by_rank[1], 5)
  elseif first >= 3 and second >= 2 then name, scoring = flush and "Flush House" or "Full House", join(prefix(by_rank[1], 3), prefix(by_rank[2], 2))
  elseif flush and straight then name, scoring = "Straight Flush", prefix(selected, #selected)
  elseif first >= 4 then name, scoring = "Four of a Kind", prefix(by_rank[1], 4)
  elseif flush then name, scoring = "Flush", prefix(selected, #selected)
  elseif straight then name, scoring = "Straight", straights(selected, f)[1]
  elseif first >= 3 then name, scoring = "Three of a Kind", prefix(by_rank[1], 3)
  elseif first >= 2 and second >= 2 then name, scoring = "Two Pair", join(prefix(by_rank[1], 2), prefix(by_rank[2], 2))
  elseif first >= 2 then name, scoring = "Pair", prefix(by_rank[1], 2)
  else
    local ranked = {}; for _, c in ipairs(selected) do if c.rank then ranked[#ranked + 1] = c end end
    table.sort(ranked, function(a, b) return a.rank > b.rank end)
    if ranked[1] then scoring = { ranked[1].index } end
  end
  local counted, nominal = {}, 0
  for _, index in ipairs(scoring) do counted[index] = true end
  for _, c in ipairs(selected) do if counted[c.index] or c.stone or f.j_splash then nominal = nominal + c.chips end end
  local hand = gs.hands and gs.hands[name]
  local out = { known = true, hand = name, label = NAMES[name], nominal_card_chips = nominal }
  if hand and type(hand.chips) == "number" and type(hand.mult) == "number" then
    out.hand_chips, out.hand_mult = hand.chips, hand.mult
    out.reference_score = (hand.chips + nominal) * hand.mult
  end
  out.note = "常规牌型参考, 未计增强/版本/小丑/留牌/重触发/特殊牌组/Boss 等效果, 不保证实际得分"
  return out
end

function M.build(gs, target)
  local cards, all, f = {}, gs.hand and gs.hand.cards or {}, flags(gs)
  for _, index in ipairs(target.indices) do cards[#cards + 1] = info(all[index + 1], index) end
  table.sort(cards, higher)
  local by_rank, pool, seen = groups(cards), {}, {}
  local function add(indices)
    if #pool >= 256 then return end
    local present, chosen = {}, {}
    for _, index in ipairs(join(indices, target.forced or {})) do
      if not present[index] then present[index] = true; chosen[#chosen + 1] = index end
    end
    if #chosen < target.min or #chosen > target.max then return end
    table.sort(chosen)
    local key = table.concat(chosen, ",")
    if seen[key] then return end
    seen[key] = true
    local preview = M.preview(gs, chosen)
    local label = "出牌 hand[" .. key .. "] (" .. #chosen .. " 张): " .. (preview.label or preview.note)
    if preview.reference_score then label = label .. ", 牌型基础与普通牌面参考 " .. preview.reference_score .. " 分" end
    pool[#pool + 1] = { indices = chosen, label = label, preview = preview }
  end
  -- 排序后的整组牌与各点数组, 不遍历 C(n, 1..5).
  for count = math.max(1, target.min), math.min(5, target.max, #cards) do add(prefix(cards, count)) end
  for _, group in ipairs(by_rank) do
    add(prefix(group, 1))
    for count = 2, math.min(5, #group, target.max) do add(prefix(group, count)) end
  end
  for i, a in ipairs(by_rank) do
    if #a >= 2 then
      for j, b in ipairs(by_rank) do
        if i < j and #b >= 2 then add(join(prefix(a, 2), prefix(b, 2))) end
        if #a >= 3 and i ~= j and #b >= 2 then add(join(prefix(a, 3), prefix(b, 2))) end
      end
    end
  end
  for _, suit in ipairs({ "H", "D", "C", "S" }) do
    local suited = {}; for _, c in ipairs(cards) do if suit_matches(c, suit, f) then suited[#suited + 1] = c end end
    local need = f.j_four_fingers and 4 or 5
    if #suited >= need then
      add(prefix(suited, math.min(5, #suited)))
      if need == 4 then add(prefix(suited, 4)) end
      for _, indices in ipairs(straights(suited, f)) do add(indices) end
    end
  end
  for _, indices in ipairs(straights(cards, f)) do add(indices) end
  -- 同一计分核心补带非计分牌的少量方案, 让模型能比较换牌与留牌效果.
  local seeds = #pool
  for i = 1, seeds do
    local padded, present = clone(pool[i].indices), {}
    for _, index in ipairs(padded) do present[index] = true end
    for _, c in ipairs(cards) do
      if #padded >= math.min(5, target.max) then break end
      if not present[c.index] then padded[#padded + 1] = c.index end
    end
    add(padded)
  end
  table.sort(pool, function(a, b)
    local x, y = a.preview.reference_score or 0, b.preview.reference_score or 0
    if x ~= y then return x > y end
    if #a.indices ~= #b.indices then return #a.indices < #b.indices end
    return table.concat(a.indices, ",") < table.concat(b.indices, ",")
  end)
  -- 先保留各牌型代表和非计分牌变体, 再填高参考分候选. 高牌仍可合法选择.
  local result, picked, types = {}, {}, {}
  for _, name in ipairs(ORDER) do types[name] = 0 end
  for i, item in ipairs(pool) do
    local name = item.preview.hand or "unknown"
    if (types[name] or 0) < 2 and #result < M.LIMIT then
      result[#result + 1] = item; picked[i] = true; types[name] = (types[name] or 0) + 1
    end
  end
  for i, item in ipairs(pool) do if not picked[i] and #result < M.LIMIT then result[#result + 1] = item end end
  table.sort(result, function(a, b) return (a.preview.reference_score or 0) > (b.preview.reference_score or 0) end)
  return result
end

return M
