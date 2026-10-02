--[[
演示 driver: 不发网络请求, 用假数据驱动 runner 与流式条, 用来验证运行控制和流式条的外观.
只在设置里打开 "演示流式条" (config.demo_stream, 开发用) 且没有真实 driver 时启用.

一个周期: 空闲 -> 请求中 (等首个 token) -> 灰色思维链增量 -> 白色正文 -> 结束 -> 执行动作 -> 空闲.
每 4 次请求模拟一次 429: 红字倒计时 3 秒, 重发后恢复流式显示.
]]

local M = {}

local REASONING = "手里有一对 K, 还剩 2 次弃牌和 3 次出牌. 目标 600 分, 一对 K 大约 120 分, 不够."
  .. " 同花差一张: 红桃 4 张. 弃掉黑桃 7 和梅花 3 追同花, 概率大约四成."
  .. " 如果没中, 下一轮还能打两对. 小丑 '贪婪' 对方块加倍, 这手用不上."
local CONTENT = "弃掉黑桃 7 和梅花 3, 保留红桃, 追同花."

local IDLE = 1.2 -- 两次请求之间的空闲
local FIRST_TOKEN = 0.8 -- 请求发出到首个 token
local CHUNK_INTERVAL = 0.06
local ACT_TIME = 1.0
local RETRY_WAIT = 3

---@param text string
---@param size integer
---@return string[]
local function chunks(text, size)
  local out, current, n = {}, {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    current[#current + 1] = ch
    n = n + 1
    if n >= size then
      out[#out + 1] = table.concat(current)
      current, n = {}, 0
    end
  end
  if #current > 0 then
    out[#out + 1] = table.concat(current)
  end
  return out
end

local demo = {
  phase = "idle",
  timer = 0,
  queue = {},
  count = 0,
  retried = false,
}

local function reset()
  demo.phase = "idle"
  demo.timer = 0
  demo.queue = {}
end

local function begin(runner)
  local stream = runner.stream()
  demo.phase = "waiting"
  demo.timer = 0
  demo.queue = {}
  for _, c in ipairs(chunks(REASONING, 3)) do
    demo.queue[#demo.queue + 1] = { "reasoning", c }
  end
  for _, c in ipairs(chunks(CONTENT, 2)) do
    demo.queue[#demo.queue + 1] = { "content", c }
  end
  runner.set_phase("requesting")
  runner.note_request()
  if stream then
    stream.begin_request()
  end
end

function M.start(_runner)
  reset()
  demo.count = 0
end

function M.stop(runner)
  reset()
  local stream = runner.stream()
  if stream then
    stream.finish()
  end
end

function M.pause(_runner)
  -- 暂停立刻取消 "请求", 继续时重新发起.
  reset()
end

function M.resume(_runner)
  reset()
end

--- 演示用的假占用: 每请求涨一截, 给 HUD 占用条动起来.
---@return integer
---@return integer
function M.context_usage()
  local used = (demo.count or 0) * 32000
  if used > 256000 then
    used = 256000
  end
  return used, 256000
end

---@param dt number
---@param runner table
function M.update(dt, runner)
  if not runner.is_active() then
    return
  end
  local stream = runner.stream()
  demo.timer = demo.timer + dt
  if demo.phase == "idle" then
    if demo.timer >= IDLE then
      demo.count = demo.count + 1
      demo.retried = false
      begin(runner)
    end
  elseif demo.phase == "waiting" then
    if demo.timer >= FIRST_TOKEN then
      demo.phase = "streaming"
      demo.timer = 0
    end
  elseif demo.phase == "streaming" then
    -- 第 4n 次请求在输出到一半时断开, 模拟 429.
    if demo.count % 4 == 0 and not demo.retried and #demo.queue <= 30 then
      demo.retried = true
      demo.phase = "retry"
      demo.timer = 0
      runner.set_phase("retry_wait")
      runner.note_retry()
      if stream then
        stream.reset()
        stream.show_error(function()
          local left = math.max(0, math.ceil(RETRY_WAIT - demo.timer))
          return string.format("请求失败: 429 rate limit (演示), 第 1/5 次重试, %d 秒后", left)
        end)
      end
      return
    end
    while demo.timer >= CHUNK_INTERVAL and #demo.queue > 0 do
      demo.timer = demo.timer - CHUNK_INTERVAL
      local item = table.remove(demo.queue, 1)
      if stream then
        stream.push(item[1], item[2])
      end
    end
    if #demo.queue == 0 then
      if stream then
        stream.finish()
      end
      runner.add_usage(1800, 120)
      runner.set_phase("acting")
      demo.phase = "acting"
      demo.timer = 0
    end
  elseif demo.phase == "retry" then
    if demo.timer >= RETRY_WAIT then
      -- 整个请求重发, 已收到的半截输出丢掉.
      begin(runner)
    end
  elseif demo.phase == "acting" then
    if demo.timer >= ACT_TIME then
      runner.set_phase("running")
      demo.phase = "idle"
      demo.timer = 0
    end
  end
end

return M
