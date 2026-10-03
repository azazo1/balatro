-- src/lua/endpoints/pack.lua

---@type BB_LOGGER
local BB_LOGGER = assert(SMODS.load_file("src/lua/utils/logger.lua"))()
local pack_wait = assert(SMODS.load_file("src/lua/utils/pack_wait.lua"))()
local slots = assert(SMODS.load_file("src/lua/utils/slots.lua"))()
local target_rules = assert(SMODS.load_file("src/lua/utils/target_rules.lua"))()

-- ==========================================================================
-- Pack Select Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.Pack.Params
---@field card integer? 0-based index of card to select from pack
---@field targets integer[]? 0-based indices of hand cards to target (for consumables requiring targets)
---@field skip boolean? Skip pack selection

-- ==========================================================================
-- Consumable Target Requirements
-- ==========================================================================

--- Get target requirements for a consumable card from G.P_CENTERS configuration
--- @param card_key string Card key (e.g., "c_magician")
--- @return table|nil { min = number, max = number } or { requires_joker = boolean } or nil if no requirements
local function get_consumable_target_requirements(card_key)
  local center = G.P_CENTERS[card_key]
  return target_rules.requirements(card_key, center and center.config)
end

--- 选完或跳过后等包稳定: 还能再选就留在包里, 否则等回到打开前的界面
--- (商店买的包回 SHOP, 跳过标签开的包回 BLIND_SELECT).
---@param send_response fun(response: Response.Endpoint)
---@param choices_before integer
---@param return_to any
---@param skipped boolean?
local function wait_pack_done(send_response, choices_before, return_to, skipped)
  G.E_MANAGER:add_event(Event({
    trigger = "condition",
    blocking = false,
    func = function()
      local result = pack_wait.after_pick({
        skip = skipped,
        choices_before = choices_before,
        choices_now = G.GAME.pack_choices or 0,
        pack_open = pack_wait.pack_open(G.pack_cards),
        state = G.STATE,
        return_to = return_to,
        state_complete = G.STATE_COMPLETE,
        states = G.STATES,
      })
      if result then
        sendDebugMessage("Return pack() after " .. result, "BB.ENDPOINTS")
        send_response(BB_GAMESTATE.get_gamestate())
        return true
      end
      return false
    end,
  }))
end

