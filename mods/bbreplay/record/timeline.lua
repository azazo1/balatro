--[[
录制时间线: 与视频同名的 JSON, 标记关键时间点.
wall 为开局起的墙钟时间, 即完整版视频里的时间; cut 为剪辑版视频里的时间, 单位秒.
字段说明见 docs/agent-api.md. 写入先写临时文件再 rename, 中途崩溃也能留下上一次完整的内容.
]]

local json = require("json")

local VERSION = 2
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
  data.cuts = {}
  return setmetatable({ path = path, data = data, dirty = true, last_flush = -math.huge }, Timeline)
end

--- 追加一个事件并返回它, 调用方可以之后补充字段 (如响应结果).
---@param wall number 墙钟时间 (完整版时间)
---@param cut number 剪辑版时间
---@param kind string
---@param fields table?
---@return table
function Timeline:event(wall, cut, kind, fields)
  local event = { wall = round(wall), cut = round(cut), kind = kind }
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

--- 同步剪辑区间与时长.
---@param cuts table record/cuts 实例
---@param wall number 当前墙钟时间
function Timeline:sync_cuts(cuts, wall)
  local list = {}
  for _, cut in ipairs(cuts.list) do
    list[#list + 1] = { start = round(cut.start), stop = round(cut.stop), at = round(cuts:cut_time(cut.start)) }
  end
  if #list ~= #self.data.cuts then
    self.dirty = true
  end
  self.data.cuts = list
  self.data.duration = { full = round(wall), cut = round(wall - cuts.removed), removed = round(cuts.removed) }
end

--- 重算 wall 不早于 from 的事件在剪辑版里的时间. 暂停期间记下的事件当时剪辑区间还没确定,
--- 恢复 (或结束) 后用它改正.
---@param cuts table record/cuts 实例
---@param from number 墙钟时间
function Timeline:refresh_cut(cuts, from)
  for _, event in ipairs(self.data.events) do
    if event.wall >= from then
      event.cut = round(cuts:cut_time(event.wall))
    end
    if event.wall_end and event.wall_end >= from then
      event.cut_end = round(cuts:cut_time(event.wall_end))
    end
  end
  self.dirty = true
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
    -- Windows 上 rename 不能覆盖已有文件: 先删掉旧的再改名. 两步之间崩溃最多丢这一份时间线.
    os.remove(self.path)
    renamed, rename_err = os.rename(tmp, self.path)
  end
  if not renamed then
    os.remove(tmp)
    return false, tostring(rename_err)
  end
  -- 不走 love.filesystem 的写包装, 每次 rename 都换成一个新的 0600 文件, 要单独通知 Android 修正权限,
  -- 否则文件管理器与 adb 读不到. 只靠失去焦点时的整树扫描不够: 切出去时录像暂停, 时间线紧接着又重写一次.
  local storage_ok, storage = pcall(require, "android_storage")
  if storage_ok and type(storage) == "table" and storage.fix_path then
    pcall(storage.fix_path, self.path)
  end
  self.dirty = false
  self.last_flush = now
  return true
end

return Timeline
