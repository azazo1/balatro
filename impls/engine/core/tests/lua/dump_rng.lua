-- 用真 LuaJIT 复刻 Balatro 的 pseudorandom 状态机, 导出期望值供 Rust 对拍.
-- 这一份是"真值"来源: pseudohash / pseudoseed 的代码逐行抄自 game/functions/misc_functions.lua,
-- math.random 由本机 LuaJIT 提供.

local G = { GAME = { pseudorandom = {} } }

local function pseudohash(str)
  if true then
    local num = 1
    for i = #str, 1, -1 do
      num = ((1.1239285023 / num) * string.byte(str, i) * math.pi + math.pi * i) % 1
    end
    return num
  end
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

local function pseudoshuffle(list, seed)
  if seed then math.randomseed(seed) end
  if list[1] and list[1].sort_id then
    table.sort(list, function(a, b) return (a.sort_id or 1) < (b.sort_id or 2) end)
  end
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
end

local function f(x) return string.format("%.17g", x) end

-- 1. pseudohash
print("# pseudohash")
for _, s in ipairs({ "shuffleALEEB", "seedALEEB", "ALEEB", "jokerALEEB", "bossALEEB", "" }) do
  print("hash\t" .. s .. "\t" .. f(pseudohash(s)))
end

-- 2. pseudoseed 递推: 同一个 key 连续调用
print("# pseudoseed")
G.GAME.pseudorandom = {}
G.GAME.pseudorandom.seed = "ALEEB"
G.GAME.pseudorandom.hashed_seed = pseudohash("ALEEB")
for round = 1, 6 do
  print("shuffle\t" .. round .. "\t" .. f(pseudoseed("shuffle")))
end
for round = 1, 4 do
  print("joker\t" .. round .. "\t" .. f(pseudoseed("joker")))
end

-- 3. math.random 序列: 给定 seed 值
print("# random")
local seeds = { 0.0, 0.5, 1.0, 0.1234567, pseudohash("ALEEB") }
for _, s in ipairs(seeds) do
  math.randomseed(s)
  local parts = {}
  for i = 1, 5 do parts[#parts + 1] = f(math.random()) end
  print("double\t" .. f(s) .. "\t" .. table.concat(parts, "\t"))
end
for _, s in ipairs(seeds) do
  math.randomseed(s)
  local parts = {}
  for i = 1, 5 do parts[#parts + 1] = tostring(math.random(52)) end
  print("int52\t" .. f(s) .. "\t" .. table.concat(parts, "\t"))
end
for _, s in ipairs(seeds) do
  math.randomseed(s)
  local parts = {}
  for i = 1, 3 do parts[#parts + 1] = tostring(math.random(2, 7)) end
  print("range\t" .. f(s) .. "\t" .. table.concat(parts, "\t"))
end

-- 4. 轮子 (The Wheel) 的抽牌掷骰: 每抽一张牌掷一次 `pseudorandom(pseudoseed('wheel'))`.
--
-- 这一段要验的是**两件事**, 缺一不可:
--   a. 这一掷的数值与真 LuaJIT 一致;
--   b. 它会**消耗掉**全局随机数的位置 —— 所以"抽 8 张牌之后再掷别的键"得到的东西,
--      与"没抽过牌直接掷别的键"不同.
--
-- 只验 a 是不够的: 掷了但不消耗 (或消耗次数不对) 同样会让后面整条序列错位,
-- 而那种错误在数值上完全看不出来.
print("# wheel")
G.GAME.pseudorandom = {}
G.GAME.pseudorandom.seed = "ALEEB"
G.GAME.pseudorandom.hashed_seed = pseudohash("ALEEB")
local parts = {}
for i = 1, 8 do
  parts[#parts + 1] = f(pseudorandom(pseudoseed('wheel')))
end
print("cards8\t" .. table.concat(parts, "\t"))
-- 抽完这 8 张之后, 同一个键 `joker` 的第一次取值 (与下面"没抽过牌"那份对比).
print("after8\tjoker\t" .. f(pseudorandom(pseudoseed('joker'))))
print("after8\tboss\t" .. f(pseudorandom(pseudoseed('boss'))))

-- 对照组: 同样从 ALEEB 起步, 但**一次都不抽牌**.
G.GAME.pseudorandom = {}
G.GAME.pseudorandom.seed = "ALEEB"
G.GAME.pseudorandom.hashed_seed = pseudohash("ALEEB")
print("none\tjoker\t" .. f(pseudorandom(pseudoseed('joker'))))
print("none\tboss\t" .. f(pseudorandom(pseudoseed('boss'))))

-- 5. 完整链路: 洗一副 52 张牌
print("# shuffle")
G.GAME.pseudorandom = {}
G.GAME.pseudorandom.seed = "ALEEB"
G.GAME.pseudorandom.hashed_seed = pseudohash("ALEEB")
local deck = {}
for i = 1, 52 do deck[i] = { sort_id = i, key = "c" .. i } end
local seed1 = pseudoseed("shuffle")
pseudoshuffle(deck, seed1)
local order = {}
for i = 1, 52 do order[i] = deck[i].key end
print("deck\t" .. table.concat(order, ","))

local seed2 = pseudoseed("shuffle")
pseudoshuffle(deck, seed2)
local order2 = {}
for i = 1, 52 do order2[i] = deck[i].key end
print("deck2\t" .. table.concat(order2, ","))
