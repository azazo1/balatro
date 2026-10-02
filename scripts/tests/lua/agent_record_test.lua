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

do -- 剪辑版重编码的目标码率: 按完整版的实测码率算, 量不到或不合理时给 nil (保持原来的画质档)
  -- 真机上的那一局: 完整版 2726254461 字节, 196988 帧, 60fps, 平均约 6.47 Mbps
  local mbps = Post.cut_mbps(2726254461, 196988, 60)
  check("按实测码率取目标", mbps and mbps > 5.5 and mbps < 6.5, tostring(mbps))
  check("低一点, 保证剪辑版更小", mbps and mbps < 2726254461 * 8 / (196988 / 60) / 1e6, tostring(mbps))
  check("帧数为 0 时不给目标", Post.cut_mbps(1000, 0, 60) == nil)
  check("帧率为 0 时不给目标", Post.cut_mbps(1000, 100, 0) == nil)
  check("文件为空时不给目标", Post.cut_mbps(0, 100, 60) == nil)
  check("读不到大小时不给目标", Post.cut_mbps(nil, 100, 60) == nil)
  check("数值离谱时不给目标", Post.cut_mbps(1e12, 100, 60) == nil)
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

do -- Windows 命令行的引号: 按 CommandLineToArgvW 的规则, 反斜杠只在引号前与结尾处加倍
  local WinProc = dofile("mods/bbreplay/record/win_proc.lua")
  local cases = {
    { "ffmpeg", "ffmpeg" },
    { "", '""' },
    { "C:/Program Files/ffmpeg.exe", '"C:/Program Files/ffmpeg.exe"' },
    { [[C:\a b\]], [["C:\a b\\"]] }, -- 结尾的反斜杠不能吃掉收尾的引号
    { [[a\b c]], [["a\b c"]] }, -- 中间的反斜杠原样
    { [[say "hi"]], [["say \"hi\""]] },
    { [[a\"b]], [["a\\\"b"]] }, -- 引号前的反斜杠加倍再转义引号
  }
  local wrong = {}
  for _, case in ipairs(cases) do
    local got = WinProc.quote(case[1])
    if got ~= case[2] then
      wrong[#wrong + 1] = case[1] .. " -> " .. got
    end
  end
  check("Windows 参数引号", #wrong == 0, table.concat(wrong, "; "))
end

do -- 消息截断按 UTF-8 字符, 不切断多字节字符
  local text = string.rep("中", 10)
  local cut = Toast.truncate(text, 5)
  check("截断保留完整字符", cut == "中中...", cut)
  check("未超长不截断", Toast.truncate("abc", 5) == "abc")
  check("阅读时长下限", Toast.duration_for("hi") == 2.5)
  check("阅读时长上限", Toast.duration_for(string.rep("中", 500)) == 36)
  -- 提示词允许的最长消息 (180 字) 要能读完, 加上停留不超过墙钟上限.
  local longest = Toast.duration_for(string.rep("中", 180))
  check("180 字的中文读得完", longest >= 180 * 0.18 and longest + 2 <= 40, tostring(longest))
  check("显式时长", Toast.duration_for("hi", 12) == 12)
  -- 同样字数的中文要比英文读得久, 否则连续消息会在观众读完前被顶掉.
  check("中文按字计时", Toast.duration_for(string.rep("中", 20)) > Toast.duration_for(string.rep("a", 20)) + 2)
  local left_opts = { side = "left" }
  check("左侧短消息比右侧短", Toast.duration_for("hi", nil, nil, left_opts) < Toast.duration_for("hi"))
  check("左侧长消息上限更短", Toast.duration_for(string.rep("中", 200), nil, nil, left_opts) == 2.2)
  check("显式 cap 仍生效", Toast.duration_for(string.rep("中", 200), nil, 8) == 8)
  local normal_right = Toast.duration_for(string.rep("中", 20))
  local left_before = Toast.duration_for(string.rep("中", 20), nil, nil, left_opts)
  Toast.compact = true
  local compact_right = Toast.duration_for(string.rep("中", 20))
  local left_compact = Toast.duration_for(string.rep("中", 20), nil, nil, left_opts)
  Toast.compact = false
  check("紧凑模式右侧更快", compact_right < normal_right, tostring(compact_right) .. " vs " .. tostring(normal_right))
  check("左侧不跟紧凑开关走", left_compact == left_before, tostring(left_compact))
end

do -- 队列: 一条条显示, 顺序不丢; 讲解的 id 让后面的操作能等它退去
  G = {
    ROOM = { T = { x = 0, y = 0, w = 12, h = 12 } },
    ROOM_ATTACH = {},
    TILESIZE = 20,
    UIT = { ROOT = 1, R = 4, C = 3, T = 2 },
    C = {
      FILTER = { 1, 1, 1, 1 },
      BLACK = { 0, 0, 0, 1 },
      GREY = { 0.5, 0.5, 0.5, 1 },
      UI = {
        TEXT_LIGHT = { 1, 1, 1, 1 },
        TRANSPARENT_DARK = { 0, 0, 0, 0.5 },
        TEXT_INACTIVE = { 0.5, 0.5, 0.5, 1 },
        BACKGROUND_INACTIVE = { 0.3, 0.3, 0.3, 1 },
      },
    },
    LANG = { font = { FONT = { getWidth = function(_, text) return #text * 10 end }, squish = 1, FONTSCALE = 0.1 } },
  }
  UIBox = function()
    local box = { REMOVED = false, T = { h = 1, w = 1 } }
    box.UIRoot = { children = { { children = { { T = { w = 2 } } } } } }
    box.alignment = { offset = { x = 20, y = 0 } }
    box.remove = function(self)
      self.REMOVED = true
    end
    return box
  end

  local fired = {}
  local read_at = {}
  local elapsed = 0
  local function cb(name)
    return function()
      fired[#fired + 1] = name
      read_at[name] = elapsed
    end
  end

  check("第一条开始显示", Toast.push("t", "A", 1, cb("A"), { gated = true }) == true)
  check("显示期间 active", Toast.active())
  local gate_a = Toast.gate_id()
  check("记下讲解的 id", gate_a ~= nil)
  check("讲解还没退去", not Toast.gate_open(gate_a))
  check("本来会拦后面的操作", Toast.gate_enabled)

  -- B 与 C 排队: 调用方不用等, 它们还没开始显示.
  Toast.push("t", "B", 1, cb("B"), { gated = true })
  Toast.push("t", "C", 1, cb("C"), { gated = true })
  local gate_c = Toast.gate_id()
  check("等最新一条讲解", gate_c ~= nil and gate_c > gate_a)
  check("排队时回调还没触发", #fired == 0, table.concat(fired, ","))
  check("排队也算活动期", Toast.active())

  -- 推进时间, 看三条依次显示, 以及各条的门槛在它退去时才打开.
  local gate_of = { A = gate_a, C = gate_c }
  local open_at = {}
  for _ = 1, 200 do -- 20 秒, 够三条走完 (每条约 3.7 秒)
    Toast.update(0.1)
    elapsed = elapsed + 0.1
    for name, gate in pairs(gate_of) do
      if not open_at[name] and Toast.gate_open(gate) then
        open_at[name] = elapsed
      end
    end
  end

  check("按 A,B,C 的顺序一条条显示, 一条都不丢", table.concat(fired, ",") == "A,B,C", table.concat(fired, ","))
  check("A 的门槛在它退去后才开", open_at.A ~= nil and open_at.A >= read_at.A, tostring(open_at.A))
  check("A 退去时 B 还没开始读", open_at.A ~= nil and read_at.B ~= nil and open_at.A < read_at.B, tostring(open_at.A))
  check("C 的门槛也在它退去后才开", open_at.C ~= nil and open_at.C >= read_at.C, tostring(open_at.C))
  check("三条都退去后不再 active", not Toast.active())

  -- 清空时排队里的也要放行, 否则等它的请求会一直等下去.
  Toast.push("t", "D", 1, cb("D"), { gated = true })
  Toast.push("t", "E", 1, cb("E"), { gated = true })
  local gate_e = Toast.gate_id()
  check("清空前 E 还在等", not Toast.gate_open(gate_e))
  Toast.clear()
  check("清空后不再 active", not Toast.active())
  check("清空时排队里的回调都触发", #fired == 5, table.concat(fired, ","))
  check("清空后门槛全部打开", Toast.gate_open(gate_e))
end

do -- 两条车道: 左侧的工具调用记录与右侧的决策消息各自排队, 互不影响
  G = {
    ROOM = { T = { x = 1, y = 0, w = 12, h = 12 } },
    ROOM_ATTACH = {},
    TILESIZE = 20,
    UIT = { ROOT = 1, R = 4, C = 3, T = 2 },
    C = {
      FILTER = { 1, 1, 1, 1 },
      BLACK = { 0, 0, 0, 1 },
      GREY = { 0.5, 0.5, 0.5, 1 },
      UI = {
        TEXT_LIGHT = { 1, 1, 1, 1 },
        TRANSPARENT_DARK = { 0, 0, 0, 0.5 },
        TEXT_INACTIVE = { 0.5, 0.5, 0.5, 1 },
        BACKGROUND_INACTIVE = { 0.3, 0.3, 0.3, 1 },
      },
    },
    LANG = { font = { FONT = { getWidth = function(_, text) return #text * 10 end }, squish = 1, FONTSCALE = 0.1 } },
  }
  local boxes = {}
  local defs = {}
  UIBox = function(args)
    local box = { REMOVED = false, T = { h = 1, w = 1 }, align = args.config.align }
    -- 内容宽度 2 (左侧框宽跟着内容走, 不再有 20 单位的最小宽度)
    box.UIRoot = { children = { { children = { { T = { w = 2 } } } } } }
    box.alignment = { offset = { x = args.config.offset.x, y = 0 } }
    box.remove = function(self)
      self.REMOVED = true
    end
    boxes[#boxes + 1] = box
    defs[#defs + 1] = args.definition
    return box
  end

  check("右侧消息开始显示", Toast.push("右侧", "决策理由", 2) == true)
  check("左侧不受右侧排队影响", Toast.push("左侧", "手牌下标 0, 1", 2, nil, { side = "left" }) == true)
  check("两条车道都建了框", #boxes == 2, tostring(#boxes))
  check("左侧用 cli 对齐且先藏在屏幕外", boxes[2].align == "cli" and boxes[2].alignment.offset.x < 0, tostring(boxes[2].align))

  -- 左侧不设 minw (框宽由内容决定), 右侧保留那个很宽的 minw
  local function inner_minw(definition)
    local row = definition.nodes[1]
    return row.config.minw
  end
  check("左侧框不设最小宽度", inner_minw(defs[2]) == nil, tostring(inner_minw(defs[2])))
  check("右侧框保留宽 minw", inner_minw(defs[1]) == 20, tostring(inner_minw(defs[1])))

  -- 滑入后: 左侧框贴窗口左边 (offset 要扣掉 ROOM 的 letterbox, 不能再加一次 G.ROOM.T.x), 右侧内容贴窗口右边
  Toast.update(0.2)
  check("左侧框贴屏幕左边", boxes[2].alignment.offset.x == 0.8 - G.ROOM.T.x, tostring(boxes[2].alignment.offset.x))
  check("右侧内容贴屏幕右边", boxes[1].alignment.offset.x == G.ROOM.T.x - 2 - 0.8, tostring(boxes[1].alignment.offset.x))

  -- 左侧那条不拦操作, 关掉开关后不再显示, 右侧照常
  check("左侧不进讲解门槛", Toast.gate_id() == nil)
  Toast.calls_enabled = false
  check("关掉后左侧不显示", Toast.push("左侧", "又一条", 2, nil, { side = "left" }) == false)
  check("右侧照常", Toast.push("右侧", "又一条", 2) == true)
  Toast.calls_enabled = true
  Toast.clear()
  check("清空后两侧都空", not Toast.active())

  -- 左侧那条的阅读时长有单独的上限 (正文只有一句参数说明)
  check("右侧仍按长解说算", Toast.duration_for(string.rep("中", 200)) == 36)

  -- 显式 duration=1 时: 左侧 linger 0.4, 右侧 2. 左侧应先退去.
  Toast.clear()
  Toast.compact = false
  local right_i = #boxes + 1
  Toast.push("右侧", "决策", 1)
  local left_i = #boxes + 1
  Toast.push("左侧", "调用", 1, nil, { side = "left" })
  for _ = 1, 23 do
    Toast.update(0.1)
  end
  check("2.3 秒后左侧已退去, 右侧还在", boxes[left_i].REMOVED and not boxes[right_i].REMOVED)
  Toast.clear()
  Toast.compact = true
  local compact_i = #boxes + 1
  Toast.push("右侧", "决策", 1)
  for _ = 1, 23 do
    Toast.update(0.1)
  end
  check("紧凑右侧 2.3 秒已退去", boxes[compact_i].REMOVED)
  Toast.compact = false
  Toast.clear()

  -- 左侧的换行宽度比右侧窄: 同样一段文字, 左侧折出的行更短 (弹窗水平方向不会拉长)
  local function longest_line(definition)
    local rows = definition.nodes[1].nodes[1].nodes
    local longest = 0
    for _, row in ipairs(rows) do
      local text = row.nodes[1].config.text or ""
      longest = math.max(longest, #text)
    end
    return longest
  end
  Toast.clear()
  -- 够长才会折行: 假字体下每字节宽度 = scale/20, 所以要几百字节
  local long = string.rep("弃牌堆统计与摸牌堆列表", 12)
  Toast.push("右侧", long, 3)
  Toast.push("左侧", long, 3, nil, { side = "left" })
  local right_line = longest_line(defs[#defs - 1])
  local left_line = longest_line(defs[#defs])
  check("左侧折行更短", left_line < right_line, tostring(left_line) .. " vs " .. tostring(right_line))
  -- 标题不折行, 左侧按 12 字截断 (否则长标题会把弹窗撑宽)
  Toast.clear()
  Toast.push("左侧", "短正文", 3, nil, { side = "left" })
  local title_text = defs[#defs].nodes[1].nodes[1].nodes[1].nodes[1].config.text
  check("左侧标题按 12 字截断", #title_text <= 12 * 3 + 3, tostring(#title_text))
  Toast.clear()
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
