--[[
流式条的文本缓冲与可见窗口截取, 纯逻辑, 不依赖 G/SMODS, 可以用 luajit 单测.

- 缓冲是分段列表 {kind, text}: 相邻同类的增量合并成一段, 换行和制表符换成空格, 连续空白压成一个.
- 缓冲只保留最近 max_chars 个字, 更早的从最前面丢掉.
- tail 从右往左按字形宽度截取, 保证最右端是最新的字; 结果仍按分段拆开, 每段一种颜色.
- 测宽函数由调用方注入: 游戏里用 toast.text_width, 单测里用假函数.
]]

local M = {}

M.KINDS = { reasoning = true, content = true, error = true, status = true }

local CHAR_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"

---@param text string
---@return string[] 按 UTF-8 拆分的字符
function M.utf8_chars(text)
  local chars = {}
  for ch in text:gmatch(CHAR_PATTERN) do
    chars[#chars + 1] = ch
  end
  return chars
end

---@param text string
---@return integer
local function char_count(text)
  local n = 0
  for _ in text:gmatch(CHAR_PATTERN) do
    n = n + 1
  end
  return n
end

--- 去掉前 n 个字符.
---@param text string
---@param n integer
---@return string
local function drop_chars(text, n)
  if n <= 0 then
    return text
  end
  local pos, seen = 1, 0
  for start, _ in text:gmatch("()(" .. CHAR_PATTERN .. ")") do
    if seen == n then
      pos = start
      return text:sub(pos)
    end
    seen = seen + 1
  end
  return ""
end

--- 换行, 回车, 制表符换成空格, 连续空白压成一个.
---@param text string
---@return string
function M.normalize(text)
  return (text:gsub("[\r\n\t]", " "):gsub("  +", " "))
end

---@class BBStreamSegment
---@field kind string
---@field text string
---@field chars integer

---@class BBStreamBuffer
---@field segments BBStreamSegment[]
---@field chars integer
---@field max_chars integer

local Buffer = {}
Buffer.__index = Buffer

---@param max_chars integer? 缓冲最多保留的字数
---@return BBStreamBuffer
function M.new_buffer(max_chars)
  return setmetatable({ segments = {}, chars = 0, max_chars = max_chars or 400 }, Buffer)
end

function Buffer:clear()
  self.segments = {}
  self.chars = 0
end

---@return boolean
function Buffer:is_empty()
  return self.chars == 0
end

--- 追加一段增量. 返回是否有新字进入缓冲.
---@param kind string
---@param text string
---@return boolean
function Buffer:append(kind, text)
  if type(text) ~= "string" or text == "" then
    return false
  end
  text = M.normalize(text)
  local last = self.segments[#self.segments]
  -- 缓冲开头不留空格; 与上一段交界处不留两个空格.
  if not last or last.text:sub(-1) == " " then
    text = text:gsub("^ +", "")
  end
  if text == "" then
    return false
  end
  local n = char_count(text)
  if last and last.kind == kind then
    last.text = last.text .. text
    last.chars = last.chars + n
  else
    self.segments[#self.segments + 1] = { kind = kind, text = text, chars = n }
  end
  self.chars = self.chars + n
  -- 超出上限时从最前面丢.
  while self.chars > self.max_chars and #self.segments > 0 do
    local first = self.segments[1]
    local extra = self.chars - self.max_chars
    if first.chars <= extra then
      table.remove(self.segments, 1)
      self.chars = self.chars - first.chars
    else
      first.text = drop_chars(first.text, extra)
      first.chars = first.chars - extra
      self.chars = self.chars - extra
    end
  end
  return true
end

--- 给测宽函数加按字符的缓存: 截取时逐字累加宽度, 同一个字只测一次.
---@param measure fun(text: string): number
---@return fun(ch: string): number
function M.cached(measure)
  local cache = {}
  return function(ch)
    local w = cache[ch]
    if not w then
      w = measure(ch)
      cache[ch] = w
    end
    return w
  end
end

---@class BBStreamPiece
---@field kind string
---@field text string

--- 从右往左截取不超过 max_width 的尾部, 按分段拆开, 最多 max_pieces 段 (更早的段丢掉).
--- 最右端总是最新的字; 放不下的宽字整个丢掉, 不会露出半个.
---@param segments {kind: string, text: string}[]
---@param max_width number
---@param measure fun(ch: string): number 单个字符的宽度
---@param max_pieces integer?
---@return BBStreamPiece[] 从左到右
function M.tail(segments, max_width, measure, max_pieces)
  max_pieces = max_pieces or 4
  local reversed = {}
  local width = 0
  local full = false
  for i = #segments, 1, -1 do
    if #reversed >= max_pieces then
      break
    end
    local seg = segments[i]
    local chars = M.utf8_chars(seg.text)
    local picked = {}
    for j = #chars, 1, -1 do
      local w = measure(chars[j])
      if width + w > max_width then
        full = true
        break
      end
      width = width + w
      picked[#picked + 1] = chars[j]
    end
    if #picked > 0 then
      local ordered = {}
      for k = #picked, 1, -1 do
        ordered[#ordered + 1] = picked[k]
      end
      reversed[#reversed + 1] = { kind = seg.kind, text = table.concat(ordered) }
    end
    if full then
      break
    end
  end
  local pieces = {}
  for i = #reversed, 1, -1 do
    pieces[#pieces + 1] = reversed[i]
  end
  -- 窗口左端的空格没有意义, 去掉.
  while pieces[1] do
    pieces[1].text = pieces[1].text:gsub("^ +", "")
    if pieces[1].text ~= "" then
      break
    end
    table.remove(pieces, 1)
  end
  return pieces
end

--- 从左往右截取开头, 放不下时以 "..." 结尾. 用于报错和状态文字: 开头的信息最重要.
---@param text string
---@param max_width number
---@param measure fun(ch: string): number
---@return string
function M.head(text, max_width, measure)
  text = M.normalize(text)
  local chars = M.utf8_chars(text)
  local total = 0
  for _, ch in ipairs(chars) do
    total = total + measure(ch)
  end
  if total <= max_width then
    return text
  end
  local ellipsis = measure(".") * 3
  local out, width = {}, 0
  for _, ch in ipairs(chars) do
    local w = measure(ch)
    if width + w + ellipsis > max_width then
      break
    end
    width = width + w
    out[#out + 1] = ch
  end
  return (table.concat(out):gsub(" +$", "")) .. "..."
end

return M
