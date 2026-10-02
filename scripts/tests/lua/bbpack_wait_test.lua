-- 补充包等待条件, 用 luajit 在仓库根目录运行: just test-agent
-- 商店买的包回到 SHOP, 跳过标签开的包回到 BLIND_SELECT, 不能死等其中一边.

local Wait = dofile("mods/bbcore/src/lua/utils/pack_wait.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local STATES = {
  SHOP = 5,
  PLAY_TAROT = 6,
  BLIND_SELECT = 7,
  TAROT_PACK = 9,
  SPECTRAL_PACK = 15,
  SMODS_BOOSTER_OPENED = 999,
}

local function after(opts)
  opts.states = STATES
  return Wait.after_pick(opts)
end

local function skip(opts)
  opts.states = STATES
  return Wait.skip_done(opts)
end

check("背面牌区还在算开着", Wait.pack_open({ cards = { {} } }) == true)
check("REMOVED 不算开着", Wait.pack_open({ REMOVED = true, cards = { {} } }) == false)
check("空区不算开着", Wait.pack_open({ cards = {} }) == false)

check("SMODS 包阶段算在包里", Wait.in_pack(STATES.SMODS_BOOSTER_OPENED, STATES) == true)
check("用牌动画算在包里", Wait.in_pack(STATES.PLAY_TAROT, STATES) == true)
check("商店不算在包里", Wait.in_pack(STATES.SHOP, STATES) == false)

check("skip_blind 锁不算额外锁", Wait.extra_lock({ skip_blind = true }) == false)
check("frame / wipe 不算额外锁", Wait.extra_lock({ frame = true, wipe = true, skip_blind = true }) == false)
check("标签 ID 锁算额外锁", Wait.extra_lock({ skip_blind = true, [12] = true }) == true)

do
  local remain = after({
    choices_before = 2,
    choices_now = 1,
    pack_open = true,
    state_complete = true,
    state = STATES.SMODS_BOOSTER_OPENED,
  })
  check("5 选 2 第一张: 还要再选", remain == "remain")
end

do
  local remain = after({
    choices_before = 3,
    choices_now = 2,
    pack_open = true,
    state_complete = true,
    state = STATES.SMODS_BOOSTER_OPENED,
  })
  check("3 选也按剩余次数等", remain == "remain")
end

check(
  "第一张还在用牌动画: 继续等",
  after({
    choices_before = 2,
    choices_now = 1,
    pack_open = true,
    state_complete = false,
    state = STATES.PLAY_TAROT,
  }) == nil
)

check(
  "最后一张关包回到商店",
  after({
    choices_before = 1,
    choices_now = 0,
    pack_open = false,
    state = STATES.SHOP,
    return_to = STATES.SHOP,
  }) == "done"
)

check(
  "最后一张关包回到选盲注",
  after({
    choices_before = 1,
    choices_now = 0,
    pack_open = false,
    state = STATES.BLIND_SELECT,
    return_to = STATES.BLIND_SELECT,
  }) == "done"
)

check(
  "跳过标签的包不能死等商店",
  after({
    choices_before = 1,
    choices_now = 0,
    pack_open = false,
    state = STATES.BLIND_SELECT,
    return_to = STATES.SHOP,
  }) == nil
)

check(
  "点跳过时即使还能再选也关包",
  after({
    skip = true,
    choices_before = 2,
    choices_now = 2,
    pack_open = false,
    state = STATES.BLIND_SELECT,
    return_to = STATES.BLIND_SELECT,
  }) == "done"
)

check(
  "没记返回界面时, 选盲注也算关掉",
  after({
    choices_before = 1,
    choices_now = 0,
    pack_open = false,
    state = STATES.BLIND_SELECT,
  }) == "done"
)

check(
  "skip: 标签锁还在, 包还没出来",
  skip({
    state = STATES.BLIND_SELECT,
    skipped = true,
    locks = { skip_blind = true, [1] = true },
  }) == nil
)

check(
  "skip: 包已打开",
  skip({
    state = STATES.SMODS_BOOSTER_OPENED,
    pack_open = true,
    state_complete = true,
    skipped = true,
  }) == "pack"
)

check(
  "skip: 没有开包标签, 停在选盲注",
  skip({
    state = STATES.BLIND_SELECT,
    skipped = true,
    locks = { skip_blind = true },
  }) == "select"
)

local function reroll_boss(opts)
  opts.states = STATES
  return Wait.reroll_boss_done(opts)
end

check(
  "reroll_boss: 还锁着",
  reroll_boss({
    state = STATES.BLIND_SELECT,
    locked = true,
    pane = true,
  }) == nil
)
check(
  "reroll_boss: Boss 栏换完",
  reroll_boss({
    state = STATES.BLIND_SELECT,
    pane = true,
    locks = { skip_blind = true },
  }) == "select"
)
check(
  "reroll_boss: 标签开包",
  reroll_boss({
    state = STATES.SMODS_BOOSTER_OPENED,
    pack_open = true,
    state_complete = true,
    pane = true,
  }) == "pack"
)
check(
  "reroll_boss: 标签锁还在",
  reroll_boss({
    state = STATES.BLIND_SELECT,
    pane = true,
    locks = { [3] = true },
  }) == nil
)

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("pack_wait 全部通过")
