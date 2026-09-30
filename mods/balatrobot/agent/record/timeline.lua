--[[
录制时间线: 与 mp4 同名的 JSON, 标记关键时间点.
t 为视频时间, wall 为开局起的墙钟时间, 单位秒. 字段说明见 docs/agent-api.md.
写入先写临时文件再 rename, 中途崩溃也能留下上一次完整的内容.
]]

local json = require("json")

local VERSION = 1
local FLUSH_INTERVAL = 2

local Timeline = {}
Timeline.__index = Timeline

local function round(x)
  return math.floor(x * 1000 + 0.5) / 1000
end

---@param path string JSON 路径
---@param meta table 顶层字段
function Timeline.new(path, meta)
  local data = { version = VERSION }
  for k, v in pairs(meta) do
    data[k] = v
  end
  data.events = {}
  data.gaps = {}
  return setmetatable({ path = path, data = data, dirty = true, last_flush = -math.huge }, Timeline)
end

--- 追加一个事件并返回它, 调用方可以之后补充字段 (如响应结果).
---@param t number 视频时间
---@param wall number 墙钟时间
---@param kind string
---@param fields table?
---@return table
function Timeline:event(t, wall, kind, fields)
  local event = { t = round(t), wall = round(wall), kind = kind }
  for k, v in pairs(fields or {}) do
    event[k] = v
  end
  table.insert(self.data.events, event)
  self.dirty = true
  return event
end

function Timeline:set(key, value)
  self.data[key] = value
  self.dirty = true
end

---@param clock table record/clock 实例
function Timeline:sync_clock(clock)
  local gaps = clock:gap_list()
  for _, gap in ipairs(gaps) do
    gap.video_start = round(gap.video_start)
    gap.video_end = round(gap.video_end)
    gap.wall_seconds = round(gap.wall_seconds)
  end
  self.data.gaps = gaps
  self.data.duration = { video = round(clock:video_time()), wall = round(clock.wall), waited = round(clock:waited()) }
end

--- 写入文件. force 为 false 时最多每 FLUSH_INTERVAL 秒写一次.
---@param now number love.timer 时间
---@param force boolean?
---@return boolean ok
---@return string? err
function Timeline:flush(now, force)
  if not self.dirty and not force then
    return true
  end
  if not force and now - self.last_flush < FLUSH_INTERVAL then
    return true
  end
  local ok, encoded = pcall(json.encode, self.data)
  if not ok then
    return false, "encode failed: " .. tostring(encoded)
  end
  local tmp = self.path .. ".tmp"
  local file, err = io.open(tmp, "wb")
  if not file then
    return false, tostring(err)
  end
  file:write(encoded)
  file:close()
  local renamed, rename_err = os.rename(tmp, self.path)
  if not renamed then
    return false, tostring(rename_err)
  end
  self.dirty = false
  self.last_flush = now
  return true
end

return Timeline
