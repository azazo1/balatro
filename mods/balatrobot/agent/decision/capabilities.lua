-- 根据当前游戏对象生成动作约束, 不模拟点击或执行端点.
local M = {}
local DECKS = {
  { "RED", "b_red" }, { "BLUE", "b_blue" }, { "YELLOW", "b_yellow" }, { "GREEN", "b_green" },
  { "BLACK", "b_black" }, { "MAGIC", "b_magic" }, { "NEBULA", "b_nebula" }, { "GHOST", "b_ghost" },
  { "ABANDONED", "b_abandoned" }, { "CHECKERED", "b_checkered" }, { "ZODIAC", "b_zodiac" },
  { "PAINTED", "b_painted" }, { "ANAGLYPH", "b_anaglyph" }, { "PLASMA", "b_plasma" }, { "ERRATIC", "b_erratic" },
}
local STAKES = { "WHITE", "RED", "GREEN", "BLACK", "BLUE", "PURPLE", "ORANGE", "GOLD" }
local function cards(area) return area and area.cards or {} end
local function hidden(card) return card.facing == "back" end
local function predicate(card, name, ...)
  if type(card[name]) ~= "function" then return false end
  local ok, result = pcall(card[name], card, ...)
  return ok and result == true
end

function M.new(deps)
  local build = {}
  function build.snapshot(gs)
    local g = deps.game()
    local result = { actions = {}, forced = {}, unsupported = false }
    if deps.hand_options then result.preview_hand = function(indices) return deps.hand_options.preview(gs, indices) end end
    local function add(method, params, label, extra)
      local action = extra or {}
      action.method, action.params, action.label = method, params or {}, label
      result.actions[#result.actions + 1] = action
    end
    if gs.state == "MENU" then
      local decks = {}
      for _, deck in ipairs(DECKS) do
        if g.P_CENTERS and g.P_CENTERS[deck[2]] then decks[#decks + 1] = deck[1] end
      end
      if #decks > 0 then add("start", {}, "开新一局", { decks = decks, stakes = STAKES }) end
      return result
    end
    local game = g.GAME or {}
    local money = (game.dollars or 0) - (game.bankrupt_at or 0)
    if gs.state == "BLIND_SELECT" then
      if game.blind_on_deck then
        add("select", {}, "选择当前盲注")
        if game.blind_on_deck ~= "Boss" then add("skip", {}, "跳过当前盲注, 获得标签") end
      end
      local cost = gs.round and gs.round.boss_reroll_cost
      if cost and cost <= money then add("reroll_boss", {}, "重掷 Boss, 费用 $" .. cost) end
      return result
    end
    local in_hand, in_shop, in_pack = gs.state == "SELECTING_HAND", gs.state == "SHOP", gs.state == "SMODS_BOOSTER_OPENED"
    if not in_hand and not in_shop and not in_pack then return result end
    local hand, hand_count = cards(g.hand), #cards(g.hand)
    for i, card in ipairs(hand) do
      if card.ability and card.ability.forced_selection then result.forced[#result.forced + 1] = i - 1 end
    end
    local function targets(card, field, source_config)
      local center = card.config and card.config.center or {}
      local req, err = deps.target_rules.requirements(center.key, source_config or center.config)
      if err then result.unsupported = true; return false end
      if req and req.requires_joker and #cards(g.jokers) == 0 then return false end
      if not req or not req.min then return nil end
      local indices = {}
      for i, target in ipairs(hand) do
        if not req.editionless or hidden(target) or not target.edition then indices[#indices + 1] = i - 1 end
      end
      if #indices < req.min or (not in_hand and not in_pack) then return false end
      return { field = field, min = req.min, max = math.min(req.max, #indices), indices = indices }
    end
    if in_hand and hand_count > 0 then
      local indices = {}; for i = 1, hand_count do indices[i] = i - 1 end
      local limit = math.min(g.hand.config.highlighted_limit or 5, hand_count)
      local target = { field = "cards", min = math.max(1, #result.forced), max = limit, indices = indices, forced = result.forced }
      if target.min <= target.max then
        if (gs.round and gs.round.hands_left or 0) > 0 then
          add("play", {}, "选择完整手牌组合出牌", { target = target,
            play_options = deps.hand_options and deps.hand_options.build(gs, target) or nil })
        end
        if (gs.round and gs.round.discards_left or 0) > 0 then add("discard", {}, "选择 1 至 " .. limit .. " 张手牌弃牌", { target = target }) end
      end
    end
    for _, item in ipairs({ { "jokers", "joker", g.jokers }, { "consumables", "consumable", g.consumeables } }) do
      for i, card in ipairs(cards(item[3])) do
        if predicate(card, "can_sell_card") then add("sell", { [item[2]] = i - 1 }, "出售 " .. item[1] .. "[" .. (i - 1) .. "]") end
        if item[1] == "consumables" and not hidden(card) then
          local target = targets(card, "cards", card.ability and card.ability.consumeable)
          local needs_space = card.config and card.config.center and card.config.center.key == "c_ankh"
            and #cards(g.jokers) >= (g.jokers and g.jokers.config.card_limit or 0)
          if target ~= false and not needs_space and (target or predicate(card, "can_use_consumeable", false, true)) then
            add("use", { consumable = i - 1 }, "使用 consumables[" .. (i - 1) .. "]", { target = target })
          end
        end
      end
    end
    for _, item in ipairs({ { "hand", g.hand }, { "jokers", g.jokers }, { "consumables", g.consumeables } }) do
      if #cards(item[2]) > 1 and (item[1] ~= "hand" or in_hand or in_pack) then
        add("rearrange", {}, "调整 " .. item[1] .. " 顺序", { move = { area = item[1], count = #cards(item[2]) } })
      end
    end
    if in_shop then
      for _, item in ipairs({ { "card", g.shop_jokers }, { "voucher", g.shop_vouchers }, { "pack", g.shop_booster } }) do
        for i, card in ipairs(cards(item[2])) do
          local ability, cost = card.ability or {}, card.cost or 0
          local affordable = cost <= 0 or cost <= money
          local room = ability.set == "Joker" and deps.slots.has_room(g.jokers, card)
            or ability.consumeable and deps.slots.has_room(g.consumeables, card)
            or (ability.set ~= "Joker" and not ability.consumeable)
          if affordable and room then add("buy", { [item[1]] = i - 1 }, "购买 " .. item[1] .. "[" .. (i - 1) .. "]") end
          if affordable and item[1] == "card" and ability.consumeable and not hidden(card)
            and predicate(card, "can_use_consumeable") and not (card.config.center.key == "c_ankh" and #cards(g.jokers) >= g.jokers.config.card_limit) then
            add("buy", { card = i - 1, use = true }, "买并使用 card[" .. (i - 1) .. "]")
          end
        end
      end
      local cost = gs.round and gs.round.reroll_cost
      if cost and (cost <= 0 or cost <= money) then add("reroll", {}, "刷新商店, 费用 $" .. cost) end
      add("next_round", {}, "离开商店, 进入下一轮")
    elseif in_pack then
      for i, card in ipairs(cards(g.pack_cards)) do
        local ability = card.ability or {}
        local target
        if not hidden(card) then target = targets(card, "targets") end
        local room = ability.set ~= "Joker" or deps.slots.has_room(g.jokers, card)
        if room and target ~= false and (not ability.consumeable or target or hidden(card) or predicate(card, "can_use_consumeable", false, true)) then
          add("pack", { card = i - 1 }, "选择 pack[" .. (i - 1) .. "]", { target = target })
        end
      end
      add("pack", { skip = true }, "跳过卡包")
    end
    return result
  end
  return build
end

return M
