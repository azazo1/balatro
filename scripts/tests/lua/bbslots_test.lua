-- 持有区空位判断, 用 luajit 在仓库根目录运行: just test-agent
-- 照游戏的规则算: 负片自带一格, 槽满时仍放得下; 普通牌在槽满时放不下.

local Slots = dofile("mods/bbcore/src/lua/utils/slots.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function area(count, limit)
  local cards = {}
  for i = 1, count do
    cards[i] = {}
  end
  return { cards = cards, config = { card_limit = limit } }
end

-- Steamodded 的 set_edition 把 edition.card_limit (负片为 1) 加到 ability.card_limit 上
local plain = { ability = { card_limit = 0, extra_slots_used = 0 } }
local negative = { ability = { card_limit = 1, extra_slots_used = 0 } }

check("有空位时普通牌放得下", Slots.has_room(area(1, 2), plain))
check("槽满时普通牌放不下", not Slots.has_room(area(2, 2), plain))
check("槽满时负片放得下", Slots.has_room(area(2, 2), negative))
check("超出一格后负片也放不下", not Slots.has_room(area(3, 2), negative))
check("额外占槽的牌要多一格", not Slots.has_room(area(1, 2), { ability = { card_limit = 0, extra_slots_used = 1 } }))
check("缺 ability 字段按普通牌算", not Slots.has_room(area(2, 2), {}) and Slots.has_room(area(1, 2), {}))
check("区域不存在时放不下", not Slots.has_room(nil, plain))

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
