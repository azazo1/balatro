-- 录制剪辑点与消息的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Cuts = dofile("mods/bbreplay/record/cuts.lua")
local Post = dofile("mods/bbreplay/record/post.lua")
package.preload.json = function() -- 时间线只在 flush 时用到, 测试不写文件
  return { encode = function() return "{}" end }
end
local Timeline = dofile("mods/bbreplay/record/timeline.lua")
local Toast = dofile("mods/bbcore/runtime/toast.lua")

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

local function write_file(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
  end
  return f ~= nil
end

-- 在墙钟时间 w 记一个操作事件 (按当时的剪辑区间算剪辑版时间), 操作在 30.5 结束
local function timeline_with_event(cuts, w)
  local tl = Timeline.new("/nonexistent/timeline.json", {})
  local event = tl:event(w, cuts:cut_time(w), "action", {})
  event.wall_end = 30.5
  event.cut_end = cuts:cut_time(30.5)
  return { tl = tl, event = event }
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

do -- 暂停: 期间的活动不算, 整段按等待剪掉; 期间记下的事件在恢复后改正剪辑版时间
  local c = new_cuts()
  active(c, 0, 2)
  c:pause(2)
  local during = timeline_with_event(c, 10)
  active(c, 2, 30) -- 暂停期间的手动操作, 动画等
  c:resume(30)
  active(c, 30, 31)
  check("暂停段被剪掉", #c.list == 1 and near(c.list[1].start, 3) and near(c.list[1].stop, 29.5),
    #c.list .. " " .. tostring(c.list[1] and (c.list[1].start .. "~" .. c.list[1].stop)))
  during.tl:refresh_cut(c, 2)
  check("暂停期间的事件对应剪辑点", near(during.event.cut, 3), tostring(during.event.cut))
  check("暂停期间开始的操作, 结束时间也改正", near(during.event.cut_end, 30.5 - 26.5), tostring(during.event.cut_end))

  local c2 = new_cuts()
  active(c2, 0, 2)
  active(c2, 2, 30)
  check("不暂停时同样的活动不剪", #c2.list == 0, tostring(#c2.list))
end

do -- 草稿脚本不删中间文件 (带 --clean 才删), 局末脚本成功后删; 声音在运行时按 .pcm 是否为空决定
  local dir = os.tmpname()
  os.remove(dir)
  assert(os.execute("mkdir -p '" .. dir .. "'") == 0)
  -- 假的 ffmpeg: 记下参数, 创建最后一个参数 (输出文件)
  local fake = dir .. "/ffmpeg"
  write_file(fake, '#!/bin/sh\necho "$*" >> "' .. dir .. '/calls.txt"\nfor a; do last=$a; done\necho x > "$last"\n')
  os.execute("chmod +x '" .. fake .. "'")
  local base = dir .. "/run"
  local opts = { ffmpeg = fake, codec_args = "-c:v libx264", base = base, fps = 30, audio = "auto",
    cuts = { { start = 2, stop = 4 } }, draft = true }
  local function reset()
    write_file(base .. ".video.mp4", "v")
    write_file(base .. ".pcm", "")
    os.remove(base .. "-full.mp4")
    os.remove(dir .. "/calls.txt")
  end

  reset()
  local path = assert(Post.write(opts))
  local ok = os.execute("/bin/sh '" .. path .. "'") == 0
  check("草稿脚本合成成功", ok and exists(base .. "-full.mp4"))
  check("草稿脚本默认保留中间文件与脚本", exists(base .. ".video.mp4") and exists(path))
  check("pcm 为空时不混声音", not read_file(dir .. "/calls.txt"):find("s16le", 1, true))

  reset()
  write_file(base .. ".pcm", "\0\0\0\0")
  os.execute("/bin/sh '" .. path .. "' --clean")
  check("pcm 非空时混入声音", read_file(dir .. "/calls.txt"):find("s16le", 1, true) ~= nil)
  check("草稿脚本带 --clean 时删除中间文件", not exists(base .. ".video.mp4") and not exists(path))

  reset()
  opts.draft = false
  opts.audio = false
  path = assert(Post.write(opts))
  os.execute("/bin/sh '" .. path .. "'")
  check("局末脚本成功后删除中间文件", exists(base .. "-full.mp4") and not exists(base .. ".video.mp4") and not exists(path))

  -- 保留方式为 keep: 合成成功也留着中间文件, 只删脚本自身
  reset()
  opts.keep = true
  path = assert(Post.write(opts))
  os.execute("/bin/sh '" .. path .. "'")
  check(
    "keep 时保留中间文件",
    exists(base .. "-full.mp4") and exists(base .. ".video.mp4") and exists(base .. ".pcm") and not exists(path)
  )
  opts.keep = nil

  os.execute("rm -rf '" .. dir .. "'")
end

do -- 清晰度, 帧率, 码率: 环境变量 > 设置页 > 平台默认; 设置页的值不在可选范围内时按默认
  local Quality = dofile("mods/bbreplay/record/quality.lua")
  local function env(map)
    return function(name)
      return map[name]
    end
  end
  local q = Quality.resolve({ height = 1080, fps = 60, bitrate = 8 }, env({}), false)
  check("设置页的值生效", q.height == 1080 and q.fps == 60 and q.bitrate == 8 and next(q.env) == nil)
  q = Quality.resolve({ height = 0, fps = 0, bitrate = 0 }, env({}), true)
  check("0 跟随平台默认", q.height == 540 and q.fps == 24 and q.bitrate == 0)
  q = Quality.resolve({ height = 1000, fps = "x" }, env({}), false)
  check("非可选值按默认", q.height == 720 and q.fps == 30 and q.bitrate == 0)
  q = Quality.resolve(
    { height = 1080, fps = 60, bitrate = 8 },
    env({ BALATROBOT_RECORD_HEIGHT = "480", BALATROBOT_RECORD_BITRATE = "2.5", BALATROBOT_RECORD_FPS = "abc" }),
    false
  )
  check(
    "环境变量优先, 不合法时当作没设",
    q.height == 480 and q.bitrate == 2.5 and q.fps == 60 and q.env.height == "480" and q.env.fps == nil
  )
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

do -- 运行时加载自己的模块必须显式给出 mod id.
  -- SMODS.load_file 只在首次加载 mod 时才可以省 id; 这些文件里的加载可能发生在运行中 (例如设置页打开
  -- 录像开关时装载编码模块, 内置 loop 启动时装载依赖), 省掉 id 会报 "No ID was provided!" 并崩掉游戏.
  -- 扫三个本仓库 mod 里由本仓库编写的模块 (含子目录). 各 mod 的入口 (main.lua, balatrobot.lua) 与
  -- bbreplay 的 migrate.lua 在 mod 首次加载时执行, 可以省 id, 不在其中; bbcore 的 src/lua 是 upstream 代码,
  -- 也只在加载时执行.
  local RUNTIME_FILES = {}
  local pipe = io.popen(
    "find mods/balatrobot/agent mods/bbcore/runtime mods/bbcore/ui mods/bbreplay/record mods/bbreplay/replay"
      .. " mods/bbreplay/ui -name '*.lua' | sort"
  )
  for name in (pipe and pipe:read("*a") or ""):gmatch("[^\n]+") do
    RUNTIME_FILES[#RUNTIME_FILES + 1] = name
  end
  if pipe then
    pipe:close()
  end
  local bare = {}
  for _, file in ipairs(RUNTIME_FILES) do
    local handle = assert(io.open(file, "rb"))
    -- 去掉注释 (块注释与行注释), 免得把用法示例当成代码
    local code = handle:read("*a"):gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
    handle:close()
    for call in code:gmatch('SMODS%.load_file%s*%(%s*"[^"]*"%s*%)') do
      bare[#bare + 1] = file:match("[^/]+$") .. ": " .. call
    end
  end
  check("运行时加载都带 mod id", #RUNTIME_FILES > 0 and #bare == 0, table.concat(bare, "; "))
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
