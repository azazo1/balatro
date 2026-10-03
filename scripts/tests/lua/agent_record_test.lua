-- 录制合成脚本与消息的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Post = dofile("mods/bbreplay/record/post.lua")
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

do -- 草稿脚本不删中间文件 (带 --clean 才删), 局末脚本成功后删; 声音在运行时按 .pcm 是否为空决定
  local dir = os.tmpname()
  os.remove(dir)
  assert(os.execute("mkdir -p '" .. dir .. "'") == 0)
  -- 假的 ffmpeg: 记下参数, 创建最后一个参数 (输出文件)
  local fake = dir .. "/ffmpeg"
  write_file(fake, '#!/bin/sh\necho "$*" >> "' .. dir .. '/calls.txt"\nfor a; do last=$a; done\necho x > "$last"\n')
  os.execute("chmod +x '" .. fake .. "'")
  local base = dir .. "/run"
  local opts = { ffmpeg = fake, base = base, audio = "auto", draft = true }
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
  Toast.set_pace("compact")
  local compact_right = Toast.duration_for(string.rep("中", 20))
  local left_compact = Toast.duration_for(string.rep("中", 20), nil, nil, left_opts)
  Toast.set_pace("fast")
  -- 快进: 原局讲解显式给的时长也不等; 回放自己的提示 (fixed) 仍按正常时长.
  local fast_explicit = Toast.duration_for("hi", 12)
  local fixed_fast = Toast.duration_for(string.rep("中", 20), nil, nil, { fixed = true })
  Toast.set_pace("normal")
  check("紧凑模式右侧更快", compact_right < normal_right, tostring(compact_right) .. " vs " .. tostring(normal_right))
  check("左侧不跟紧凑开关走", left_compact == left_before, tostring(left_compact))
  check("快进几乎不等读完", fast_explicit < 0.2, tostring(fast_explicit))
  check("fixed 不跟快进走", fixed_fast == normal_right, tostring(fixed_fast))
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
    -- 内容宽度 2 (两侧都用 20 的最小宽度, 多出来的部分留在屏幕外)
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
  check("左侧用 cli 对齐且先藏在屏幕外", boxes[2].align == "cli" and boxes[2].alignment.offset.x == -0.8 - G.ROOM.T.x - 20, tostring(boxes[2].alignment.offset.x))

  -- 两侧都用很宽的 minw: 左侧内容靠右, 右侧内容靠左, 多出来的宽度留在屏幕外
  local function inner_minw(definition)
    local row = definition.nodes[1]
    return row.config.minw
  end
  local function inner_align(definition)
    return definition.config.align
  end
  check("左侧内容靠右", inner_align(defs[2]) == "cr", tostring(inner_align(defs[2])))
  check("右侧内容靠左", inner_align(defs[1]) == "cl", tostring(inner_align(defs[1])))
  check("左侧框同样用宽 minw", inner_minw(defs[2]) == 20, tostring(inner_minw(defs[2])))
  check("右侧框保留宽 minw", inner_minw(defs[1]) == 20, tostring(inner_minw(defs[1])))

  -- 滑入后: 左侧把 (WIDE - 内容宽) 退到屏幕左边外, 并扣掉 ROOM 的 letterbox; 右侧内容贴窗口右边
  Toast.update(0.2)
  check("左侧框贴屏幕左边", boxes[2].alignment.offset.x == 0.8 - G.ROOM.T.x - (20 - 2), tostring(boxes[2].alignment.offset.x))
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
  Toast.set_pace("normal")
  local right_i = #boxes + 1
  Toast.push("右侧", "决策", 1)
  local left_i = #boxes + 1
  Toast.push("左侧", "调用", 1, nil, { side = "left" })
  for _ = 1, 23 do
    Toast.update(0.1)
  end
  check("2.3 秒后左侧已退去, 右侧还在", boxes[left_i].REMOVED and not boxes[right_i].REMOVED)
  Toast.clear()
  Toast.set_pace("compact")
  local compact_i = #boxes + 1
  Toast.push("右侧", "决策", 1)
  for _ = 1, 23 do
    Toast.update(0.1)
  end
  check("紧凑右侧 2.3 秒已退去", boxes[compact_i].REMOVED)
  Toast.clear()
  -- 回放中途切到快进: 屏幕上那条按新档位重算, 等着它读完的调用方很快放行.
  Toast.set_pace("normal")
  local read = false
  Toast.push("右侧", string.rep("中", 60), nil, function()
    read = true
  end)
  Toast.update(0.5)
  Toast.set_pace("fast")
  Toast.update(0.1)
  check("切到快进后屏幕上的讲解立刻读完", read)
  Toast.clear()
  -- 快进: 回调立刻放行, 但框要停够滑入的时间 (约 0.4 秒), 否则还没进屏幕就退场了.
  -- 第二条不排队, 直接叠上来.
  local first_i = #boxes + 1
  local fast_read = false
  Toast.push("右侧", "讲解一", nil, function()
    fast_read = true
  end, { gated = true })
  Toast.update(0.2)
  local second_i = #boxes + 1
  Toast.push("右侧", "讲解二", nil, nil, { gated = true })
  check("快进时第二条不排队", boxes[second_i] ~= nil)
  for _ = 1, 6 do
    Toast.update(0.1)
  end
  check("快进时回调很快放行", fast_read)
  check("快进时框仍停留够滑入的时间", not boxes[first_i].REMOVED)
  -- 左侧的工具调用记录同样不排队.
  Toast.clear()
  local left_first_i = #boxes + 1
  Toast.push("左侧", "手牌下标 0", nil, nil, { side = "left" })
  Toast.update(0.2)
  local left_second_i = #boxes + 1
  Toast.push("左侧", "手牌下标 1", nil, nil, { side = "left" })
  check("快进时左侧第二条也直接叠上来", boxes[left_second_i] ~= nil and not boxes[left_first_i].REMOVED)
  Toast.set_pace("normal")
  Toast.clear()
  -- agent 的 home 档位: 快速关掉门槛, 阅读打开.
  Toast.home_pace = "fast"
  Toast.gate_enabled = true
  Toast.apply_home()
  check("home 快速关掉门槛", Toast.pace == "fast" and Toast.gate_enabled == false)
  Toast.home_pace = "normal"
  Toast.apply_home()
  check("home 阅读打开门槛", Toast.pace == "normal" and Toast.gate_enabled == true)
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
