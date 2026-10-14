--[[
纯 Lua 的 bit 模块, 语义对齐 LuaJIT 的 BitOp (32 位有符号结果).
love.js 使用 PUC Lua 5.1, 没有内置 bit 库, 游戏的 pseudohash 依赖它产生与桌面版一致的种子.
]]

local floor = math.floor
local TWO32 = 4294967296
local TWO31 = 2147483648

local M = {}

-- 归一化到 [0, 2^32) 的无符号整数. LuaJIT 对非整数按最近偶数取整.
local function u32(x)
    x = tonumber(x) or 0
    if x ~= floor(x) then
        local f = floor(x)
        local d = x - f
        if d > 0.5 or (d == 0.5 and f % 2 == 1) then f = f + 1 end
        x = f
    end
    return x % TWO32
end

local function s32(x)
    if x >= TWO31 then return x - TWO32 end
    return x
end

function M.tobit(x) return s32(u32(x)) end

-- 逐 4 位查表实现与或异或, 避免逐位循环过慢.
local AND, OR, XOR = {}, {}, {}
for a = 0, 15 do
    AND[a], OR[a], XOR[a] = {}, {}, {}
    for b = 0, 15 do
        local r_and, r_or, r_xor, bit_v = 0, 0, 0, 1
        local x, y = a, b
        for _ = 1, 4 do
            local xa, yb = x % 2, y % 2
            if xa == 1 and yb == 1 then r_and = r_and + bit_v end
            if xa == 1 or yb == 1 then r_or = r_or + bit_v end
            if xa ~= yb then r_xor = r_xor + bit_v end
            x, y, bit_v = (x - xa) / 2, (y - yb) / 2, bit_v * 2
        end
        AND[a][b], OR[a][b], XOR[a][b] = r_and, r_or, r_xor
    end
end

local function op2(tbl, a, b)
    a, b = u32(a), u32(b)
    local r, m = 0, 1
    for _ = 1, 8 do
        local na, nb = a % 16, b % 16
        r = r + tbl[na][nb] * m
        a, b, m = (a - na) / 16, (b - nb) / 16, m * 16
    end
    return r
end

local function fold(tbl, a, b, ...)
    local r = op2(tbl, a, b)
    for i = 1, select("#", ...) do r = op2(tbl, r, (select(i, ...))) end
    return s32(r)
end

function M.band(a, b, ...) if b == nil then return M.tobit(a) end return fold(AND, a, b, ...) end
function M.bor(a, b, ...) if b == nil then return M.tobit(a) end return fold(OR, a, b, ...) end
function M.bxor(a, b, ...) if b == nil then return M.tobit(a) end return fold(XOR, a, b, ...) end
function M.bnot(a) return s32(TWO32 - 1 - u32(a)) end

function M.lshift(a, n)
    n = u32(n) % 32
    return s32((u32(a) * 2 ^ n) % TWO32)
end

function M.rshift(a, n)
    n = u32(n) % 32
    return s32(floor(u32(a) / 2 ^ n))
end

function M.arshift(a, n)
    n = u32(n) % 32
    local v = s32(u32(a))
    return s32(u32(floor(v / 2 ^ n)))
end

function M.rol(a, n)
    n = u32(n) % 32
    local v = u32(a)
    return s32((v * 2 ^ n) % TWO32 + floor(v / 2 ^ (32 - n)))
end

function M.ror(a, n) return M.rol(a, 32 - (u32(n) % 32)) end

function M.bswap(a)
    local v = u32(a)
    local b0, b1, b2, b3 = v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216)
    return s32(((b0 * 256 + b1) * 256 + b2) * 256 + b3)
end

function M.tohex(a, n)
    n = n or 8
    local upper = n < 0
    if upper then n = -n end
    local s = string.format(upper and "%08X" or "%08x", u32(a))
    return s:sub(-n)
end

return M
