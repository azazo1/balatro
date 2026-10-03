-- 游戏内回放列表的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 覆盖可不可回放的判断, 扫描与缓存, 开始时间的时区换算, 分页, 以及回放菜单的布局结构.

package.path = "mods/Steamodded/libs/json/?.lua;" .. package.path
local json = require("json")
local DIR = "mods/bbreplay/replay/"
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

do -- 模型来源是可选元数据, 不影响回放有效性, 不保留无关字段.
  local data = replay_data()
  data.agents = {
    { endpoint = "https://one.example/v1", model = "model-one", api_key = "不能进入列表" },
    { endpoint = "https://two.example/v1", model = "model-two" },
    false,
    { model = {} },
  }
  local entry = Library.describe(data, Format.VERSION)
  check("提取多个模型来源且不保留敏感字段", entry.ok and #entry.agents == 2
    and entry.agents[1].endpoint == data.agents[1].endpoint and entry.agents[2].model == "model-two"
    and entry.agents[1].api_key == nil)
  check("旧回放没有模型元数据仍可回放", #Library.describe(replay_data(), Format.VERSION).agents == 0)
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

do -- 新版本录下的手动局: 出牌等手动步骤可以重做
  local data = replay_data()
  data.actions = {
    { method = "select", manual = true, ok = true },
    { method = "play", params = { cards = { 0, 1 } }, manual = true, ok = true },
    { method = "menu", manual = true, ok = true },
  }
  local entry = Library.describe(data, Format.VERSION)
  check("可回放: 手动步骤", entry.ok == true, entry.reason)
end

do -- 教程局: 强制内容是写死的常量, 回放前按录像里的教程状态重建, 所以可以回放
  local data = replay_data()
  data.run.tutorial = true
  data.run.seed = "TUTORIAL"
  local entry = Library.describe(data, Format.VERSION)
  check("可回放: 教程局", entry.ok == true, entry.reason)
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

do -- 开始时间按本机时区显示: 把本地时刻写成 UTC 的 ISO 串, 再换回来应当还是那一刻
  local cases = {
    { year = 2026, month = 1, day = 15, hour = 12, min = 0 }, -- 冬令时一侧
    { year = 2026, month = 7, day = 15, hour = 12, min = 0 }, -- 夏令时一侧
  }
  for _, fields in ipairs(cases) do
    fields.sec = 0
    local epoch = os.time(fields)
    local iso = os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
    local want = os.date("%Y-%m-%d %H:%M", epoch)
    check(string.format("时间: 按本地时区换算 (%s)", iso), Library.time_text(iso) == want, Library.time_text(iso) .. " ~= " .. want)
  end
  check("时间: 没有行内的 UTC 标记", not Library.time_text("2024-05-01T12:34:56Z"):find("UTC"))
  check("时间: 少了秒也认", Library.time_text("2024-05-01T12:34Z") == Library.time_text("2024-05-01T12:34:00Z"))
  check("时间: 缺字段时说不认识", Library.time_text(nil) == "未知时间" and Library.time_text("随便") == "随便")
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

do -- 一局的位置: 每局一个文件夹与旧版平铺都认, 删除只支持前者
  local location = Library.locate("20261001-162556-SPLIT01/20261001-162556-SPLIT01.replay.json")
  local set = {}
  for _, name in ipairs(location and location.names or {}) do
    set[name] = true
  end
  check("认文件夹里的回放文件", location and location.folder == "20261001-162556-SPLIT01")
  check("局名与文件夹名一致", location and location.stem == "20261001-162556-SPLIT01")
  check(
    "这一局的产物: 回放, 视频, 时间轴与转录",
    set["20261001-162556-SPLIT01.replay.json"] and set["20261001-162556-SPLIT01-full.mp4"]
      and set["20261001-162556-SPLIT01.json"]
      and set["20261001-162556-SPLIT01-agent.jsonl"] and set["20261001-162556-SPLIT01.video.mp4"] or false
  )
  local escaped = false
  for _, name in ipairs(location and location.names or {}) do
    escaped = escaped or name:find("[/\\]") ~= nil or not name:find("^20261001%-162556%-SPLIT01[%.%-]")
  end
  check("产物名都不带路径, 都属于这一局", not escaped)
  check("文件夹布局可以删", Library.deletable(location))

  local flat = Library.locate("20261001-162556-SPLIT01.replay.json")
  check("认旧版平铺的回放文件", flat and flat.folder == nil and flat.stem == "20261001-162556-SPLIT01")
  check("旧版平铺不支持删除", not Library.deletable(flat))

  check(
    "不是回放文件时不认",
    Library.locate("a.json") == nil and Library.locate("../x.replay.json") == nil
      and Library.locate("sub\\x.replay.json") == nil and Library.locate(".replay.json") == nil
      and Library.locate(nil) == nil
  )
  check("文件名与文件夹名不一致时不认", Library.locate("随便/x.replay.json") == nil)
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
      UI = { TEXT_LIGHT = { 1, 1, 1, 1 }, TEXT_INACTIVE = { 0.5, 0.5, 0.5, 1 }, BACKGROUND_INACTIVE = { 0.3, 0.3, 0.3, 1 } },
    },
    FUNCS = {},
    SETTINGS = {},
  }
  local fake_data = replay_data()
  fake_data.agents = { { endpoint = "https://one.example/v1", model = "model-one" } }
  local fake_replay = json.encode(fake_data)
  -- 录像目录: 一个新布局 (每局一个文件夹) 与一个旧版平铺的回放文件. 按 kind 返回目录或文件.
  -- BROKEN 那个在文件夹里, 用来验证损坏的行也点得进确认页.
  SMODS = {
    NFS = {
      getDirectoryItemsInfo = function(path, kind)
        if kind == "directory" then
          return { { name = "20240501-123456-ABCD" } }
        end
        if path:find("20240501%-123456%-ABCD") then
          return { { name = "20240501-123456-ABCD.replay.json", size = #fake_replay, modtime = 1000 } }
        end
        return { { name = "20240501-000000-BROKEN.replay.json", size = 3, modtime = 1000 } }
      end,
      read = function(path)
        return path:find("BROKEN", 1, true) and "{{{" or fake_replay
      end,
    },
  }
  create_UIBox_generic_options = function(args) return { args = args } end
  sendDebugMessage = function() end

  -- widgets 量文字宽度要用 toast.pick_lang 给的字体
  local Widgets = dofile("mods/bbcore/ui/widgets.lua")
  Widgets.init({
    toast = {
      pick_lang = function() return { font = { FONT = { getWidth = function(_, t) return #t * 10 end }, squish = 1, FONTSCALE = 0.1 } } end,
    },
  })

  local ReplayMenu = dofile("mods/bbreplay/ui/replay_menu.lua")
  ReplayMenu.init({
    menu = { entries = {} },
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
  local rendered = {}
  local function collect_text(node)
    if type(node) ~= "table" then
      return
    end
    if node.config and type(node.config.text) == "string" then
      rendered[#rendered + 1] = node.config.text
    end
    for _, child in ipairs(node.n and (node.nodes or {}) or node) do
      collect_text(child)
    end
  end
  collect_text(captured.args.contents)
  local text = table.concat(rendered, "\n")
  check("确认页显示原局记录而非当前配置", text:find(fake_data.agents[1].model, 1, true)
    and text:find(fake_data.agents[1].endpoint, 1, true))

  -- 不能回放的行 (这里是损坏的文件) 仍能点进确认页, 才能删除它.
  --- 按顺序收集所有按钮的引用表.
  local function collect_refs(node, out)
    if type(node) ~= "table" then
      return out
    end
    local ref = node.config and node.config.ref_table
    if ref and type(ref.on_click) == "function" then
      out[#out + 1] = ref
    end
    for _, child in ipairs(node.n and (node.nodes or {}) or node) do
      collect_refs(child, out)
    end
    return out
  end
  G.FUNCS.bb_replay_list()
  local broken
  for _, ref in ipairs(collect_refs(captured.args.contents, {})) do
    if tostring(ref.label):find("BROKEN", 1, true) then
      broken = ref
    end
  end
  local enabled = broken and (broken.enabled == nil or broken.enabled())
  local ok, err = false, "列表里没有损坏文件那一行"
  if broken then
    captured = nil
    ok, err = pcall(broken.on_click)
  end
  check("不能回放的行可以点进确认页", enabled and ok and captured ~= nil, tostring(err))

  -- 删除按钮: 每局一个文件夹的可以删 (删掉整个文件夹), 旧版平铺的不给删, 免得误删别的局.
  ---@param definition table
  ---@return table?
  local function delete_ref_of(definition)
    for _, ref in ipairs(collect_refs(definition.args.contents, {})) do
      if tostring(ref.label) == "删除" then
        return ref
      end
    end
    return nil
  end

  captured = nil
  clicked()
  local folder_entry_delete = captured and delete_ref_of(captured)
  check("文件夹布局的删除按钮可以点", folder_entry_delete ~= nil and folder_entry_delete.enabled())

  G.FUNCS.bb_replay_list()
  local flat
  for _, ref in ipairs(collect_refs(captured.args.contents, {})) do
    if tostring(ref.label):find("BROKEN", 1, true) then
      flat = ref
    end
  end
  captured = nil
  if flat then
    flat.on_click()
  end
  local flat_delete = captured and delete_ref_of(captured)
  check("旧版平铺的删除按钮不可点", flat_delete ~= nil and not flat_delete.enabled())
end

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("回放列表全部通过")
