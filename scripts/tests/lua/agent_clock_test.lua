-- 录制时钟与消息截断的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Clock = dofile("mods/balatrobot/agent/record/clock.lua")
local Toast = dofile("mods/balatrobot/agent/toast.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function near(a, b)
  return math.abs(a - b) < 1e-6
end

-- 以 60Hz 推进 seconds 秒, 返回输出帧数
local function run(clock, seconds, active)
  local total = 0
  for _ = 1, math.floor(seconds * 60 + 0.5) do
    total = total + clock:advance(1 / 60, active)
  end
  return total
end

do -- keep: 等待照常出帧, 等待段有长度
  local c = Clock.new({ mode = "keep", fps = 30 })
  local a = run(c, 2, true)
  local b = run(c, 3, false)
  local d = run(c, 1, true)
  c:finish()
  check("keep 出帧数随墙钟", a == 60 and b == 90 and d == 30, a .. "/" .. b .. "/" .. d)
  local gaps = c:gap_list()
  check("keep 一个等待段", #gaps == 1)
  check("keep 等待段覆盖视频区间", near(gaps[1].video_start, 2) and near(gaps[1].video_end, 5))
  check("keep 等待段墙钟时长", near(gaps[1].wall_seconds, 3), tostring(gaps[1].wall_seconds))
  check("keep 视频时长等于墙钟", near(c:video_time(), c.wall))
end

do -- skip: 等待不出帧, 剪辑点 video_start == video_end
  local c = Clock.new({ mode = "skip", fps = 30 })
  run(c, 2, true)
  local idle = run(c, 40, false)
  run(c, 1, true)
  c:finish()
  local gaps = c:gap_list()
  check("skip 等待期间不出帧", idle == 0)
  check("skip 视频只含活动期", near(c:video_time(), 3), tostring(c:video_time()))
  check("skip 剪辑点", #gaps == 1 and near(gaps[1].video_start, 2) and near(gaps[1].video_end, 2))
  check("skip 记录被剪掉的墙钟时长", near(gaps[1].wall_seconds, 40), tostring(gaps[1].wall_seconds))
  check("skip 等待总时长", near(c:waited(), 40))
end

do -- skip: 恢复活动时累积量从零开始, 不会把等待期的时间补成帧
  local c = Clock.new({ mode = "skip", fps = 30 })
  c:advance(0.02, true) -- 累积 0.02, 不足一帧
  c:advance(10, false)
  local n = c:advance(0.02, true)
  check("skip 恢复后不补等待期的帧", n == 0 and c.frames == 0, "frames=" .. c.frames)
end

do -- 卡顿: 补帧有上限, 超出部分丢弃
  local c = Clock.new({ mode = "keep", fps = 30, max_catchup = 30 })
  local n = c:advance(5, true)
  check("卡顿补帧上限", n == 30)
  check("卡顿后累积量清零", c:advance(1 / 60, true) == 0)
end

do -- 结束时仍在等待: 未关闭的等待段也写入
  local c = Clock.new({ mode = "skip", fps = 30 })
  run(c, 1, true)
  run(c, 5, false)
  c:finish()
  local gaps = c:gap_list()
  check("结束时收尾等待段", #gaps == 1 and near(gaps[1].wall_seconds, 5))
end

do -- 消息截断按 UTF-8 字符, 不切断多字节字符
  local text = string.rep("中", 10)
  local cut = Toast.truncate(text, 5)
  check("截断保留完整字符", cut == "中中..." , cut)
  check("未超长不截断", Toast.truncate("abc", 5) == "abc")
  check("阅读时长下限", Toast.duration_for("hi") == 2.5)
  check("阅读时长上限", Toast.duration_for(string.rep("中", 500)) == 12)
  check("显式时长", Toast.duration_for("hi", 12) == 12)
  -- 同样字数的中文要比英文读得久, 否则连续消息会在观众读完前被顶掉.
  check("中文按字计时", Toast.duration_for(string.rep("中", 20)) > Toast.duration_for(string.rep("a", 20)) + 2)
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
