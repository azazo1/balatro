--[[
本仓库新增: 买进或选入一张小丑/消耗牌时, 持有区还放不放得下.

照抄游戏的判断 (Steamodded 改过的 G.FUNCS.check_for_buy_space 与 can_select_card, 见
mods/Steamodded/lovely/edition.toml 与 booster.toml), 但不弹 "没有空间" 的提示:
牌数 + 1 + 这张牌额外占的槽 <= 区域上限 + 这张牌自带的槽.
负片的 ability.card_limit 为 1, 所以槽满时负片仍放得下. 以前端点只比 count >= limit, 把负片拒掉了.
]]

local M = {}

---@param area table? CardArea (G.jokers / G.consumeables)
---@param card table? Card
---@return boolean
function M.has_room(area, card)
  if not area or not area.cards or not area.config then
    return false
  end
  local ability = card and card.ability or {}
  local own = tonumber(ability.card_limit) or 0
  local used = tonumber(ability.extra_slots_used) or 0
  local limit = tonumber(area.config.card_limit) or 0
  return #area.cards + 1 + used <= limit + own
end

return M
