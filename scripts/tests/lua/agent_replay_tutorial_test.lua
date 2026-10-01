-- 教程局回放的纯逻辑测试, 用 luajit 在仓库根目录运行: just test-agent
-- 覆盖回放用的教程状态, 引导不显示浮层时的替代实现, 以及收尾恢复.

local Tutorial = dofile("mods/bbreplay/replay/tutorial.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

do -- 初始进度就是教程开局的那份强制内容, 与 state_events.lua 的 tutorial_controller 一致
  local progress = Tutorial.initial_progress()
  check("强制商店牌", progress.forced_shop[1] == "j_joker" and progress.forced_shop[2] == "c_empress")
  check("强制优惠券", progress.forced_voucher == "v_grabber")
  check("强制标签", progress.forced_tags[1] == "tag_handy" and progress.forced_tags[2] == "tag_garbage")
  check("两份记录都是空的", next(progress.hold_parts) == nil and next(progress.completed_parts) == nil)
end

do -- 每次拿到的是新表: 回放里教程逻辑会清 forced_shop 与 forced_tags
  check("两次调用互不影响", Tutorial.initial_progress() ~= Tutorial.initial_progress())
end

do -- 开局前换上回放用的状态, 收尾恢复原值
  local original_part = function() end
  G = {
    SETTINGS = { tutorial_complete = true, tutorial_progress = nil, profile = 1 },
    FUNCS = { tutorial_part = original_part },
    F_SKIP_TUTORIAL = true,
  }
  Tutorial.install()
  check("回放中视为教程未完成", G.SETTINGS.tutorial_complete == false)
  check("回放中用初始强制内容", G.SETTINGS.tutorial_progress.forced_voucher == "v_grabber")
  check("关掉跳过教程的开关", G.F_SKIP_TUTORIAL == false)
  check("引导换成不显示浮层的版本", G.FUNCS.tutorial_part ~= original_part)
  check("标记为已装上", Tutorial.active())
  check("重复装上不再备份", (function()
    Tutorial.install()
    return G.SETTINGS.tutorial_complete == false
  end)())

  G.SETTINGS.tutorial_complete = true
  G.SETTINGS.tutorial_progress = Tutorial.initial_progress()
  Tutorial.restore()
  check("恢复教程完成状态", G.SETTINGS.tutorial_complete == true)
  check("恢复原来的进度", G.SETTINGS.tutorial_progress == nil)
  check("恢复跳过教程的开关", G.F_SKIP_TUTORIAL == true)
  check("恢复原来的引导函数", G.FUNCS.tutorial_part == original_part)
  check("标记为已卸下", not Tutorial.active())
  Tutorial.restore()
  check("重复卸下不出错", not Tutorial.active())
end

do -- 快照已经放回了进度时保留它: 教程中途的局, 强制内容与第一次开局不同
  G = {
    SETTINGS = { tutorial_complete = false, tutorial_progress = { forced_shop = {}, hold_parts = {} } },
    FUNCS = { tutorial_part = function() end },
    F_SKIP_TUTORIAL = true,
  }
  Tutorial.install()
  check("保留快照放回的进度", G.SETTINGS.tutorial_progress.forced_shop[1] == nil)
  check("保留它的记录", G.SETTINGS.tutorial_progress.hold_parts ~= nil)
  Tutorial.restore()
end

do -- 引导: 不显示浮层, 但 hold_parts 要记下, tutorial_controller 靠它推进后面几步
  G = { SETTINGS = { tutorial_progress = Tutorial.initial_progress() }, FUNCS = {} }
  Tutorial.skip_part("big_blind")
  Tutorial.skip_part("second_hand")
  check("记下展过的步骤", G.SETTINGS.tutorial_progress.hold_parts.big_blind == true)
  check("多个步骤都记下", G.SETTINGS.tutorial_progress.hold_parts.second_hand == true)
  check("没有把没展过的步骤记上", G.SETTINGS.tutorial_progress.hold_parts.small_blind == nil)
  check("不碰强制内容", G.SETTINGS.tutorial_progress.forced_tags[1] == "tag_handy")
end

do -- 教程状态被清掉时 (例如读档) 不炸
  G = { SETTINGS = { tutorial_progress = nil }, FUNCS = {} }
  local ok = pcall(Tutorial.skip_part, "small_blind")
  check("没有进度表时不报错", ok)
end

if failures > 0 then
  print(string.format("%d 个用例失败", failures))
  os.exit(1)
end
print("全部通过")