-- ==========================================================================
-- Pack Select Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "pack",

  description = "Select or skip a card from an opened booster pack",

  schema = {
    card = {
      type = "integer",
      required = false,
      description = "0-based index of card to select from pack",
    },
    targets = {
      type = "array",
      items = "integer",
      required = false,
      description = "0-based indices of hand cards to target (for consumables requiring targets)",
    },
    skip = {
      type = "boolean",
      required = false,
      description = "Skip pack selection",
    },
  },

  requires_state = { G.STATES.SMODS_BOOSTER_OPENED },

  ---@param args Request.Endpoint.Pack.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    sendDebugMessage("Init pack()", "BB.ENDPOINTS")

    -- Validate that exactly one of card or skip is provided
    local set = 0
    if args.card then
      set = set + 1
    end
    if args.skip then
      set = set + 1
    end

    if set == 0 then
      send_response({
        message = "Invalid arguments. You must provide one of: card, skip",
        name = BB_ERROR_NAMES.BAD_REQUEST,
      })
      return
    end

    if set > 1 then
      send_response({
        message = "Invalid arguments. Cannot provide both card and skip",
        name = BB_ERROR_NAMES.BAD_REQUEST,
      })
      return
    end

    -- Validate pack_cards exists
    if not G.pack_cards or G.pack_cards.REMOVED then
      send_response({
        message = "No pack is currently open",
        name = BB_ERROR_NAMES.INVALID_STATE,
      })
      return
    end

    -- Helper function to perform card selection and handle response
    local function select_card()
      local pos = args.card + 1

      -- Validate card index is in range
      if not G.pack_cards.cards[pos] then
        local pack_count = G.pack_cards.config and G.pack_cards.config.card_count or 0
        send_response({
          message = "Card index out of range. Index: " .. args.card .. ", Available cards: " .. pack_count,
          name = BB_ERROR_NAMES.BAD_REQUEST,
        })
        return true
      end
      local card = G.pack_cards.cards[pos]
      local card_key = card.config and card.config.center and card.config.center.key

      -- Check if card is a Joker and validate that we have room
      -- 本仓库修改: 按游戏的规则算空位 (utils/slots.lua), 负片自带一格, 槽满时也能选.
      if card.ability and card.ability.set == "Joker" then
        local joker_count = G.jokers and G.jokers.config and G.jokers.config.card_count or 0
        local joker_limit = G.jokers and G.jokers.config and G.jokers.config.card_limit or 0
        if not slots.has_room(G.jokers, card) then
          send_response({
            message = "Cannot select joker, joker slots are full. Current: "
              .. joker_count
              .. ", Limit: "
              .. joker_limit,
            name = BB_ERROR_NAMES.NOT_ALLOWED,
          })
          return true
        end
      end

      -- Validate consumable target requirements
      if card_key then
        local req, target_error = get_consumable_target_requirements(card_key)
        if target_error then send_response({ message = target_error, name = BB_ERROR_NAMES.NOT_ALLOWED }); return true end
        if req then
          -- Check joker requirement for cards like Ankh
          if req.requires_joker then
            local joker_count = G.jokers and G.jokers.config and G.jokers.config.card_count or 0
            if joker_count == 0 then
              send_response({
                message = string.format("Card '%s' requires at least 1 joker. Current: %d", card_key, joker_count),
                name = BB_ERROR_NAMES.NOT_ALLOWED,
              })
              return true
            end
          end

          -- Check target card requirements
          local target_count = args.targets and #args.targets or 0
          if req.min and req.max and (target_count < req.min or target_count > req.max) then
            local msg
            if req.min == req.max then
              msg = string.format(
                "Card '%s' requires exactly %d target card(s). Provided: %d",
                card_key,
                req.min,
                target_count
              )
            else
              msg = string.format(
                "Card '%s' requires %d-%d target card(s). Provided: %d",
                card_key,
                req.min,
                req.max,
                target_count
              )
            end
            send_response({
              message = msg,
              name = BB_ERROR_NAMES.BAD_REQUEST,
            })
            return true
          end

          -- Highlight the target cards in hand
          if args.targets and #args.targets > 0 then
            -- Clear existing highlights using proper CardArea method
            for i = #G.hand.highlighted, 1, -1 do
              G.hand:remove_from_highlighted(G.hand.highlighted[i], true)
            end

            -- Highlight target cards using proper CardArea method
            for _, target_idx in ipairs(args.targets) do
              local hand_pos = target_idx + 1 -- Convert 0-based to 1-based
              if not G.hand.cards[hand_pos] then
                send_response({
                  message = "Target card index out of range. Index: " .. target_idx .. ", Hand size: " .. #G.hand.cards,
                  name = BB_ERROR_NAMES.BAD_REQUEST,
                })
                return true
              end
              G.hand:add_to_highlighted(G.hand.cards[hand_pos], true)
            end
          end
        end
      end

      -- 本仓库修改: 卡包里直接使用的消耗牌 (塔罗, 星球, 幻灵) 按原版 "使用" 按钮的条件检查, 例如命运之轮
      -- 没有能加版本的小丑, 审判没有空的小丑槽时按钮是灰的. 选进槽位的牌 (selectable_from_pack) 不是 "使用", 不查.
      -- skip_check 跳过动画中的锁: 那只影响按钮能不能点的时机, 接口调用前已等动画停下.
      local select_to = booster_obj and card.selectable_from_pack and card:selectable_from_pack(booster_obj)
      if card.ability and card.ability.consumeable and not select_to and not card:can_use_consumeable(false, true) then
        if G.hand then
          for i = #G.hand.highlighted, 1, -1 do
            G.hand:remove_from_highlighted(G.hand.highlighted[i], true)
          end
        end
        send_response({
          message = "Card '" .. tostring(card_key) .. "' cannot be used now (the game's Use button is disabled for it)",
          name = BB_ERROR_NAMES.NOT_ALLOWED,
        })
        return true
      end

      -- Log what we're selecting
      local card_name = card.ability and card.ability.name or "Unknown"
      local card_set = card.ability and card.ability.set or card.set or "card"
      if args.targets and #args.targets > 0 then
        local targets = BB_LOGGER.format_playing_cards(G.hand.cards, args.targets)
        sendDebugMessage(
          string.format("Pack: selecting %s '%s' targeting: %s", card_set, card_name, targets),
          "BB.ENDPOINTS"
        )
      else
        sendDebugMessage(string.format("Pack: selecting %s '%s'", card_set, card_name), "BB.ENDPOINTS")
      end

      -- Select the card by calling use_card
      local btn = {
        config = {
          ref_table = card,
        },
      }

      local pack_choices_before = G.GAME.pack_choices or 0
      local return_to = G.GAME.PACK_INTERRUPT

      G.FUNCS.use_card(btn)
      wait_pack_done(send_response, pack_choices_before, return_to)

      return true
    end

    -- Handle skip
    if args.skip then
      local pack_count = G.pack_cards.config and G.pack_cards.config.card_count or 0
      sendDebugMessage(string.format("Pack: skipping (%d cards remaining)", pack_count), "BB.ENDPOINTS")
      local return_to = G.GAME.PACK_INTERRUPT
      G.FUNCS.skip_booster({})
      wait_pack_done(send_response, 1, return_to, true)
      return
    end

    -- Wait for hand cards to load for Arcana and Spectral packs
    local pack_key = G.pack_cards
      and G.pack_cards.cards
      and G.pack_cards.cards[1]
      and G.pack_cards.cards[1].ability
      and G.pack_cards.cards[1].ability.set
    local needs_hand = pack_key == "Tarot" or pack_key == "Spectral"

    if needs_hand then
      -- Wait for hand cards to be fully loaded and positioned
      local selection_executed = false -- Flag to ensure we only execute once

      G.E_MANAGER:add_event(Event({
        trigger = "condition",
        blocking = false,
        func = function()
          -- Wait for state transition to complete (ensures hand is fully dealt)
          if not G.STATE_COMPLETE then
            return false
          end

          -- Calculate expected hand size for initial load
          -- After cards are destroyed (mega packs), hand may have fewer cards
          local hand_limit = G.hand.config and G.hand.config.card_limit or 8
          local deck_size = G.deck and G.deck.config and G.deck.config.card_count or 52
          local expected_hand_size = math.min(deck_size, hand_limit)

          -- Calculate minimum required cards based on target indices
          local min_required = 1
          if args.targets and #args.targets > 0 then
            for _, target_idx in ipairs(args.targets) do
              local required = target_idx + 1 -- 0-based to 1-based
              if required > min_required then
                min_required = required
              end
            end
          end

          -- Wait for hand to be ready:
          -- - At least expected_hand_size cards (initial load), OR
          -- - At least min_required cards (for mega packs after cards destroyed)
          local hand_ready = G.hand
            and not G.hand.REMOVED
            and G.hand.cards
            and (#G.hand.cards >= expected_hand_size or #G.hand.cards >= min_required)
            and G.hand.T -- Table area exists
            and G.hand.T.x -- Positioned

          -- Also check that cards are actually positioned in the hand
          local cards_positioned = hand_ready and G.hand.cards[1] and G.hand.cards[1].T and G.hand.cards[1].T.x

          -- Early return to ensure hand is ready before target index validation
          if not hand_ready or not cards_positioned then
            return false
          end

          -- Validate target index is in range if targets are provided
          if args.targets then
            for _, target_idx in ipairs(args.targets) do
              local hand_pos = target_idx + 1
              if not G.hand.cards[hand_pos] then
                send_response({
                  message = "Target card index out of range. Index: " .. target_idx .. ", Hand size: " .. #G.hand.cards,
                  name = BB_ERROR_NAMES.BAD_REQUEST,
                })
                return
              end
            end
          end

          -- Validate that all target card indices exist in hand
          local all_targets_exist = true
          if args.targets and #args.targets > 0 then
            for _, target_idx in ipairs(args.targets) do
              local hand_pos = target_idx + 1 -- Convert 0-based to 1-based
              if not G.hand.cards[hand_pos] then
                all_targets_exist = false
                break
              end
            end
          end

          if all_targets_exist and not selection_executed then
            selection_executed = true -- Mark as executed to prevent re-running
            return select_card()
          end

          return false
        end,
      }))
      return
    else
      -- Handle card selection for packs that don't need hand (e.g., Buffoon, Celestial, Standard)
      select_card()
    end
  end,
}
