-- 用真 LuaJIT 的 table.sort 排一批"有重号"的序列, 输出结果供 Rust 侧对拍.
--
-- 每行: 键序列 \t 排完之后各位置**取自原来的第几个** (都是 1 基, 逗号分隔)
--
-- 为什么输出下标而不是值: `table.sort` 不稳定, 键相同的两个元素谁排前面由交换过程决定,
-- 而只记值的话它们长得**一模一样**, 这半边就根本没被记下来. 排的是下标数组, 比较函数只看键,
-- 下标于是成了身份 —— 输出里 `5,5,5` 到底是 `{1,3,5}` 还是 `{5,3,1}` 一目了然.
-- 值域故意开小 (1..3), 好让"比较函数说相等"的元素频繁出现.
math.randomseed(20261004)
local cases = {}
-- 手工局面: 全相同 / 交替 / 已排好 / 逆序 / 一个重复的大头
cases[#cases+1] = {5,5,5,5,5}
cases[#cases+1] = {5,5,5,5,5,5,5,5}
cases[#cases+1] = {5,3,5,3,5,3}
cases[#cases+1] = {1,2,3,4,5,6,7,8}
cases[#cases+1] = {8,7,6,5,4,3,2,1}
cases[#cases+1] = {9,9,1,2,9,3,9,4}
cases[#cases+1] = {13,13,7,11,11,2,13,1}
cases[#cases+1] = {10,10,10,1,10,10,10}
-- 随机局面.
for _ = 1, 400 do
  local n = math.random(2, 12)
  local t = {}
  for i = 1, n do t[i] = math.random(1, 3) end
  cases[#cases+1] = t
end
for _, t in ipairs(cases) do
  local idx = {}
  for i = 1, #t do idx[i] = i end
  table.sort(idx, function(a, b) return t[a] > t[b] end)
  print(table.concat(t, ",") .. "\t" .. table.concat(idx, ","))
end
