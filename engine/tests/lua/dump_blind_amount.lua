-- 用真 LuaJIT 算一遍 `get_blind_amount` (赌注三档), 输出供 Rust 侧对拍.
--
-- 每行: 底注 \t 档1 \t 档2 \t 档3
-- 数值按**十六进制浮点**打印 (`%a`), 因为高底注下这些数大到 `%.17g` 也不够看,
-- 而十六进制是逐位精确的 —— 对拍要的是"一模一样", 不是"看起来差不多".
-- 底注 40 起两边都会得到 `nan` (指数溢出), 那不是错, 是游戏本身的行为, 照样要一致.
math.randomseed(1)
local function amount_for(ante, amounts)
  local k = 0.75
  if ante < 1 then return 100 end
  if ante <= 8 then return amounts[ante] end
  local a, b, c, d = amounts[8], 1.6, ante - 8, 1 + 0.2 * (ante - 8)
  local amount = math.floor(a * (b + (k * c) ^ d) ^ c)
  amount = amount - amount % (10 ^ math.floor(math.log10(amount) - 1))
  return amount
end
local tables = {
  {300, 800, 2000, 5000, 11000, 20000, 35000, 50000},
  {300, 900, 2600, 8000, 20000, 36000, 60000, 100000},
  {300, 1000, 3200, 9000, 25000, 60000, 110000, 200000},
}
local antes = {-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 26,
               28, 30, 32, 34, 35, 36, 37, 38, 39, 40, 41, 45, 50, 60, 80, 100, 200}
for _, ante in ipairs(antes) do
  local parts = {tostring(ante)}
  for i = 1, 3 do
    parts[#parts + 1] = string.format("%a", amount_for(ante, tables[i]))
  end
  print(table.concat(parts, "\t"))
end
