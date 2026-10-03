-- 卡包与消耗牌共用的目标数量规则, 不依赖游戏或选牌副作用.
local M = {}

function M.requirements(key, config)
  if key == "c_aura" then return { min = 1, max = 1, editionless = true } end
  if key == "c_ankh" then return { requires_joker = true } end
  config = config or {}
  if config.max_highlighted == nil then return nil end
  local min, max = config.min_highlighted or 1, config.max_highlighted
  if type(min) ~= "number" or type(max) ~= "number" or min < 1 or max < min
    or min ~= math.floor(min) or max ~= math.floor(max) or max == math.huge then
    return nil, "卡牌目标数量规则无效"
  end
  return { min = min, max = max }
end

return M
