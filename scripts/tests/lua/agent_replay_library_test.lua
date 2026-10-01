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

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("回放列表全部通过")
