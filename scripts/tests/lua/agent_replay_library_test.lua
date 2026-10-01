-- 游戏内回放列表的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 覆盖可不可回放的判断, 扫描与缓存, 分页, 以及回放菜单的布局结构.

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
local function replay_data()
  return {
    version = Format.VERSION,
    recorded_at = "2024-05-01T12:34:56Z",
    run = { deck = "RED", stake = "WHITE", seed = "ABCD", resumed = false },
    manual_inputs = 0,
    actions = {
      { method = "play", wall = 1, wall_end = 2.5, ok = true, digest = "state=SELECTING_HAND ante=1 round=1 money=4" },
      { method = "next_round", wall = 3, wall_end = 4, ok = true, digest = "state=SHOP ante=2 round=2 money=7" },
    },
    result = { reason = "menu", won = false },
  }
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
  local entry = Library.describe(replay_data(), Format.VERSION)
  check("解析: 可回放", entry.ok == true, entry.reason)
  check("解析: 底注取最后一步的摘要", entry.ante == 2, tostring(entry.ante))
  check("解析: 时长取最后一步完成时间", entry.duration == 4, tostring(entry.duration))

  -- 读档开局不要求牌组与种子
  local data = replay_data()
  data.run = { resumed = true, save = "return {}" }
  check("解析: 读档开局可回放", Library.describe(data, Format.VERSION).ok == true)
end

do
  local cases = {
    { name = "版本不支持", patch = function(d) d.version = 99 end },
    { name = "挑战模式", patch = function(d) d.run.challenge = "c_x" end },
    { name = "非原版牌组", patch = function(d) d.run.deck = nil end },
    { name = "缺少动作", patch = function(d) d.actions = nil end },
    -- 真机上的手动教程局: 只有末尾回主菜单那一步, 回放一开局就结束
    {
      name = "手动打的局",
      patch = function(d)
        d.manual_inputs = 22
        d.actions = { { method = "notify", ok = true }, { method = "menu", manual = true, ok = true } }
      end,
    },
  }
  for _, case in ipairs(cases) do
    local data = replay_data()
    case.patch(data)
    local entry = Library.describe(data, Format.VERSION)
    check("不可回放: " .. case.name, entry.ok == false and entry.reason ~= nil)
  end
end

do
  -- 扫描: 坏文件不炸, 按时间倒序
  local newer = replay_data()
  newer.recorded_at = "2025-01-01T00:00:00Z"
  local files = {
    ["a.replay.json"] = { text = json.encode(replay_data()), size = 10, mtime = 1 },
    ["b.replay.json"] = { text = "{ 不是 json", size = 5, mtime = 2 },
    ["c.replay.json"] = { text = "", size = 0, mtime = 3 },
    ["d.replay.json"] = { text = json.encode(newer), size = 11, mtime = 4 },
  }
  local entries, cache = Library.list(fs_for(files), {
    supported_version = Format.VERSION,
    decode = json.decode,
  })
  check("扫描: 四个文件都在", #entries == 4, tostring(#entries))
  check("扫描: 最新的排前面", entries[1].name == "d.replay.json", entries[1].name)
  local by_name = {}
  for _, entry in ipairs(entries) do
    by_name[entry.name] = entry
  end
  check("扫描: 空文件与坏 json 不可回放", by_name["c.replay.json"].ok == false and by_name["b.replay.json"].ok == false)

  local hits = 0
  local function counting_decode(text)
    hits = hits + 1
    return json.decode(text)
  end
  Library.list(fs_for(files), { supported_version = Format.VERSION, decode = counting_decode, cache = cache })
  check("缓存: 内容没变就不重新解析", hits == 0, tostring(hits))

  -- 文件重写: 大小或时间变了要重新解析
  files["a.replay.json"].size, files["a.replay.json"].mtime = 99, 5
  Library.list(fs_for(files), { supported_version = Format.VERSION, decode = counting_decode, cache = cache })
  check("缓存: 文件变了要重新解析", hits == 1, tostring(hits))
end

do
  local entries = {}
  for i = 1, 13 do
    entries[i] = { name = i .. ".replay.json", ok = true }
  end
  local items, page, pages = Library.paginate(entries, 3, 6)
  check("分页: 最后一页 1 行", pages == 3 and page == 3 and #items == 1 and items[1].name == "13.replay.json")
  local _, high = Library.paginate(entries, 99, 6)
  check("分页: 页码越界收敛到最后一页", high == 3, tostring(high))
  local _, low = Library.paginate(entries, -2, 6)
  check("分页: 页码下界收敛到第一页", low == 1, tostring(low))
end

do -- 回放菜单的布局: 竖直列表里不能出现"C 型节点后面还有兄弟"
  -- 布局引擎 (game/engine/ui.lua) 遍历子节点时, C 型子节点把横向游标往右推, 而 R 型子节点只推进
  -- 纵向且不重置横向游标. 所以 C 后面再有兄弟, 那些兄弟就会右移, 可能整行跑到面板外面.
  -- 这个错误在开发机上肉眼看不到 (要真机截图), 只能靠结构检查兜住.
  local UIT = { T = 1, C = 3, R = 4 }
  local C, R = UIT.C, UIT.R

  -- 假 G/SMODS/love, 只为让 replay_menu 能加载并生成定义.
  love = { filesystem = { getSaveDirectory = function() return "/tmp/bb" end } }
  G = {
    UIT = UIT,
    TILESIZE = 20,
    TILESCALE = 1,
    C = {
      FILTER = { 1, 1, 1, 1 },
      RED = { 1, 0, 0, 1 },
      GREEN = { 0, 1, 0, 1 },
      L_BLACK = { 0, 0, 0, 1 },
      UI = { TEXT_LIGHT = { 1, 1, 1, 1 }, TEXT_INACTIVE = { 0.5, 0.5, 0.5, 1 } },
    },
    FUNCS = {},
    SETTINGS = {},
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
  sendDebugMessage = function() end

  -- widgets 量文字宽度要用 toast.pick_lang 给的字体
  local Widgets = dofile("mods/balatrobot/agent/ui/widgets.lua")
  Widgets.init({
    toast = {
      pick_lang = function() return { font = { FONT = { getWidth = function(_, t) return #t * 10 end }, squish = 1, FONTSCALE = 0.1 } } end,
    },
  })

  local ReplayMenu = dofile("mods/balatrobot/agent/ui/replay_menu.lua")
  ReplayMenu.init({
    agent_menu = { menu_entries = {} },
    library = Library,
    format = Format,
    widgets = Widgets,
  })

  -- overlay_menu 被调用时把定义留下
  local captured = nil
  G.FUNCS.overlay_menu = function(args)
    captured = args.definition
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
      -- 纯 C 的容器 (例如横向排的按钮组) 不受影响, 只报 C 后面跟着 R 的情况.
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
  scan(list_def.args.contents, "list", found)
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

  local clicked = find_on_click(list_def.args.contents)
  local confirm_found = {}
  if clicked then
    clicked()
    if captured ~= list_def then
      scan(captured.args.contents, "confirm", confirm_found)
    end
  end
  check("确认页生成且没有 C 后面带 R 的布局", clicked ~= nil and captured ~= list_def and #confirm_found == 0, table.concat(confirm_found, "; "))
end

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("回放列表全部通过")
