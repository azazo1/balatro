-- LLM 与 Decision 共用的稳定阶段和自动步骤判断.
local M = {}
M.STABLE = { MENU = true, BLIND_SELECT = true, SELECTING_HAND = true, SHOP = true, SMODS_BOOSTER_OPENED = true }

function M.new(deps)
  local observed, since = nil, 0
  local lifecycle = {}
  function lifecycle.reset() observed, since = nil, 0 end
  function lifecycle.next()
    if deps.busy() then return { kind = "wait" } end
    local overlay = deps.overlay()
    if overlay ~= observed then observed, since = overlay, deps.now() end
    if (overlay == "unlock" or overlay == "win") and deps.now() - since < (deps.overlay_hold or 0) then
      return { kind = "wait", detail = overlay }
    end
    if overlay == "unlock" then return { kind = "auto", method = "continue", note = "关掉了解锁通知" }
    elseif overlay == "win" then
      if deps.config().after_win == "endless" then return { kind = "auto", method = "endless", note = "赢下本局, 进入无尽模式" } end
      return { kind = "auto", method = "menu", note = "赢下本局, 回主菜单", result = "win" }
    elseif overlay then return { kind = "wait", detail = overlay } end
    local gs = deps.gamestate()
    if gs.state == "GAME_OVER" then return { kind = "auto", method = "menu", note = "本局失败, 回主菜单", result = "lose" }
    elseif gs.state == "ROUND_EVAL" then
      return { kind = "auto", method = "cash_out", note = string.format("第 %s 回合结算, 进入商店", tostring(gs.round_num)) }
    elseif not M.STABLE[gs.state] then return { kind = "wait", detail = gs.state } end
    return { kind = "stable", gamestate = gs }
  end
  return lifecycle
end

return M
