-- 录制剪辑点与消息的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Cuts = dofile("mods/balatrobot/agent/record/cuts.lua")
local Post = dofile("mods/balatrobot/agent/record/post.lua")
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

local function new_cuts()
  return Cuts.new({ pre = 0.5, post = 1, min_gap = 1.5 })
end

-- 以 0.1 秒为步长, 在 [from, to) 内每一步都标记活动
local function active(cuts, from, to)
  for i = math.floor(from * 10 + 0.5), math.floor(to * 10 + 0.5) - 1 do
    cuts:mark(i / 10)
  end
end

do -- 长时间等待: 活动结束后留 post, 下次活动前留 pre, 中间剪掉
  local c = new_cuts()
  active(c, 0, 2) -- 最后一次活动在 1.9
  active(c, 42, 43)
  c:finish(43)
  -- 结尾在最后一次活动 (42.9) 之后只有 0.1 秒, 不足 post, 不再剪
  check("等待被剪成一段", #c.list == 1, tostring(#c.list))
  local cut = c.list[1]
  check("剪辑点前后留出 padding", near(cut.start, 2.9) and near(cut.stop, 41.5), cut.start .. "~" .. cut.stop)
  check("剪掉的总时长", near(c.removed, 38.6), tostring(c.removed))
end

do -- 结尾的等待: 最后一次活动后留 post, 之后全部剪掉
  local c = new_cuts()
  active(c, 0, 1)
  c:finish(20)
  local last = c.list[#c.list]
  check("结尾等待被剪掉", last and near(last.start, 1.9) and near(last.stop, 20))
end

do -- 短暂停顿不剪: 剪掉的部分不足 min_gap
  local c = new_cuts()
  active(c, 0, 1)
  active(c, 3.5, 4)
  check("短停顿保留", #c.list == 0, tostring(#c.list))
end

do -- 剪辑版时间: 剪辑点之后的时间减去剪掉的长度, 落在剪掉区间里的对应剪辑点
  local c = new_cuts()
  active(c, 0, 2)
  active(c, 42, 43)
  check("剪辑点之前不变", near(c:cut_time(1.5), 1.5))
  check("剪掉区间内对应剪辑点", near(c:cut_time(20), 2.9))
  check("剪辑点之后减去剪掉的长度", near(c:cut_time(42), 42 - 38.6), tostring(c:cut_time(42)))
end

do -- 剪辑版的 select 表达式: 半开区间, 与 cut_time 一致
  check("没有剪辑区间时不需要表达式", Post.keep_expr({}) == nil)
  local expr = Post.keep_expr({ { start = 2, stop = 4 }, { start = 6.5, stop = 8 } })
  check("select 表达式", expr == "not(gte(t,2.000)*lt(t,4.000)+gte(t,6.500)*lt(t,8.000))", expr)
end

do -- 消息截断按 UTF-8 字符, 不切断多字节字符
  local text = string.rep("中", 10)
  local cut = Toast.truncate(text, 5)
  check("截断保留完整字符", cut == "中中...", cut)
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
