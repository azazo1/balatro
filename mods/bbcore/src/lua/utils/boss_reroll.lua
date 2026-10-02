--[[
导演剪辑版 / 重构: 选盲注时花 $10 重掷即将面对的 Boss.

纯逻辑, 不依赖游戏. 端点用来决定能不能点, 摘要用来决定要不要写出价格.
]]

local M = {}

M.COST = 10

---@param opts {used_vouchers: table?, boss_rerolled: boolean?}?
---@return boolean
function M.available(opts)
  opts = opts or {}
  local vouchers = opts.used_vouchers or {}
  if vouchers["v_retcon"] then
    return true
  end
  if vouchers["v_directors_cut"] and not opts.boss_rerolled then
    return true
  end
  return false
end

---@param opts {used_vouchers: table?, boss_rerolled: boolean?, dollars: number?, bankrupt_at: number?}?
---@return boolean, string?
function M.allowed(opts)
  opts = opts or {}
  if not M.available(opts) then
    if (opts.used_vouchers or {})["v_directors_cut"] then
      return false, "Cannot reroll boss: already used this ante"
    end
    return false, "Cannot reroll boss: need Director's Cut or Retcon"
  end
  local money = (opts.dollars or 0) - (opts.bankrupt_at or 0)
  if money < M.COST then
    return false,
      string.format(
        "Not enough dollars to reroll boss. Available: %s, Required: %s",
        tostring(money),
        tostring(M.COST)
      )
  end
  return true
end

return M
