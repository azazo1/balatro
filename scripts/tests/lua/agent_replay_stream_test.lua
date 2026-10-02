-- 回放流式条纯逻辑的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Play = dofile("mods/bbreplay/replay/stream_play.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

do -- 平均字速
  check("还没开始是 0", Play.visible_chars(-1, 4, 10) == 0)
  check("时长为 0 一次给完", Play.visible_chars(0, 0, 10) == 10)
  check("走完给全部", Play.visible_chars(4, 4, 10) == 10)
  check("一半约一半字", Play.visible_chars(2, 4, 10) == 5)
  check("没有字是 0", Play.visible_chars(1, 4, 0) == 0)
end

do -- 原局时间映射
  check("original 1:1", Play.map_time(10, 3, 8, 8) == 13)
  check("tight 把 8 秒压进 0.4 秒", math.abs(Play.map_time(10, 0.2, 8, 0.4) - 14) < 1e-9)
  check("等满就到终点", Play.map_time(10, 9, 8, 8) == 18)
  check("没有间隔停在起点", Play.map_time(10, 1, 0, 0.35) == 10)
end

do -- 落在哪一段输出
  local streams = {
    { wall = 2, wall_end = 5 },
    { wall = 8, wall_end = 10 },
  }
  local s, i = Play.active_stream(streams, 1)
  check("开始前没有", s == nil and i == 0)
  s, i = Play.active_stream(streams, 2)
  check("第一段起点", i == 1 and s.wall == 2)
  s, i = Play.active_stream(streams, 5)
  check("第一段终点还算里面", i == 1)
  s, i = Play.active_stream(streams, 6)
  check("两段之间没有", s == nil and i == 1)
  s, i = Play.active_stream(streams, 9)
  check("第二段", i == 2)
  s, i = Play.active_stream(streams, 11)
  check("全部结束", s == nil and i == 2)
end

do -- 录制累积
  local acc = Play.new_acc()
  check("空的 take 什么都没有", acc:take() == nil)
  acc:begin(nil)
  check("还没有字不写", acc:take() == nil)
  acc:begin("压缩中: ")
  check("第一个字", acc:delta("reasoning", "想") == true)
  check("后续不是第一", acc:delta("reasoning", "一下") == false)
  acc:delta("content", "结论")
  local rec = acc:take()
  check("带前缀和两段", rec.label == "压缩中: " and #rec.segments == 2 and rec.segments[1].text == "想一下")
  acc:begin(nil)
  acc:delta("content", "半截")
  acc:reset()
  acc:delta("content", "重来")
  rec = acc:take()
  check("reset 丢掉半截", rec and rec.segments[1].text == "重来", rec and rec.segments[1].text)
  acc:begin(nil)
  acc:delta("reasoning", "旧")
  local prev = acc:begin(nil)
  check("begin 交出上一段", prev and prev.segments[1].text == "旧")
  acc:delta("content", "新")
  acc:drop()
  check("drop 不留", acc:take() == nil)
end

do -- 字数
  check(
    "中英合计",
    Play.char_count({ { kind = "reasoning", text = "思考ab" }, { kind = "content", text = "好" } }) == 5
  )
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("replay stream 全部通过")
