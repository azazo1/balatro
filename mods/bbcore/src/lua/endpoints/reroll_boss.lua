-- src/lua/endpoints/reroll_boss.lua

local boss_reroll = assert(BB_BOSS_REROLL, "BB_BOSS_REROLL not loaded")
local pack_wait = assert(SMODS.load_file("src/lua/utils/pack_wait.lua"))()

-- ==========================================================================
-- Reroll Boss Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.RerollBoss.Params

-- ==========================================================================
-- Reroll Boss Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "reroll_boss",

  description = "Reroll the upcoming Boss blind for $10 (requires Director's Cut or Retcon)",

  schema = {},

  requires_state = { G.STATES.BLIND_SELECT },

  ---@param _ Request.Endpoint.RerollBoss.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    local game = G.GAME
    local ok, message = boss_reroll.allowed({
      used_vouchers = game and game.used_vouchers,
      boss_rerolled = game and game.round_resets and game.round_resets.boss_rerolled,
      dollars = game and game.dollars,
      bankrupt_at = game and game.bankrupt_at,
    })
    if not ok then
      sendDebugMessage("reroll_boss() not allowed: " .. tostring(message), "BB.ENDPOINTS")
      send_response({
        message = message,
        name = BB_ERROR_NAMES.NOT_ALLOWED,
      })
      return
    end

    if not (G.blind_select_opts and G.blind_select_opts.boss) then
      send_response({
        message = "Boss pane is not available",
        name = BB_ERROR_NAMES.NOT_ALLOWED,
      })
      return
    end

    sendDebugMessage(
      string.format("Rerolling boss (cost=$%d, money=$%s)", boss_reroll.COST, tostring(game and game.dollars)),
      "BB.ENDPOINTS"
    )
    G.FUNCS.reroll_boss(nil)

    -- 游戏先锁 boss_reroll, 滑走旧 Boss 再换新的. 待处理的开包标签也可能在这里打开补充包.
    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      func = function()
        local locks = G.CONTROLLER and G.CONTROLLER.locks
        local result = pack_wait.reroll_boss_done({
          state = G.STATE,
          states = G.STATES,
          locked = locks and locks.boss_reroll,
          pane = G.blind_select_opts and G.blind_select_opts.boss ~= nil,
          pack_open = pack_wait.pack_open(G.pack_cards),
          state_complete = G.STATE_COMPLETE,
          booster_pack = G.booster_pack and not G.booster_pack.REMOVED,
          pack_interrupt = G.GAME.PACK_INTERRUPT,
          locks = locks,
        })
        if result then
          sendDebugMessage("Return reroll_boss() after " .. result, "BB.ENDPOINTS")
          send_response(BB_GAMESTATE.get_gamestate())
          return true
        end
        return false
      end,
    }))
  end,
}
