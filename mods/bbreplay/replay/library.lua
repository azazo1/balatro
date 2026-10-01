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

--- 文件读不出或解析不了时只有 name, ok, reason.
---@class BBReplayEntry
---@field name string 文件名
---@field ok boolean 能不能回放
---@field reason string? 不能回放的原因
---@field started string? 原局开始时间 (ISO 8601 UTC)
---@field deck string? 牌组
---@field stake string? 赌注
---@field seed string? 种子
---@field steps integer? 步数
---@field duration integer? 原局时长 (秒)
---@field result string? 结果的说明
---@field ante integer? 最后的底注
---@field manual_inputs integer? 原局里手动操作的次数
---@field resumed boolean? 是否读档开局

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

--- recorded_at (log.lua 按 UTC 写的 2024-05-01T12:00:00Z) 转显示用的时间, 不换算时区.
---@param iso string?
---@return string
local function time_text(iso)
  if type(iso) ~= "string" then
    return "未知时间"
  end
  local y, m, d, hh, mm = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")
  if not y then
    return iso
  end
  return string.format("%s-%s-%s %s:%s UTC", y, m, d, hh, mm)
end

--- 从最后一步的状态摘要里取底注. 摘要是 "state=... ante=3 round=2 ..." 这种格式.
---@param actions table[]
---@return integer?
local function ante_of(actions)
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
---@param actions table[]
---@return integer
local function duration_of(actions)
  for i = #actions, 1, -1 do
    local wall = actions[i].wall_end or actions[i].wall
    if type(wall) == "number" then
      return wall
    end
  end
  return 0
end

-- 不改变对局的步骤: 解说, 关解锁通知, 以及弹窗上的去向选择 (回主菜单, 无尽模式).
local NO_PLAY = { notify = true, continue = true, menu = true, endless = true }

--- 会改变对局的步骤数 (出牌, 购买, 排序等, agent 与手动都算).
---
--- 旧版本只记手动操作的次数, 手动打的局里只剩末尾回主菜单那一步, 回放一开局就结束, 据此判为不可回放.
---@param data table
---@return integer
function M.play_steps(data)
  local count = 0
  for _, action in ipairs(data.actions or {}) do
    if not NO_PLAY[action.method] then
      count = count + 1
    end
  end
  return count
end

--- 解析出的回放数据转成列表项. 不能回放时 ok 为 false, reason 是中文原因.
---@param data table 回放文件内容 (已解码)
---@param supported_version integer 当前支持的版本号
---@param is_tutorial (fun(run: table): boolean)? 是不是教程局 (format.is_tutorial)
---@return BBReplayEntry
function M.describe(data, supported_version, is_tutorial)
  local run = type(data.run) == "table" and data.run or {}
  local actions = type(data.actions) == "table" and data.actions or {}
  local entry = {
    steps = #actions,
    manual_inputs = data.manual_inputs or 0,
    started = data.recorded_at,
    duration = duration_of(actions),
    ante = ante_of(actions),
    deck = DECK_CN[run.deck] or run.deck or run.deck_key or "?",
    stake = STAKES_CN[run.stake] or run.stake or "?",
    seed = run.seed or "随机",
    resumed = run.resumed == true,
  }
  if data.result then
    entry.result = data.result.won == true and "胜利" or "未胜利"
  else
    entry.result = "未记录结果"
  end

  -- 与 player.lua 的 read_data 同样的判断, 加上没有可重做操作的局.
  local reason
  if data.version ~= supported_version then
    reason = string.format("回放文件版本 %s, 当前只支持 %d", tostring(data.version), supported_version)
  elseif type(data.run) ~= "table" or type(data.actions) ~= "table" then
    reason = "回放文件格式不对"
  elseif run.challenge then
    reason = "挑战模式的局不支持回放"
  elseif is_tutorial and is_tutorial(run) then
    reason = "教程局不支持回放"
  elseif not run.resumed and not (run.deck and run.stake and run.seed) then
    reason = "只支持原版牌组的局"
  elseif M.play_steps(data) == 0 then
    reason = (data.manual_inputs or 0) > 0 and "旧版本录的手动局, 没有记下具体操作" or "没有可以重做的操作"
  end
  entry.ok = reason == nil
  entry.reason = reason
  return entry
