--[[
回放列表: 扫描录像目录下的 *.replay.json, 解析出菜单要用的信息, 判断能不能回放.

回放文件里带存档快照, 可能很大, 所以这里只留列表用的字段 (见 describe), 解析出的完整表立刻丢掉,
真正开始时再由 player 重新读一遍文件. 解析结果按 文件名 + 大小 + 修改时间 缓存, 文件没变就不重复解析.

不依赖游戏: 目录与读文件都从外部注入 (见 BBReplayFS), 纯逻辑可以直接用 luajit 单测.
]]

local M = {}

---@class BBReplayFS
---@field list fun(): {name: string, size: integer, mtime: integer}[]
---@field read fun(name: string): string?

---@class BBReplayEntry
---@field name string 文件名
---@field ok boolean 能不能回放
---@field reason string? 不能回放的原因
---@field started string? 原局开始时间 (ISO 8601 UTC)
---@field deck string? 牌组
---@field stake string? 赌注
---@field seed string? 种子
---@field steps integer 步数
---@field duration integer 原局时长 (秒)
---@field won boolean?
---@field result string? 结果的说明
---@field ante integer? 最后的底注
---@field manual_inputs integer 原局里手动操作的次数
---@field resumed boolean 是否读档开局
---@field size integer? 文件大小
---@field mtime integer? 文件修改时间

local STAKES_CN = {
  WHITE = "白注",
  RED = "红注",
  GREEN = "绿注",
  BLACK = "黑注",
  BLUE = "蓝注",
  PURPLE = "紫注",
  ORANGE = "橙注",
  GOLD = "金注",
}

-- 原版牌组的枚举名 (format.deck_enum 的结果) 转中文. 非原版牌组不会到这里 (不可回放).
local DECK_CN = {
  RED = "红牌组",
  BLUE = "蓝牌组",
  YELLOW = "黄牌组",
  GREEN = "绿牌组",
  BLACK = "黑牌组",
  MAGIC = "魔术牌组",
  NEBULA = "星云牌组",
  GHOST = "幽灵牌组",
  ABANDONED = "废弃牌组",
  CHECKERED = "棋盘牌组",
  ZODIAC = "黄道牌组",
  PAINTED = "彩绘牌组",
  ANAGLYPH = "立体牌组",
  PLASMA = "等离子牌组",
  ERRATIC = "古怪牌组",
}

--- 缓存键: 文件改名或重写都会变.
---@param name string
---@param size integer
---@param mtime integer
---@return string
function M.cache_key(name, size, mtime)
  return string.format("%s|%d|%d", name, size, mtime)
end

--- 秒数转 "12 分 30 秒" / "45 秒".
---@param seconds number
---@return string
function M.duration_text(seconds)
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  local minutes = math.floor(seconds / 60)
  if minutes <= 0 then
    return seconds .. " 秒"
  end
  return string.format("%d 分 %d 秒", minutes, seconds % 60)
end

---@param iso string? 回放文件里的 recorded_at
---@return string 显示用的时间
function M.time_text(iso)
  if type(iso) ~= "string" then
    return "未知时间"
  end
  -- 2024-05-01T12:00:00Z 是本地时区的偏移, 这里按 UTC 换成统一格式, 不额外换算时区.
  local y, m, d, hh, mm = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")
  if not y then
    return iso
  end
  return string.format("%s-%s-%s %s:%s UTC", y, m, d, hh, mm)
end

--- 从最后一步的状态摘要里取底注. 摘要是 "state=... ante=3 round=2 ..." 这种格式.
---@param data table
---@return integer?
function M.ante_of(data)
  local actions = data.actions or {}
  for i = #actions, 1, -1 do
    local digest = actions[i].digest
    if type(digest) == "string" then
      local ante = tonumber(digest:match("ante=(%d+)"))
      if ante then
        return ante
      end
    end
  end
  return nil
end

--- 原局时长: 最后一步的完成时间, 没有时用最后一步的开始时间.
---@param data table
---@return integer
function M.duration_of(data)
  local actions = data.actions or {}
  for i = #actions, 1, -1 do
    local action = actions[i]
    local wall = action.wall_end or action.wall
    if type(wall) == "number" then
      return wall
    end
  end
  return 0
end

