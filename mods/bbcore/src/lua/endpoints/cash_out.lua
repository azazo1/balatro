-- src/lua/endpoints/cash_out.lua

-- ==========================================================================
-- CashOut Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.CashOut.Params

-- ==========================================================================
-- CashOut Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "cash_out",

  description = "Cash out and collect round rewards",

  schema = {},

  requires_state = { G.STATES.ROUND_EVAL },

  ---@param _ Request.Endpoint.CashOut.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    sendDebugMessage("Init cash_out()", "BB.ENDPOINTS")

    -- 结算界面是逐行弹出的, `add_round_eval_row` 每写一行就覆盖一次
    -- `G.GAME.current_round.dollars` (common_events.lua), 只有最后一行 `bottom` 写的才是合计.
    -- `G.FUNCS.cash_out` 一进去就 `ease_dollars(current_round.dollars)`, 所以要等结算栏写完
    -- 才能领, 否则领到的是中间某一行的值 (实测大盲注会少领 `$5`).
    -- `cash_out_button` 出现就代表最后一行已经写完, 与 play 端点用的是同一个信号.
    local settled = function()
      if not G.round_eval then
        return false
      end
      for _, box in ipairs(G.I.UIBOX) do
        if box:get_UIE_by_ID("cash_out_button") then
          return true
        end
      end
      return false
    end

    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      func = function()
        if not settled() then
          return false
        end
        G.FUNCS.cash_out({ config = {} })
        return true
      end,
    }))

    local num_items = function(area)
      local count = 0
      if area and area.cards then
        for _, v in ipairs(area.cards) do
          if v.children.buy_button and v.children.buy_button.definition then
            count = count + 1
          end
        end
      end
      return count
    end

    -- Wait for SHOP state after state transition completes
    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      func = function()
        local done = false
        if G.STATE == G.STATES.SHOP and G.STATE_COMPLETE then
          done = num_items(G.shop_booster) > 0 or num_items(G.shop_jokers) > 0 or num_items(G.shop_vouchers) > 0
          if done then
            sendDebugMessage("Return cash_out() - reached SHOP state", "BB.ENDPOINTS")
            send_response(BB_GAMESTATE.get_gamestate())
            return done
          end
        end
        return done
      end,
    }))
  end,
}
