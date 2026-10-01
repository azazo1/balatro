--[[
游戏手册 (打包自 docs/game/) 的纯逻辑部分, 不依赖 G/SMODS, 单测直接加载.

- 路径: 只接受手册根目录下的相对路径, 反斜杠转斜杠, 拒绝 .. 与绝对路径.
- 索引: 手册内全部 .md 文件的路径, 一级标题和行数, 附 README 的 "按决策查阅" 表.
- 读取: 按 section (标题文字, 标题 slug 或锚点 id) 切章节, offset/limit 分页.
  大文件不带 section/offset 时只返回大纲.
- 搜索: 纯子串, 不区分大小写 (只对 ASCII), 结果为 "路径:行号: 内容".
- 链接改写: 指向手册内文件的相对链接改成相对手册根目录的路径, 模型可以直接拿去 docs_read;
  指向手册以外的链接 (源码位置, 未打包的文档, 网页) 改成 "文字 (目标)" 的纯文本.

文件访问由调用方注入: read(rel) 返回文件内容或 nil, list(rel) 返回目录项名数组, 子目录名以 "/" 结尾.
rel 是相对手册根目录的路径, 根目录本身为 "".
]]

local M = {}

-- 单次读取的行数与字节上限
M.MAX_LINES = 200
M.MAX_BYTES = 8192
-- 超过这个行数的文件, 不带 section/offset 时只返回大纲
M.OUTLINE_THRESHOLD = 300
-- 搜索默认与最多返回的条数
M.SEARCH_DEFAULT = 20
M.SEARCH_MAX = 100
-- 搜索结果每行保留的字节数 (按 UTF-8 字符边界截取)
M.CLIP_BYTES = 200

-- 手册在仓库里的位置, 用于把指向手册外的链接写成相对仓库根目录的路径.
local REPO_PREFIX = { "docs", "game" }
-- 手册的范围与索引里目录的排列顺序 (与 README 的阅读顺序一致). 与打包时复制的内容一致
-- (scripts/lib/modding/build.py 的 KNOWLEDGE_ITEMS), 直接读仓库的 docs/game/ 时也不会多出 sources.md 等文件.
local ROOT_FILES = { ["README.md"] = true }
local DIR_ORDER = { [""] = 0, rules = 1, mechanics = 2, cards = 3, data = 4 }
local MAX_DEPTH = 4

local ANCHOR_PATTERN = '<a%s+id="([^"]+)"%s*>%s*</a>'

-- ---------------------------------------------------------------- 路径

--- 校验并规范化手册内的相对路径. 失败时返回 nil 与原因.
---@param path any
---@return string? rel
---@return string? err
function M.normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil, "Path must be a non-empty string"
  end
  local p = path:gsub("\\", "/")
  if p:sub(1, 1) == "/" or p:sub(1, 1) == "~" or p:match("^%a:") then
    return nil, "Absolute paths are not allowed: " .. path
  end
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      return nil, "'..' is not allowed in path: " .. path
    end
    if seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  if #parts == 0 then
    return nil, "Path must point into the manual: " .. path
  end
  return table.concat(parts, "/")
end

---@param path string
---@return string
local function dirname(path)
  return path:match("^(.*)/[^/]*$") or ""
end