end

---@param fs BBReplayFS
---@param name string
---@param decode fun(text: string): table?
---@param supported_version integer
---@param is_tutorial (fun(run: table): boolean)?
---@return BBReplayEntry
local function describe_file(fs, name, decode, supported_version, is_tutorial)
  local text = fs.read(name)
  if not text or text == "" then
    return { ok = false, reason = "读不到文件" }
  end
  local ok, decoded = pcall(decode, text)
  if not ok or type(decoded) ~= "table" then
    return { ok = false, reason = "文件损坏或不是回放文件" }
  end
  return M.describe(decoded, supported_version, is_tutorial)
end

--- 扫描一遍目录, 用缓存跳过没变的文件. 按开始时间倒序.
---@param fs BBReplayFS
---@param options {supported_version: integer, decode: fun(text: string): table?, is_tutorial: (fun(run: table): boolean)?, cache: table?, log: fun(text: string)?}
---@return BBReplayEntry[] entries
---@return table cache 传回给下一次调用, 只留这次还在的文件
function M.list(fs, options)
  local cache = options.cache or {}
  local fresh = {}
  local entries = {}
  for _, file in ipairs(fs.list()) do
    -- 文件改名或重写都会换键
    local key = string.format("%s|%d|%d", file.name, file.size, file.mtime)
    local entry = cache[key]
    if not entry then
      entry = describe_file(fs, file.name, options.decode, options.supported_version, options.is_tutorial)
      entry.name = file.name
      if options.log then
        options.log(string.format("%s: %s", file.name, entry.ok and "可回放" or ("不可回放: " .. entry.reason)))
      end
    end
    fresh[key] = entry
    entries[#entries + 1] = entry
  end
  -- 开始时间相同 (或都缺) 时按文件名, 让顺序稳定.
  table.sort(entries, function(a, b)
    local sa, sb = a.started or "", b.started or ""
    if sa ~= sb then
      return sa > sb
    end
    return a.name < b.name
  end)
  return entries, fresh
end

-- 一局在录像目录里的文件: <stem> 加这些后缀. 与 record/recorder.lua, record/post.lua 和
-- balatrobot 的转录 (<stem>-agent.jsonl) 的命名一致. 中间文件只在崩溃或合成失败时才会留下.
local RUN_SUFFIXES = {
  ".replay.json",
  "-full.mp4",
  "-cut.mp4",
  ".json", -- 时间轴
  "-agent.jsonl",
  ".video.mp4",
  ".pcm",
  ".ffmpeg.txt",
  ".post.sh",
  ".post.cmd",
}

--- 删除一个回放时要删掉的文件名 (不含目录): 这一局的回放文件, 两份视频, 时间轴, agent 转录与残留的中间文件.
--- 只按固定后缀拼出完整文件名, 不做通配, 同一局的其它段 (<stem>-2 等) 不会被带上.
--- name 不是 <stem>.replay.json, 或者带路径分隔符时返回 nil.
---@param name string 回放文件名
---@return string[]?
function M.run_files(name)
  local stem = type(name) == "string" and name:match("^(.+)%.replay%.json$")
  if not stem or stem:find("[/\\]") or stem == "." or stem == ".." then
    return nil
  end
  local files = {}
  for i, suffix in ipairs(RUN_SUFFIXES) do
    files[i] = stem .. suffix
  end
  return files
end

--- 分页. 页码从 1 起, 越界时收敛到有效范围.
---@param entries table[]
---@param page integer
---@param per_page integer
---@return table items
---@return integer page 实际页码
---@return integer pages 总页数
function M.paginate(entries, page, per_page)
  local total = #entries
  local pages = math.max(1, math.ceil(total / per_page))
  page = math.min(math.max(1, math.floor(page)), pages)
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
    time_text(entry.started),
    entry.deck,
    entry.stake,
    entry.seed,
    entry.result,
    ante,
    entry.steps,
    M.duration_text(entry.duration)
  )
end

return M
