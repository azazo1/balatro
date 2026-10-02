--[[
回放流式条的纯逻辑: 录制时记下模型输出的起止时刻与正文, 回放按这段时间的平均字速露出.

- 时间与回放文件的 wall 相同 (开局起的秒数).
- wall 是第一个字到达, wall_end 是请求结束; 中间按总字数匀速滚动, 不逐 token 重放.
- original 节奏下回放等待窗口与原局间隔相同, 映射 1:1; tight 把原局这段思考压进较短的等待.
]]

local M = {}

local CHAR_PATTERN = "[%z\1-\127\194-\244][\128-\191]*"

---@param text string
---@return integer
local function char_count(text)
  local n = 0
  for _ in (text or ""):gmatch(CHAR_PATTERN) do
    n = n + 1
  end
  return n
end

--- 已经过了 elapsed 秒时, 应按平均速度露出多少字.
---@param elapsed number
---@param duration number 原局从第一个字到结束的秒数
---@param total integer
---@return integer
function M.visible_chars(elapsed, duration, total)
  total = total or 0
  if total <= 0 then
    return 0
  end
  if duration <= 0 or elapsed >= duration then
    return total
  end
  if elapsed <= 0 then
    return 0
  end
  return math.floor(total * elapsed / duration + 0.5)
end

--- 把回放已经等过的时间映射到原局时间.
--- orig_span 是原局这一段的时长, wait_span 是回放实际等待的时长
--- (original 时两者相同; tight 时是压缩后的窗口).
---@param origin number 原局这一段的起点
---@param elapsed number 回放已经等过的秒数
---@param orig_span number
---@param wait_span number
---@return number
function M.map_time(origin, elapsed, orig_span, wait_span)
  origin = origin or 0
  orig_span = orig_span or 0
  if orig_span <= 0 then
    return origin
  end
  if (wait_span or 0) <= 0 then
    return origin + orig_span
  end
  local p = elapsed / wait_span
  if p < 0 then
    p = 0
  elseif p > 1 then
    p = 1
  end
  return origin + orig_span * p
end

--- 原局时刻 t 落在哪一段输出里. 还没开始或已经结束时返回 nil.
---@param streams table[]
---@param t number
---@return table? stream
---@return integer index 1-based; 0 表示还没到第一段
function M.active_stream(streams, t)
  if type(streams) ~= "table" then
    return nil, 0
  end
  local last_past = 0
  for i, stream in ipairs(streams) do
    local wall = stream.wall or 0
    local wall_end = stream.wall_end or wall
    if t < wall then
      return nil, last_past
    end
    if t <= wall_end then
      return stream, i
    end
    last_past = i
  end
  return nil, last_past
end

--- 录制时累积一段输出. begin 会先交出上一段没结束的内容.
---@return table
function M.new_acc()
  local acc = { label = nil, segs = {}, open = false }

  ---@param label string?
  ---@return table? prev 被顶掉的上一段 (还没有 take)
  function acc:begin(label)
    local prev = self:take()
    self.label = label
    self.segs = {}
    self.open = true
    return prev
  end

  ---@param kind string
  ---@param text string
  ---@return boolean 是否是这一段的第一个字
  function acc:delta(kind, text)
    if not self.open or type(text) ~= "string" or text == "" then
      return false
    end
    if type(kind) ~= "string" or kind == "" then
      return false
    end
    local first = #self.segs == 0
    local last = self.segs[#self.segs]
    if last and last.kind == kind then
      last.text = last.text .. text
    else
      self.segs[#self.segs + 1] = { kind = kind, text = text }
    end
    return first
  end

  function acc:reset()
    self.segs = {}
  end

  --- 丢掉当前这段, 不交给调用方.
  function acc:drop()
    self.label = nil
    self.segs = {}
    self.open = false
  end

  ---@return table? rec {label, segments} 有正文才返回
  function acc:take()
    if not self.open then
      return nil
    end
    local segs = self.segs
    local label = self.label
    self.label = nil
    self.segs = {}
    self.open = false
    if #segs == 0 then
      return nil
    end
    return { label = label, segments = segs }
  end

  return acc
end

M.char_count = function(segments)
  local n = 0
  for _, seg in ipairs(segments or {}) do
    n = n + char_count(seg.text)
  end
  return n
end

return M