--- 把 dir 下的相对目标拼成相对手册根目录的路径. up 为越过手册根目录的层数.
---@param dir string
---@param target string
---@return string joined
---@return integer up
local function join(dir, target)
  local parts = {}
  for seg in dir:gmatch("[^/]+") do
    parts[#parts + 1] = seg
  end
  local up = 0
  for seg in target:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 then
        parts[#parts] = nil
      else
        up = up + 1
      end
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return table.concat(parts, "/"), up
end

-- ---------------------------------------------------------------- 文本

---@param text string
---@return string[]
local function split_lines(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  if text == "" then
    return lines
  end
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  for line in text:gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return lines
end
M.split_lines = split_lines

--- 按 UTF-8 字符边界截取 line 中 [from, to] 附近 width 字节的片段, 两端被截时加 "...".
---@param line string
---@param from integer 命中起点 (字节)
---@param to integer 命中终点 (字节)
---@param width integer
---@return string
function M.clip(line, from, to, width)
  if #line <= width then
    return line
  end
  local span = to - from + 1
  local start = math.max(1, from - math.floor((width - span) / 2))
  local stop = math.min(#line, start + width - 1)
  start = math.max(1, math.min(start, stop - width + 1))
  -- 起点移到字符首字节, 终点移到字符末字节
  while start > 1 and line:byte(start) >= 0x80 and line:byte(start) < 0xC0 do
    start = start + 1
  end
  while stop < #line and line:byte(stop + 1) >= 0x80 and line:byte(stop + 1) < 0xC0 do
    stop = stop - 1
  end
  local out = line:sub(start, stop)
  if start > 1 then
    out = "..." .. out
  end
  if stop < #line then
    out = out .. "..."
  end
  return out
end

--- GitHub 风格的标题 slug: 小写, 去掉 ASCII 标点, 空格换成 "-", 非 ASCII 字符保留.
---@param text string
---@return string
function M.slug(text)
  local s = text:gsub("<[^>]*>", ""):gsub("%[([^%]]*)%]%b()", "%1"):lower()
  s = s:gsub("[%p]", function(c)
    if c == "-" or c == "_" then
      return c
    end
    return ""
  end)
  return (s:gsub(" ", "-"))
end

--- 改写一行中的 markdown 链接.
---@param line string
---@param path string 当前文件, 相对手册根目录
---@param files table<string, boolean> 手册内可读的文件
---@return string
function M.rewrite_links(line, path, files)
  local dir = dirname(path)
  local function convert(text, target)
    -- 网页等带协议的链接原样保留
    if target:match("^%a[%w+.-]*:") then
      return nil
    end
    local target_path, frag = target:match("^([^#]*)#?(.*)$")
    local suffix = frag ~= "" and ("#" .. frag) or ""
    if target_path == "" then
      return "[" .. text .. "](<" .. path .. suffix .. ">)"
    end
    if target_path:sub(1, 1) == "/" then
      return text .. " (" .. target .. ")"
    end
    local joined, up = join(dir, target_path)
    if up == 0 and files[joined] then
      return "[" .. text .. "](<" .. joined .. suffix .. ">)"
    end
    -- 手册外: 写成相对仓库根目录的路径, 算不出来时保留原目标
    if up > #REPO_PREFIX then
      return text .. " (" .. target .. ")"
    end
    local prefix = {}
    for i = 1, #REPO_PREFIX - up do
      prefix[i] = REPO_PREFIX[i]
    end
    if joined ~= "" then
      prefix[#prefix + 1] = joined
    end
    return text .. " (" .. table.concat(prefix, "/") .. suffix .. ")"
  end
  line = line:gsub("%[([^%[%]]*)%]%(<([^>]*)>%)", function(text, target)
    return convert(text, target)
  end)
  line = line:gsub("%[([^%[%]]*)%]%(([^%s%(%)<>]+)%)", function(text, target)
    return convert(text, target)
  end)
  return line
end

-- ---------------------------------------------------------------- 大纲

---@class Knowledge.Heading
---@field line integer
---@field level integer
---@field text string
---@field end_line integer 章节最后一行

---@class Knowledge.Anchor
---@field line integer
---@field id string

--- 解析标题 (跳过代码块) 与锚点, 算出每个标题的章节范围.
---@param lines string[]
---@return Knowledge.Heading[] headings
---@return Knowledge.Anchor[] anchors
local function parse_outline(lines)
  local headings, anchors = {}, {}
  local fence = false
  for i, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fence = not fence
    elseif not fence then
      local hashes, text = line:match("^(#+)%s+(.-)%s*#*%s*$")
      if hashes and #hashes <= 6 then
        headings[#headings + 1] = { line = i, level = #hashes, text = text }
      end
      for id in line:gmatch(ANCHOR_PATTERN) do
        anchors[#anchors + 1] = { line = i, id = id }
      end
    end
  end
  for i, h in ipairs(headings) do
    local stop = #lines
    for j = i + 1, #headings do
      if headings[j].level <= h.level then
        stop = headings[j].line - 1
        break
      end
    end
    -- 下一节的锚点行与空行不算本节
    while stop > h.line and (lines[stop]:match("^%s*$") or lines[stop]:match("^%s*" .. ANCHOR_PATTERN .. "%s*$")) do
      stop = stop - 1
    end
    h.end_line = stop
  end
  return headings, anchors
end

--- 锚点对应的标题: 锚点之后第一个标题, 中间只隔空行时才算.
---@param doc table
---@param anchor Knowledge.Anchor
---@return Knowledge.Heading?
local function anchor_heading(doc, anchor)
  for _, h in ipairs(doc.headings) do
    if h.line >= anchor.line then
      for i = anchor.line + 1, h.line - 1 do
        if not doc.lines[i]:match("^%s*$") then
          return nil
        end
      end
      return h
    end
  end
  return nil
end

---@param doc table
---@return string
local function outline_text(doc)
  local by_heading = {}
  local items = {}
  for _, a in ipairs(doc.anchors) do
    local h = anchor_heading(doc, a)
    if h then
      by_heading[h] = a.id
    else
      items[#items + 1] = { line = a.line, text = "{#" .. a.id .. "}" }
    end
  end
  for _, h in ipairs(doc.headings) do
    local text = string.rep("#", h.level) .. " " .. h.text
    if by_heading[h] then
      text = text .. " {#" .. by_heading[h] .. "}"
    end
    items[#items + 1] = { line = h.line, text = text }
  end
  table.sort(items, function(a, b)
    return a.line < b.line
  end)
  local out = {}
  for i, item in ipairs(items) do
    out[i] = item.line .. ": " .. item.text
  end
  return table.concat(out, "\n")
end

--- 按 section 找章节: 锚点 id, 标题 slug, 标题全文, 最后是唯一的标题子串.
---@param doc table
---@param query string
---@return {title: string, line: integer, end_line: integer}? section
---@return string[]? candidates 没找到或有歧义时的候选标题
local function find_section(doc, query)
  local q = query:gsub("^%s*#+%s*", ""):gsub("%s*{#[^}]*}%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  local function heading_section(h, start)
    return { title = h.text, line = start or h.line, end_line = h.end_line }
  end
  for _, a in ipairs(doc.anchors) do
    if a.id == q then
      local h = anchor_heading(doc, a)
      if h then
        return heading_section(h)
      end
      -- 锚点后面直接是正文: 章节到下一个标题为止
      local stop = #doc.lines
      for _, other in ipairs(doc.headings) do
        if other.line > a.line then
          stop = other.line - 1
          break
        end
      end
      return { title = "{#" .. a.id .. "}", line = a.line, end_line = stop }
    end
  end
  local lower = q:lower()
  local slug = M.slug(q)
  for _, h in ipairs(doc.headings) do
    if M.slug(h.text) == slug or h.text:lower() == lower then
      return heading_section(h)
    end
  end
  local hits = {}
  for _, h in ipairs(doc.headings) do
    if lower ~= "" and h.text:lower():find(lower, 1, true) then
      hits[#hits + 1] = h
    end
  end
  if #hits == 1 then
    return heading_section(hits[1])
  end
  local candidates = {}
  for i = 1, math.min(#hits, 10) do
    candidates[i] = hits[i].line .. ": " .. hits[i].text
  end
  return nil, candidates
end

-- ---------------------------------------------------------------- 手册

---@class Knowledge.Docs
---@field private _read fun(rel: string): string?
---@field private _list fun(rel: string): string[]?
local Store = {}
Store.__index = Store

--- 新建手册访问对象. 文件列表与内容在第一次用到时读取, 之后缓存.
---@param opts {read: fun(rel: string): string?, list: fun(rel: string): string[]?}
---@return Knowledge.Docs
function M.new(opts)
  return setmetatable({ _read = opts.read, _list = opts.list, _docs = {} }, Store)
end

--- 手册内全部 .md 文件, 按阅读顺序排列.
---@return string[]
function Store:files()
  if self._files then
    return self._files
  end
  local found = {}
  local function walk(dir, depth)
    local items = self._list(dir) or {}
    for _, name in ipairs(items) do
      local rel = dir == "" and name or (dir .. "/" .. name)
      if name:sub(-1) == "/" then
        local sub = rel:sub(1, -2)
        if depth < MAX_DEPTH and (dir ~= "" or DIR_ORDER[sub]) then
          walk(sub, depth + 1)
        end
      elseif name:lower():match("%.md$") and (dir ~= "" or ROOT_FILES[name]) then
        found[#found + 1] = rel
      end
    end
  end
  walk("", 1)
  local function rank(path)
    local dir = dirname(path)
    local top = dir:match("^[^/]+") or ""
    return DIR_ORDER[top] or 9, dir
  end
  table.sort(found, function(a, b)
    local ra, da = rank(a)
    local rb, db = rank(b)
    if ra ~= rb then
      return ra < rb
    end
    if da ~= db then
      return da < db
    end
    -- 同一目录里 README 排在最前
    local a_readme, b_readme = a:match("README%.md$") ~= nil, b:match("README%.md$") ~= nil
    if a_readme ~= b_readme then
      return a_readme
    end
    return a < b
  end)
  self._files = found
  self._file_set = {}
  for _, rel in ipairs(found) do
    self._file_set[rel] = true
  end
  return found
end

--- 读取并解析一个文件 (链接已改写). 文件不在手册里时返回 nil.
---@param rel string
---@return table?
function Store:doc(rel)
  local cached = self._docs[rel]
  if cached then
    return cached
  end
  self:files()
  if not self._file_set[rel] then
    return nil
  end
  local text = self._read(rel)
  if not text then
    error("Failed to read manual file: " .. rel)
  end
  local lines = split_lines(text)
  local fence = false
  for i, line in ipairs(lines) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fence = not fence
    elseif not fence and line:find("](", 1, true) then
      lines[i] = M.rewrite_links(line, rel, self._file_set)
    end
  end
  local headings, anchors = parse_outline(lines)
  local title = rel
  for _, h in ipairs(headings) do
    if h.level == 1 then
      title = h.text
      break
    end
  end
  local lower = {}
  for i, line in ipairs(lines) do
    lower[i] = line:lower()
  end
  local doc = { path = rel, lines = lines, lower = lower, headings = headings, anchors = anchors, title = title }
  self._docs[rel] = doc
  return doc
end

--- 目录索引: 每个文件的路径, 一级标题, 行数, 以及 README 的 "按决策查阅" 表.
---@return table
function Store:index()
  local files = {}
  for i, rel in ipairs(self:files()) do
    local doc = self:doc(rel)
    files[i] = { path = rel, title = doc.title, lines = #doc.lines }
  end
  local result = {
    files = files,
    hint = "Read with docs_read(path). Files over " .. M.OUTLINE_THRESHOLD
      .. " lines return an outline first; then read one part with section (heading text or anchor id) or offset/limit. "
      .. "Links like [x](<path#anchor>) point to manual files and can be passed to docs_read as is; "
      .. "'text (path)' is outside the manual and cannot be read.",
  }
  local readme = self._file_set["README.md"] and self:doc("README.md")
  if readme then
    local section = find_section(readme, "按决策查阅")
    if section then
      result.guide = table.concat(readme.lines, "\n", section.line, section.end_line)
    end
  end
  return result
end

---@param doc table
---@param from integer
---@param to integer
---@return string content
---@return integer last 实际读到的最后一行
local function render(doc, from, to)
  local out, bytes = {}, 0
  local last = from - 1
  for i = from, to do
    local text = i .. ": " .. doc.lines[i]
    if #out > 0 and bytes + #text + 1 > M.MAX_BYTES then
      break
    end
    out[#out + 1] = text
    bytes = bytes + #text + 1
    last = i
  end
  return table.concat(out, "\n"), last
end

--- 读取文件内容 (带行号), 章节或分页. 参数错误时返回 nil 与原因.
---@param args {path: string, section: string?, offset: integer?, limit: integer?}
---@return table? result
---@return string? err
function Store:read(args)
  if type(args.path) ~= "string" then
    return nil, "Field 'path' must be a string"
  end
  -- path 可以直接带 "#锚点", 等同 section
  local raw, frag = args.path:match("^([^#]*)#(.*)$")
  raw = raw or args.path
  local rel, err = M.normalize(raw)
  if not rel then
    return nil, err
  end
  local doc = self:doc(rel)
  if not doc then
    return nil, "No such manual file: " .. rel .. ". Call docs_index for the file list"
  end
  local total = #doc.lines
  local result = { path = rel, title = doc.title, total_lines = total }
  if total == 0 then
    result.content = ""
    return result
  end

  local query = args.section
  if query == nil and frag and frag ~= "" then
    query = frag
  end
  local from, to = 1, total
  if query ~= nil then
    if type(query) ~= "string" or query == "" then
      return nil, "Field 'section' must be a non-empty string"
    end
    local section, candidates = find_section(doc, query)
    if not section then
      local message = "Section not found in " .. rel .. ": " .. query
      if candidates and #candidates > 0 then
        message = message .. ". Matching headings: " .. table.concat(candidates, "; ")
      else
        message = message .. ". Call docs_read without section to get the outline"
      end
      return nil, message
    end
    from, to = section.line, section.end_line
    result.section = { title = section.title, line = section.line, end_line = section.end_line }
  elseif args.offset == nil and total > M.OUTLINE_THRESHOLD then
    result.outline = outline_text(doc)
    result.hint = "Large file, outline only (line: heading {#anchor}). Call again with section "
      .. "(heading text or anchor id) or offset/limit"
    return result
  end

  local offset = args.offset or from
  if type(offset) ~= "number" or offset ~= math.floor(offset) then
    return nil, "Field 'offset' must be an integer"
  end
  if offset < from or offset > to then
    return nil, string.format("Field 'offset' must be within %d-%d", from, to)
  end
  local limit = args.limit or M.MAX_LINES
  if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 then
    return nil, "Field 'limit' must be a positive integer"
  end
  limit = math.min(limit, M.MAX_LINES)
  local content, last = render(doc, offset, math.min(to, offset + limit - 1))
  result.start_line = offset
  result.end_line = last
  result.content = content
  if last < to then
    result.next_offset = last + 1
  end
  return result
end

--- 子串搜索. 参数错误时返回 nil 与原因.
---@param args {query: string, path: string?, limit: integer?}
---@return table? result
---@return string? err
function Store:search(args)
  if type(args.query) ~= "string" or args.query == "" then
    return nil, "Field 'query' must be a non-empty string"
  end
  local limit = args.limit or M.SEARCH_DEFAULT
  if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 then
    return nil, "Field 'limit' must be a positive integer"
  end
  limit = math.min(limit, M.SEARCH_MAX)

  local files = self:files()
  local scope
  if args.path ~= nil then
    local rel, err = M.normalize(args.path)
    if not rel then
      return nil, err
    end
    scope = {}
    for _, f in ipairs(files) do
      if f == rel or f:sub(1, #rel + 1) == rel .. "/" then
        scope[#scope + 1] = f
      end
    end
    if #scope == 0 then
      return nil, "No manual file or directory: " .. rel .. ". Call docs_index for the file list"
    end
  end

  local needle = args.query:lower()
  local matches, total = {}, 0
  for _, rel in ipairs(scope or files) do
    local doc = self:doc(rel)
    for i, lower in ipairs(doc.lower) do
      local s, e = lower:find(needle, 1, true)
      if s then
        total = total + 1
        if #matches < limit then
          matches[#matches + 1] = rel .. ":" .. i .. ": " .. M.clip(doc.lines[i], s, e, M.CLIP_BYTES)
        end
      end
    end
  end
  return { query = args.query, matches = matches, total = total, truncated = total > #matches }
end

--- 在 prefix 目录下搜索完整的标识符 (前后不是字母, 数字或下划线), 供 lookup 带出机制说明.
---@param token string
---@param prefix string 目录, 例如 "mechanics"
---@param max integer
---@return string[] lines "路径:行号: 内容"
function Store:grep_token(token, prefix, max)
  local out = {}
  for _, rel in ipairs(self:files()) do
    if rel:sub(1, #prefix + 1) == prefix .. "/" then
      local doc = self:doc(rel)
      for i, line in ipairs(doc.lines) do
        local init = 1
        while true do
          local s, e = line:find(token, init, true)
          if not s then
            break
          end
          local before = s > 1 and line:sub(s - 1, s - 1) or ""
          local after = line:sub(e + 1, e + 1)
          if not before:match("[%w_]") and not after:match("[%w_]") then
            out[#out + 1] = rel .. ":" .. i .. ": " .. M.clip(line, s, e, M.CLIP_BYTES)
            break
          end
          init = e + 1
        end
        if #out >= max then
          return out
        end
      end
    end
  end
  return out
end

--- prefix 目录下的锚点 id 到文件的映射.
---@param prefix string
---@return table<string, string>
function Store:anchor_paths(prefix)
  local map = {}
  for _, rel in ipairs(self:files()) do
    if rel:sub(1, #prefix + 1) == prefix .. "/" then
      for _, a in ipairs(self:doc(rel).anchors) do
        map[a.id] = map[a.id] or rel
      end
    end
  end
  return map
end

return M
