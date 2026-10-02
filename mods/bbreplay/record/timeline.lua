--[[
录制时间线: 与视频同名的 JSON, 标记关键时间点.
wall 为开局起的墙钟时间, 即视频里的时间, 单位秒.
字段说明见 docs/agent-api.md. 写入先写临时文件再 rename, 中途崩溃也能留下上一次完整的内容.
]]

local json = require("json")

local VERSION = 3
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
  return setmetatable({ path = path, data = data, dirty = true, last_flush = -math.huge }, Timeline)
end

--- 追加一个事件并返回它, 调用方可以之后补充字段 (如响应结果).
---@param wall number 墙钟时间 (视频里的时间)
---@param kind string
---@param fields table?
---@return table
function Timeline:event(wall, kind, fields)
  local event = { wall = round(wall), kind = kind }
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

--- 记下视频时长 (秒), 局末调用.
---@param wall number
function Timeline:set_duration(wall)
  self:set("duration", round(wall))
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
