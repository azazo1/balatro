--[[
剪辑点计算: 在墙钟时间上记录活动, 算出剪辑版要去掉的区间. 纯逻辑, 不依赖 G 与 love.

完整版 (-full.mp4) 按墙钟原样录制. 剪辑版 (-cut.mp4) 在局末从完整版剪出, 去掉 agent 思考时的
无意义等待:
- 活动由调用方判断: agent 请求处理中, 通知在屏幕上, 动画还没停下.
- 活动结束 (动画完全停下) 后再保留 post 秒, 下一次活动前提前 pre 秒开始保留, 中间的部分剪掉.
- 剪掉的部分不足 min_gap 秒时不剪, 避免画面频繁跳动.
- 暂停期间 (pause 到 resume) 的 mark 一律忽略, 这一段按等待处理, 与 agent 思考时的等待一样剪掉
  (前后各留 post/pre). 完整版不受影响.
]]

local Cuts = {}
Cuts.__index = Cuts

---@param opts {pre: number, post: number, min_gap: number}
function Cuts.new(opts)
  return setmetatable({
    pre = opts.pre,
    post = opts.post,
    min_gap = opts.min_gap,
    last = 0, -- 最近一次活动的墙钟时间
    removed = 0, -- 已确定剪掉的总时长
    paused = false,
    list = {}, -- {start, stop}, 墙钟时间, 按时间顺序
  }, Cuts)
end

--- 在墙钟时间 w 标记活动. 距上次活动足够久时, 中间的部分记为一个剪辑区间. 暂停期间忽略.
---@param w number
function Cuts:mark(w)
  if self.paused then
    return
  end
  local start, stop = self.last + self.post, w - self.pre
  if stop - start >= self.min_gap then
    self.list[#self.list + 1] = { start = start, stop = stop }
    self.removed = self.removed + (stop - start)
  end
  if w > self.last then
    self.last = w
  end
end

--- 墙钟时间 w 在剪辑版里的时间. 只对已经标记过的时间点准确 (之后的剪辑区间还没确定).
---@param w number
---@return number
function Cuts:cut_time(w)
  local removed = 0
  for _, cut in ipairs(self.list) do
    if w >= cut.stop then
      removed = removed + (cut.stop - cut.start)
    elseif w > cut.start then
      -- 落在剪掉的区间里, 对应剪辑点
      return cut.start - removed
    else
      break
    end
  end
  return w - removed
end

--- 在墙钟时间 w 暂停: 这一刻算作活动, 之后的 mark 忽略, 直到 resume.
---@param w number
function Cuts:pause(w)
  self:mark(w)
  self.paused = true
end

--- 在墙钟时间 w 恢复: 这一刻算作活动, 暂停的那一段在这里确定为剪辑区间.
---@param w number
function Cuts:resume(w)
  self.paused = false
  self:mark(w)
end

--- 录制结束: 末尾的等待也剪掉 (只保留 post). 暂停中结束时, 暂停的部分同样剪掉.
---@param w number 结束时的墙钟时间
function Cuts:finish(w)
  local start = self.last + self.post
  if w - start >= self.min_gap then
    self.list[#self.list + 1] = { start = start, stop = w }
    self.removed = self.removed + (w - start)
  end
end

return Cuts
