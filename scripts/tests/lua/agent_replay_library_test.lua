-- 游戏内回放列表的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 覆盖解析, 缓存, 不可回放的原因, 分页与显示文字.

package.path = "mods/Steamodded/libs/json/?.lua;" .. package.path
local json = require("json")
local DIR = "mods/balatrobot/agent/replay/"
local Library = dofile(DIR .. "library.lua")
local Format = dofile(DIR .. "format.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

--- 造一个回放文件的内容.
local function replay_data(extra)
  local data = {
    version = Format.VERSION,
    game_version = "1.0.1n+deadbeef",
    mod_version = "1.0.0 / smods 1.0",
    recorded_at = "2024-05-01T12:34:56Z",
    source = "20240501-123456-ABCD",
    run = { deck = "RED", deck_key = "b_red", stake = "WHITE", seed = "ABCD", resumed = false },
    snapshot = { uda = {}, profile = "", unlock_notify = "", settings = {} },
    manual_inputs = 0,
    actions = {
      { method = "play", wall = 1, wall_end = 2.5, ok = true, digest = "state=SELECTING_HAND ante=1 round=1 money=4" },
      { method = "next_round", wall = 3, wall_end = 4, ok = true, digest = "state=SHOP ante=2 round=2 money=7" },
    },
    result = { reason = "menu", won = false },
  }
  for k, v in pairs(extra or {}) do
    data[k] = v
  end
  return data
end

local function fs_for(files)
  return {
    list = function()
      local out = {}
      for name, file in pairs(files) do
        out[#out + 1] = { name = name, size = file.size, mtime = file.mtime }
      end
      return out
    end,
    read = function(name)
      return files[name] and files[name].text or nil
    end,
  }
end

do
  -- 完整的一局: 字段都从文件里推出来
  local entry = Library.describe(replay_data(), Format.VERSION)
  check("解析: 可回放", entry.ok == true, entry.reason)
  check("解析: 步数", entry.steps == 2, tostring(entry.steps))
  check("解析: 底注取最后一步的摘要", entry.ante == 2, tostring(entry.ante))
  check("解析: 时长取最后一步完成时间", entry.duration == 4, tostring(entry.duration))
  check("解析: 牌组转中文", entry.deck == "红牌组", tostring(entry.deck))
  check("解析: 赌注转中文", entry.stake == "白注", tostring(entry.stake))
  check("解析: 种子", entry.seed == "ABCD", tostring(entry.seed))
  check("解析: 未胜利", entry.result == "未胜利" and entry.won == false)
end

do
  -- 没有种子时显示 "随机"
  local data = replay_data()
  data.run.seed = nil
  data.run.resumed = true
  data.run.save = "return {}"
  local entry = Library.describe(data, Format.VERSION)
  check("解析: 读档开局没有种子时显示随机", entry.seed == "随机", tostring(entry.seed))
  check("解析: 读档开局可回放", entry.ok == true, entry.reason)
  check("解析: 标记读档开局", entry.resumed == true)
end

do
  local cases = {
    { name = "版本不支持", patch = function(d) d.version = 99 end, expect = "版本" },
    { name = "挑战模式", patch = function(d) d.run.challenge = "c_x" end, expect = "挑战" },
    { name = "非原版牌组", patch = function(d) d.run.deck = nil end, expect = "原版牌组" },
    { name = "缺少动作", patch = function(d) d.actions = nil end, expect = "格式" },
    -- 真机上的手动教程局: 只有末尾回主菜单那一步, 回放一开局就结束
    {
      name = "手动打的局",
      patch = function(d)
        d.manual_inputs = 22
        d.actions = { { method = "notify", ok = true }, { method = "menu", manual = true, ok = true } }
      end,
      expect = "手动",
    },
  }
  for _, case in ipairs(cases) do
    local data = replay_data()
    case.patch(data)
    local entry = Library.describe(data, Format.VERSION)
    check("不可回放: " .. case.name, entry.ok == false and entry.reason:find(case.expect, 1, true) ~= nil, tostring(entry.reason))
  end
end

do
  -- 扫描: 坏文件不炸, 按时间倒序
  local files = {
    ["a.replay.json"] = { text = json.encode(replay_data()), size = 10, mtime = 1 },
    ["b.replay.json"] = { text = "{ 不是 json", size = 5, mtime = 2 },
    ["c.replay.json"] = { text = "", size = 0, mtime = 3 },
  }
  local data = replay_data()
  data.recorded_at = "2025-01-01T00:00:00Z"
  files["d.replay.json"] = { text = json.encode(data), size = 11, mtime = 4 }
  local entries, cache = Library.list(fs_for(files), {
    supported_version = Format.VERSION,
    decode = json.decode,
  })
  check("扫描: 四个文件都在", #entries == 4, tostring(#entries))
  check("扫描: 最新的排前面", entries[1].name == "d.replay.json", entries[1].name)
  local broken = {}
  for _, entry in ipairs(entries) do
    broken[entry.name] = entry
  end
  check("扫描: 空文件不可回放", broken["c.replay.json"].ok == false, tostring(broken["c.replay.json"].reason))
  check("扫描: 坏 json 不可回放", broken["b.replay.json"].ok == false, tostring(broken["b.replay.json"].reason))
  check("扫描: 缓存里留下四个条目", next(cache) ~= nil)

  -- 缓存命中: 同样的 名字+大小+时间 不再解析
  local hits = 0
  local entries2, _ = Library.list(fs_for(files), {
    supported_version = Format.VERSION,
    decode = function(text)
      hits = hits + 1
      return json.decode(text)
    end,
    cache = cache,
  })
  check("缓存: 内容没变就不重新解析", hits == 0, tostring(hits))
  check("缓存: 条目数不变", #entries2 == 4)

  -- 文件重写: 大小或时间变了要重新解析
  files["a.replay.json"] = { text = json.encode(replay_data()), size = 99, mtime = 5 }
  local entries3 = Library.list(fs_for(files), {
    supported_version = Format.VERSION,
    decode = function(text)
      hits = hits + 1
      return json.decode(text)
    end,
    cache = cache,
  })
  check("缓存: 文件变了要重新解析", hits == 1, tostring(hits))
  local rewritten
  for _, entry in ipairs(entries3) do
    if entry.name == "a.replay.json" then
      rewritten = entry
    end
  end
  check("缓存: 重写后仍可回放", rewritten ~= nil and rewritten.ok == true)
end

do
  local entries = {}
  for i = 1, 13 do
    entries[i] = { name = i .. ".replay.json", ok = true }
  end
  local items, page, pages = Library.paginate(entries, 1, 6)
  check("分页: 页数", pages == 3, tostring(pages))
  check("分页: 第一页 6 行", #items == 6 and items[1].name == "1.replay.json")
  items, page, pages = Library.paginate(entries, 3, 6)
  check("分页: 最后一页 1 行", page == 3 and #items == 1 and items[1].name == "13.replay.json")
  items, page = Library.paginate(entries, 99, 6)
  check("分页: 页码越界收敛到最后一页", page == 3, tostring(page))
  items, page = Library.paginate(entries, -2, 6)
  check("分页: 页码下界收敛到第一页", page == 1, tostring(page))
end

do
  check("时长: 秒", Library.duration_text(45) == "45 秒", Library.duration_text(45))
  check("时长: 分秒", Library.duration_text(125.4) == "2 分 5 秒", Library.duration_text(125.4))
  check("时间: 格式化", Library.time_text("2024-05-01T12:34:56Z"):find("2024-05-01 12:34", 1, true) ~= nil)
  check("时间: 没有记录时说明未知", Library.time_text(nil) == "未知时间")

  local entry = Library.describe(replay_data(), Format.VERSION)
  entry.name = "20240501-123456-ABCD.replay.json"
  local line = Library.line_text(entry)
  check("行文字: 带牌组与步数", line:find("红牌组", 1, true) ~= nil and line:find("2 步", 1, true) ~= nil, line)
  local bad = { name = "x.replay.json", ok = false, reason = "文件损坏或不是回放文件" }
  local bad_line = Library.line_text(bad)
  check("行文字: 不可回放带原因", bad_line:find("不可回放", 1, true) ~= nil and bad_line:find("文件损坏", 1, true) ~= nil, bad_line)
end

do -- 回放菜单的布局: 竖直列表里不能出现"C 型节点后面还有兄弟"
  -- 布局引擎 (game/engine/ui.lua) 遍历子节点时, C 型子节点把横向游标往右推, 而 R 型子节点只推进
  -- 纵向且不重置横向游标. 所以 C 后面再有兄弟, 那些兄弟就会右移, 可能整行跑到面板外面.
  -- 这个错误在开发机上肉眼看不到 (要真机截图), 只能靠结构检查兜住.
  local UIT = { T = 1, B = 2, C = 3, R = 4, O = 5, ROOT = 7, S = 8, I = 9 }
  local C, R = UIT.C, UIT.R

  -- 假 G/SMODS/love, 只为让 replay_menu 能加载并生成定义.
  love = {
    filesystem = { getSaveDirectory = function() return "/tmp/bb" end, remove = function() return true end },
    timer = { getTime = function() return os.clock() end },
  }
  G = {
    UIT = UIT,
    ROOM = { T = { w = 10, h = 10 } },
    TILESIZE = 20,
    TILESCALE = 1,
    C = {
      FILTER = { 1, 1, 1, 1 },
      BLUE = { 0, 0, 1, 1 },
      RED = { 1, 0, 0, 1 },
      GREEN = { 0, 1, 0, 1 },
      L_BLACK = { 0, 0, 0, 1 },
      UI = { TEXT_LIGHT = { 1, 1, 1, 1 }, TEXT_INACTIVE = { 0.5, 0.5, 0.5, 1 } },
    },
    FUNCS = {},
    STAGES = { MAIN_MENU = 1, RUN = 2, SANDBOX = 3 },
    STAGE = 1,
    SETTINGS = { paused = false, profile = 1 },
  }
  local fake_replay = json.encode(replay_data())
  SMODS = {
    NFS = {
      getDirectoryItemsInfo = function()
        return { { name = "20240501-123456-ABCD.replay.json", size = #fake_replay, modtime = 1000 } }
      end,
      read = function()
        return fake_replay
      end,
    },
  }
  create_UIBox_generic_options = function(args) return { args = args } end
  sendDebugMessage, sendInfoMessage, sendWarnMessage, sendErrorMessage = function() end, function() end, function() end, function() end

  -- widgets.init 需要 toast.pick_lang
  local Widgets = dofile("mods/balatrobot/agent/ui/widgets.lua")
  Widgets.init({
    toast = {
      pick_lang = function() return { font = { FONT = { getWidth = function(_, t) return #t * 10 end, getHeight = function() return 10 end }, squish = 1, FONTSCALE = 0.1, TEXT_HEIGHT_SCALE = 1 } } end,
    },
  })

  local ReplayMenu = dofile("mods/balatrobot/agent/ui/replay_menu.lua")
  local pages = {}
  ReplayMenu.init({
    mod = { id = "balatrobot" },
    agent_menu = { menu_entries = {} },
    runner = { is_busy = function() return false end },
    mode = { apply = function() end },
    recorder = { enabled = false, get_prefix = function() return "" end, set_enabled = function() end, set_prefix = function() end },
    replay = { active = false, start = function() return true end },
    session = { begin = function() return true end, finish = function() end },
    library = Library,
    snapshot = {},
    format = Format,
    toast = { push = function() end },
    stream = { show_status = function() end },
    widgets = Widgets,
  })
  -- 列表页与确认页都生成一次: 用一个假条目走确认页.
  pages.list = function()
    G.FUNCS.bb_replay_list()
  end

  -- 收集 definition: overlay_menu 被调用时把定义留下
  local captured = nil
  G.FUNCS.overlay_menu = function(args)
    captured = args and args.definition
  end
  G.FUNCS.bb_replay_list()
  local list_def = captured

  --- 找出"竖直列表里 C 型节点后面还有兄弟"的地方.
  --- 参数既可以是节点, 也可以是节点数组 (定义树的顶层就是数组).
  ---@param node table
  ---@param path string
  ---@param found string[]
  local function scan(node, path, found)
    if type(node) ~= "table" then
      return
    end
    if not node.n then
      -- 数组: 逐个当节点处理, 这个层级本身没有容器语义
      for i, child in ipairs(node) do
        scan(child, string.format("%s<%d>", path, i), found)
      end
      return
    end
    local nodes = node.nodes
    if type(nodes) ~= "table" then
      return
    end
    for i, child in ipairs(nodes) do
      -- C 型子节点会把横向游标推出去, 而它后面的 R 型子节点只推进纵向、不重置横向游标,
      -- 于是那些 R 会整体右移. 纯 C 的容器 (例如横向排的按钮组) 不受影响, 不报.
      if type(child) == "table" and child.n == C then
        for j = i + 1, #nodes do
          local later = nodes[j]
          if type(later) == "table" and later.n == R then
            found[#found + 1] = string.format("%s: [%d] 是 C 型, 后面的 [%d] 是 R 型", path, i, j)
            break
          end
        end
      end
      scan(child, string.format("%s[%d]", path, i), found)
    end
  end

  local found = {}
  if list_def then
    scan(list_def.args and list_def.args.contents or list_def, "list", found)
  end
  check("列表页生成成功", list_def ~= nil)
  check("列表页没有 C 后面带 R 的布局", #found == 0, table.concat(found, "; "))

  -- 确认页: 找到列表里那行按钮的点击回调并触发它, 这样确认页的定义会真的被构建出来再受检查.
  ---@param node table
  ---@return fun()?
  local function find_on_click(node)
    if type(node) ~= "table" then
      return nil
    end
    local ref = node.config and node.config.ref_table
    if ref and type(ref.on_click) == "function" then
      return ref.on_click
    end
    -- 节点数组 (定义顶层) 与子节点都按顺序找, 第一个按钮就是第一行回放
    for _, child in ipairs(node.n and (node.nodes or {}) or node) do
      local found_fn = find_on_click(child)
      if found_fn then
        return found_fn
      end
    end
    return nil
  end

  local clicked = list_def and find_on_click(list_def.args and list_def.args.contents or list_def)
  check("列表行有点击回调", clicked ~= nil)
  local confirm_def = nil
  if clicked then
    clicked()
    confirm_def = captured
  end
  check("确认页生成成功", confirm_def ~= nil and confirm_def ~= list_def)

  local confirm_found = {}
  if confirm_def then
    scan(confirm_def.args and confirm_def.args.contents or confirm_def, "confirm", confirm_found)
  end
  check("确认页没有 C 后面带 R 的布局", #confirm_found == 0, table.concat(confirm_found, "; "))
end

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("回放列表全部通过")
