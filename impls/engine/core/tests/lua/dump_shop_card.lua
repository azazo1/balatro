-- 用真 LuaJIT 复刻"商店铺一格"的掷骰顺序, 导出期望值供 Rust 对拍.
--
-- 这一段复刻的是 `UI_definitions.lua` 里 create_shop_card 那段 + `create_card` 里
-- 与扑克牌有关的那几支. 顺序逐行照源码抄, 不"化简".
--
-- 重点在幻象券 (v_illusion): 它引入三次 `illusion` 掷骰, 而其中**第一次是在构造那张权重表时
-- 就发生的** (Lua 的 table constructor 会先整个求值再交给 ipairs) —— 所以哪怕这一格最后
-- 是张小丑, 那一掷也已经花掉了. 位置写错的话, "下一格扑克牌是不是强化牌"会跟着变.

local G = { GAME = { pseudorandom = {} } }

local function pseudohash(str)
  local num = 1
  for i = #str, 1, -1 do
    num = ((1.1239285023 / num) * string.byte(str, i) * math.pi + math.pi * i) % 1
  end
  return num
end

local function pseudoseed(key)
  if key == 'seed' then return math.random() end
  if not G.GAME.pseudorandom[key] then
    G.GAME.pseudorandom[key] = pseudohash(key .. (G.GAME.pseudorandom.seed or ''))
  end
  G.GAME.pseudorandom[key] = math.abs(tonumber(string.format("%.13f", (2.134453429141 + G.GAME.pseudorandom[key] * 1.72431234) % 1)))
  return (G.GAME.pseudorandom[key] + (G.GAME.pseudorandom.hashed_seed or 0)) / 2
end

local function pseudorandom(seed, min, max)
  if type(seed) == 'string' then seed = pseudoseed(seed) end
  math.randomseed(seed)
  if min and max then return math.random(min, max)
  else return math.random() end
end

local function f(x) return string.format("%.17g", x) end

-- 连铺 N 格: **不要每格重置随机状态** —— 真实的一面试图就是这样一路铺下来的, 而 illusion
-- 这个键的计数正是跨格累积的 (所以第 2、3 格的强化判定与第 1 格不同).
local function shelf(seed, ante, total, lo, hi, illusion, slots)
  G.GAME.pseudorandom = {}
  G.GAME.pseudorandom.seed = seed
  G.GAME.pseudorandom.hashed_seed = pseudohash(seed)

  local out, illusion_rolls = {}, 0
  for slot_index = 1, slots do
    -- 1. 这一格是什么类型.
    local polled = pseudorandom(pseudoseed('cdt'..ante)) * total
    -- 2. 权重表构造时的那一掷 (只有幻象券在场才有).
    local table_roll = nil
    if illusion then
      table_roll = pseudorandom(pseudoseed('illusion'))
      illusion_rolls = illusion_rolls + 1
    end
    local is_card = polled > lo and polled <= hi
    local enhanced = is_card and illusion and table_roll > 0.6
    -- 3. 强化牌抽一次 Enhanced 池; 基础牌不抽.
    if enhanced then
      out[#out+1] = "s"..slot_index.."_pool\t" .. f(pseudorandom(pseudoseed('Enhancedsho'..ante)))
    end
    -- 4. 牌面 (只有扑克牌那一格会抽).
    if is_card then
      out[#out+1] = "s"..slot_index.."_front\t" .. f(pseudorandom(pseudoseed('frontsho'..ante)))
    end
    -- 5. 版本: 幻象券在场、且这一格是扑克牌时两掷.
    if is_card and illusion then
      out[#out+1] = "s"..slot_index.."_want\t" .. f(pseudorandom(pseudoseed('illusion')))
      out[#out+1] = "s"..slot_index.."_which\t" .. f(pseudorandom(pseudoseed('illusion')))
      illusion_rolls = illusion_rolls + 2
    end
    out[#out+1] = "s"..slot_index.."\tcard="..tostring(is_card).."\tenhanced="..tostring(enhanced)
  end
  out[#out+1] = "illusion_rolls\t" .. illusion_rolls
  return out
end

print("# shop_card")
-- 种子的挑法: SEED2 的 illusion 序列一开始就超过 0.6 (强化牌那一支), ALEEB 一直在 0.6 以下
-- (基础牌那一支). 两支都要有 case, 否则"强化牌那半边"等于没对拍.
for _, row in ipairs({
  {"ALEEB", 1, 28.0, 24.0, 28.0, false, 4},
  {"ALEEB", 1, 28.0, 24.0, 28.0, true, 4},
  {"ALEEB", 1, 28.0, 0.0, 28.0, true, 6},
  {"SEED2", 1, 28.0, 0.0, 28.0, true, 6},
  {"SEED3", 2, 28.0, 0.0, 28.0, true, 6},
  {"12345", 3, 28.0, 0.0, 28.0, true, 6},
}) do
  local lines = shelf(row[1], row[2], row[3], row[4], row[5], row[6], row[7])
  -- 表头字段: 种子, 底注, 总权重, 扑克牌那一档的区间, 是否开幻象券, 铺几格.
  print("case\t" .. row[1] .. "\t" .. row[2] .. "\t" .. row[3] .. "\t" .. row[4] .. "\t"
        .. row[5] .. "\t" .. tostring(row[6]) .. "\t" .. row[7])
  for _, line in ipairs(lines) do print(line) end
  print("--")
end
