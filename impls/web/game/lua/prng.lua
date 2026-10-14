--[[
纯 Lua 复刻 LuaJIT 2.1 的 math.random / math.randomseed (TW223, 见 lj_prng.c 与 lib_math.c).
love.js 是 PUC Lua 5.1, math.random 走 C 的 rand(), 同一种子抽出的牌与桌面版不同.
64 位状态拆成 hi/lo 两个 32 位无符号数, 运算全部保持在 double 能精确表示的范围内.
]]

local floor, frexp = math.floor, math.frexp
local P32 = 4294967296

-- 32 位无符号异或: 逐 4 位查表.
local XOR = {}
for a = 0, 15 do
    XOR[a] = {}
    for b = 0, 15 do
        local r, v, x, y = 0, 1, a, b
        for _ = 1, 4 do
            local xa, yb = x % 2, y % 2
            if xa ~= yb then r = r + v end
            x, y, v = (x - xa) / 2, (y - yb) / 2, v * 2
        end
        XOR[a][b] = r
    end
end

local function xor32(a, b)
    local r, m = 0, 1
    for _ = 1, 8 do
        local na, nb = a % 16, b % 16
        r = r + XOR[na][nb] * m
        a, b, m = (a - na) / 16, (b - nb) / 16, m * 16
    end
    return r
end

local function shl(hi, lo, n)
    if n == 0 then return hi, lo end
    if n >= 32 then return (lo % 2 ^ (64 - n)) * 2 ^ (n - 32), 0 end
    local k = 2 ^ (32 - n)
    return (hi % k) * 2 ^ n + floor(lo / k), (lo % k) * 2 ^ n
end

local function shr(hi, lo, n)
    if n == 0 then return hi, lo end
    if n >= 32 then return 0, floor(hi / 2 ^ (n - 32)) end
    local p = 2 ^ n
    return floor(hi / p), floor(lo / p) + (hi % p) * 2 ^ (32 - n)
end

-- 状态: u[1..4] 各为 {hi, lo}.
local u = {
    { 0xa0d27757, 0x0a345b8c },
    { 0x764a296c, 0x5d4aa64f },
    { 0x51220704, 0x070adeaa },
    { 0x2a2717b5, 0xa7b7b927 },
}
-- (k, q, s), 与 lj_prng.c 的 TW223_GEN 一致.
local STEPS = { { 63, 31, 18 }, { 58, 19, 28 }, { 55, 24, 7 }, { 47, 21, 8 } }

local function next_u64()
    local rh, rl = 0, 0
    for i = 1, 4 do
        local st = STEPS[i]
        local k, q, s = st[1], st[2], st[3]
        local zh, zl = u[i][1], u[i][2]
        -- ((z << q) ^ z) >> (k - s)
        local ah, al = shl(zh, zl, q)
        ah, al = shr(xor32(ah, zh), xor32(al, zl), k - s)
        -- (z & (~0 << (64 - k))) << s
        local bh, bl = shr(zh, zl, 64 - k)
        bh, bl = shl(bh, bl, 64 - k)
        bh, bl = shl(bh, bl, s)
        zh, zl = xor32(ah, bh), xor32(al, bl)
        u[i][1], u[i][2] = zh, zl
        rh, rl = xor32(rh, zh), xor32(rl, zl)
    end
    return rh, rl
end

-- 取低 52 位, 拼成 [1, 2) 的 double 再减 1.
local function random01()
    local hi, lo = next_u64()
    return ((hi % 1048576) * P32 + lo) / 4503599627370496
end

-- double 的 IEEE 754 位模式, 返回 hi, lo.
local function double_bits(d)
    if d ~= d then return 0x7ff80000, 0 end
    local sign = 0
    if d < 0 or (d == 0 and 1 / d < 0) then sign, d = 0x80000000, -d end
    if d == 0 then return sign, 0 end
    if d == math.huge then return sign + 0x7ff00000, 0 end
    local m, e = frexp(d) -- d = m * 2^e, m 在 [0.5, 1)
    local expo = e + 1022
    local mant
    if expo <= 0 then -- 次正规数
        mant = m * 2 ^ (52 + expo)
        expo = 0
    else
        mant = (m * 2 - 1) * 4503599627370496
    end
    return sign + expo * 1048576 + floor(mant / P32), mant % P32
end

local PI, E = math.pi, math.exp(1)

local function randomseed(d)
    d = tonumber(d) or os.time()
    local r = 0x11090601
    for i = 1, 4 do
        local mbit = r % 256
        r = floor(r / 256)
        d = d * PI + E
        local hi, lo = double_bits(d)
        -- bits < (1 << mbit) 时补上 1 << mbit. mbit 只会是 1/6/9/17, 都在低 32 位.
        local m = 2 ^ mbit
        if hi == 0 and lo < m then lo = lo + m end
        u[i][1], u[i][2] = hi, lo
    end
    for _ = 1, 10 do next_u64() end
end

-- 与 LuaJIT 2.1 的 math_random 相同: 参数不取整, 也不检查区间是否为空.
local function random(m, n)
    local r = random01()
    if m == nil then return r end
    m = tonumber(m)
    if n == nil then return floor(r * m) + 1 end
    n = tonumber(n)
    return floor(r * (n - m + 1)) + m
end

return { random = random, randomseed = randomseed, double_bits = double_bits }
