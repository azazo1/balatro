--[[
录制时钟: 按墙钟 dt 决定每次 update 输出几帧, 并记录 agent 的等待段. 纯逻辑, 不依赖 G 与 love.

- keep: 始终计时, 等待段照常出帧, 记为 {video_start, video_end, wall_seconds}.
- skip: 等待期间不计时也不出帧, 在剪辑点记一条 video_start == video_end 的等待段.
活动与否由调用方判断 (请求处理中, 响应后的 hold 时间内, 通知仍在屏幕上).
]]

local Clock = {}
Clock.__index = Clock

---@param opts {mode: "skip"|"keep", fps: number, max_catchup: integer?}
function Clock.new(opts)
  return setmetatable({
    mode = opts.mode,
    fps = opts.fps,
    interval = 1 / opts.fps,
    max_catchup = opts.max_catchup or 30,
    acc = 0,
    frames = 0,
    wall = 0,
    gaps = {},
    gap = nil, -- 当前等待段
  }, Clock)
end

--- 当前视频时间 (秒).
function Clock:video_time()
  return self.frames * self.interval
end

--- 推进 dt 秒墙钟, 返回本次应输出的帧数.
---@param dt number
---@param active boolean
---@return integer
function Clock:advance(dt, active)
  if dt < 0 then
    dt = 0
  end
  self.wall = self.wall + dt

  if active then
    if self.gap then
      self.gap.video_end = self:video_time()
      self.gaps[#self.gaps + 1] = self.gap
      self.gap = nil
    end
  elseif not self.gap then
    self.gap = { video_start = self:video_time(), wall_start = self.wall - dt, wall_seconds = 0 }
  end
  if self.gap then
    self.gap.wall_seconds = self.wall - self.gap.wall_start
  end

  if self.mode == "skip" and not active then
    self.acc = 0
    return 0
  end

  self.acc = self.acc + dt
  local count = math.floor(self.acc / self.interval + 1e-9)
  self.acc = self.acc - count * self.interval
  if count > self.max_catchup then
    count = self.max_catchup
    self.acc = 0
  end
  self.frames = self.frames + count
  return count
end

--- 结束录制时收尾: 未结束的等待段也写入.
function Clock:finish()
  if self.gap then
    self.gap.video_end = self:video_time()
    self.gaps[#self.gaps + 1] = self.gap
    self.gap = nil
  end
end

--- 输出给时间线的等待段 (不含内部字段).
---@return {video_start: number, video_end: number, wall_seconds: number}[]
function Clock:gap_list()
  local list = {}
  for _, gap in ipairs(self.gaps) do
    list[#list + 1] = { video_start = gap.video_start, video_end = gap.video_end, wall_seconds = gap.wall_seconds }
  end
  return list
end

--- 等待段总墙钟时长.
function Clock:waited()
  local total = 0
  for _, gap in ipairs(self.gaps) do
    total = total + gap.wall_seconds
  end
  if self.gap then
    total = total + self.gap.wall_seconds
  end
  return total
end

return Clock