--- 解析出的回放数据转成列表项. 不能回放时 ok 为 false, reason 是中文原因.
---@param data table 回放文件内容 (已解码)
---@param supported_version integer 当前支持的版本号
---@return BBReplayEntry
function M.describe(data, supported_version)
  local entry = {
    steps = #(data.actions or {}),
    manual_inputs = data.manual_inputs or 0,
    started = data.recorded_at,
    duration = M.duration_of(data),
    ante = M.ante_of(data),
  }
  local run = data.run or {}
  entry.deck = DECK_CN[run.deck] or run.deck or run.deck_key or "?"
  entry.stake = STAKES_CN[run.stake] or run.stake or "?"
  entry.seed = run.seed or "随机"
  entry.resumed = run.resumed == true
  if data.result then
    entry.won = data.result.won == true
    entry.result = entry.won and "胜利" or "未胜利"
  else
    entry.result = "未记录结果"
  end

  local reason
  if data.version ~= supported_version then
    reason = string.format("回放文件版本 %s, 当前只支持 %d", tostring(data.version), supported_version)
  elseif type(run) ~= "table" or type(data.actions) ~= "table" then
    reason = "回放文件格式不对"
  elseif run.challenge then
    reason = "挑战模式的局不支持回放"
  elseif not run.resumed and not (run.deck and run.stake and run.seed) then
    reason = "只支持原版牌组的局"
  end
  entry.ok = reason == nil
  entry.reason = reason
  return entry
end

--- 扫描一遍目录, 用缓存跳过没变的文件. 按开始时间倒序.
---@param fs BBReplayFS
---@param options {supported_version: integer, decode: fun(text: string): table?, cache: table?, log: fun(text: string)?}
---@return BBReplayEntry[] entries
---@return table cache 传回给下一次调用
function M.list(fs, options)
  local cache = options.cache or {}
  local fresh = {}
  local entries = {}
  local files = fs.list()
  table.sort(files, function(a, b)
    return a.name < b.name
  end)
  for _, file in ipairs(files) do
    local key = M.cache_key(file.name, file.size, file.mtime)
    local entry = cache[key]
    if not entry then
      entry = M.describe_file(fs, file, options)
      if options.log then
        options.log(string.format("%s: %s", file.name, entry.ok and "可回放" or ("不可回放: " .. tostring(entry.reason))))
      end
    end
    fresh[key] = entry
    entry.name = file.name
    entry.size = file.size
    entry.mtime = file.mtime
    entries[#entries + 1] = entry
  end
  table.sort(entries, function(a, b)
    return (a.started or "") > (b.started or "")
  end)
  return entries, fresh
end

---@param fs BBReplayFS
---@param file {name: string, size: integer, mtime: integer}
---@param options {supported_version: integer, decode: fun(text: string): table?}
---@return BBReplayEntry
function M.describe_file(fs, file, options)
  local text = fs.read(file.name)
  if not text or text == "" then
    return { ok = false, reason = "读不到文件", steps = 0, manual_inputs = 0 }
  end
  local ok, decoded = pcall(options.decode, text)
  if not ok or type(decoded) ~= "table" then
    return { ok = false, reason = "文件损坏或不是回放文件", steps = 0, manual_inputs = 0 }
  end
  return M.describe(decoded, options.supported_version)
end

--- 分页. 页码从 1 起, 越界时收敛到有效范围.
---@param entries table[]
---@param page integer?
---@param per_page integer
---@return table items
---@return integer page 实际页码
---@return integer pages 总页数
function M.paginate(entries, page, per_page)
  per_page = math.max(1, per_page or 6)
  local total = #entries
  local pages = math.max(1, math.ceil(total / per_page))
  page = math.floor(page or 1)
  if page < 1 then
    page = 1
  elseif page > pages then
    page = pages
  end
  local items = {}
  for i = (page - 1) * per_page + 1, math.min(page * per_page, total) do
    items[#items + 1] = entries[i]
  end
  return items, page, pages
end

--- 一行列表项的显示文字.
---@param entry BBReplayEntry
---@return string
function M.line_text(entry)
  if not entry.ok then
    return string.format("%s | 不可回放: %s", entry.name, entry.reason)
  end
  local ante = entry.ante and string.format(", 底注 %d", entry.ante) or ""
  return string.format(
    "%s | %s | %s | 种子 %s | %s%s | %d 步 | %s",
    M.time_text(entry.started),
    entry.deck or "?",
    entry.stake or "?",
    entry.seed or "随机",
    entry.result or "?",
    ante,
    entry.steps,
    M.duration_text(entry.duration)
  )
end

return M
