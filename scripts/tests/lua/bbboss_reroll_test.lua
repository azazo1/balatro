-- 导演剪辑版 / 重构 能不能重掷 Boss, 用 luajit 在仓库根目录运行: just test-agent

local Boss = dofile("mods/bbcore/src/lua/utils/boss_reroll.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

check("没有优惠券不能掷", not Boss.available({}) and not Boss.allowed({ dollars = 20 }))

local directors = { used_vouchers = { v_directors_cut = true } }
check("导演剪辑版本底注还能掷", Boss.available(directors) == true)
check("导演剪辑版本底注已掷过", Boss.available({ used_vouchers = { v_directors_cut = true }, boss_rerolled = true }) == false)

local retcon = { used_vouchers = { v_retcon = true }, boss_rerolled = true }
check("重构不限次数", Boss.available(retcon) == true)

local ok, err = Boss.allowed({ used_vouchers = { v_directors_cut = true }, dollars = 9 })
check("钱不够", ok == false and type(err) == "string" and err:find("Available: 9", 1, true) ~= nil, err)

ok, err = Boss.allowed({ used_vouchers = { v_directors_cut = true }, dollars = 10 })
check("刚好 $10 能掷", ok == true and err == nil)

ok = Boss.allowed({ used_vouchers = { v_directors_cut = true }, dollars = 0, bankrupt_at = -20 })
check("信用卡把破产线压到负也能掷", ok == true)

ok, err = Boss.allowed({ used_vouchers = { v_directors_cut = true }, boss_rerolled = true, dollars = 50 })
check("本底注已掷过给明确原因", ok == false and err:find("already used", 1, true) ~= nil, err)

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("boss_reroll 全部通过")
