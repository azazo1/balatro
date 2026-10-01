--[[
内置 agent loop 的运行控制外壳: 状态机, 统计, driver 调度. 不依赖 G/SMODS, 依赖都经 init 注入.

真正的 LLM loop 以 driver 的形式接入 (set_driver). driver 是一个表, 字段都可选:
  start(runner)          开始. 此时状态为 running
  stop(runner, reason)   停止, reason 为 "user" 或 "error". 要取消在路上的请求
  pause(runner)          暂停: 立刻取消在路上的请求, 保留上下文
  resume(runner)         继续: 读取最新状态重新发起请求
  update(dt, runner)     每帧调用 (running 系状态与 paused 时都调用, 由 driver 自己看 runner.state)
driver 的调用都包在 pcall 里, 报错时 runner 进入 error 状态.

driver 通过 runner 汇报进度:
  runner.set_phase("requesting" | "acting" | "retry_wait" | "running")
  runner.note_request()  runner.note_retry()  runner.add_usage(prompt, completion)
  runner.fail(message)   不可重试的错误, loop 停止
  runner.pause(reason)   防失控自动暂停, reason 以红字显示
  runner.stream()        流式条 (bbcore 的 ui/stream_bar.lua)

没有真实 driver 时: 设置里开了 "演示流式条" 就用演示 driver (agent/demo_driver.lua), 否则 start 失败并提示.
停止 (含出错停止) 时依次调用 on_stop 里的钩子 fn(reason), 用于结束当前录像段.
]]

local M = {
  ---@type "stopped"|"running"|"requesting"|"acting"|"retry_wait"|"paused"|"error"
  state = "stopped",
  -- 最近一次操作的提示, 例如 "内置 agent 尚未接入模型"
  notice = "",
  stats = {
    requests = 0,
    retries = 0,
    prompt_tokens = 0,
    completion_tokens = 0,
    run_tokens = 0, -- 本局累计, 用于单局上限
    last_error = "",
  },
  ---@type fun(reason: string)[] 停止时调用
  on_stop = {},
  ---@type fun(state: string, previous: string)[] 状态变化时调用
  on_state = {},
  -- 暂停时流式条上的提示, 触摸平台可以改掉 F9 的字样
  pause_hint = "已暂停 (F9 继续)",
}

M.LABELS = {
  stopped = "已停止",
  running = "运行中",
  requesting = "请求中",
  acting = "执行动作中",
  retry_wait = "等待重试",
  paused = "已暂停",
  error = "出错停止",
}

local ACTIVE = { running = true, requesting = true, acting = true, retry_wait = true }
local PHASES = { running = true, requesting = true, acting = true, retry_wait = true }

---@class BBRunnerDeps
---@field stream table? 流式条
---@field can_start (fun(): boolean, string?)? 能否开始 (模式, 回放)
---@field demo_enabled (fun(): boolean)? 是否启用演示 driver
---@field demo_driver table? 演示 driver
---@field token_limit (fun(): number)? 单局 token 上限, 0 为不限
---@field log (fun(level: string, text: string))?
local deps = {}

---@type table? 真实 driver
local driver = nil
---@type table? 当前在用的 driver
local active = nil

local function log(level, text)
  if deps.log then
    deps.log(level, text)
  end
end

local function stream_call(name, ...)
  local stream = deps.stream
  if stream and stream[name] then
    stream[name](...)
  end
end

---@param options BBRunnerDeps
function M.init(options)
  deps = options or {}
end

---@return table? 流式条
function M.stream()
  return deps.stream
end

---@param new string
local function set_state(new)
  local previous = M.state
  if previous == new then
    return
  end
  M.state = new
  log("debug", "Runner " .. previous .. " -> " .. new)
  for _, fn in ipairs(M.on_state) do
    local ok, err = pcall(fn, new, previous)
    if not ok then
      log("error", "Runner on_state hook failed: " .. tostring(err))
    end
  end
end

local function fire_stop(reason)
  for _, fn in ipairs(M.on_stop) do
    local ok, err = pcall(fn, reason)
    if not ok then
      log("error", "Runner on_stop hook failed: " .. tostring(err))
    end
  end
end

--- 调用当前 driver 的一个方法. driver 报错时进入 error 状态 (stop 自身报错只记日志).
---@return boolean ok
local function invoke(name, ...)
  local d = active
  local fn = d and d[name]
  if not fn then
    return true
  end
  local ok, err = pcall(fn, ...)
  if not ok then
    log("error", "Driver " .. name .. " failed: " .. tostring(err))
    if name ~= "stop" then
      M.fail("内部错误: " .. tostring(err))
    end
  end
  return ok
end

--- 设置真实 driver, nil 表示撤掉. 运行中设置时下次开始才生效.
---@param new_driver table?
function M.set_driver(new_driver)
  driver = new_driver
  if M.state ~= "stopped" and M.state ~= "error" then
    log("info", "Runner driver replaced, takes effect on next start")
  end
end

---@return boolean
function M.has_driver()
  return driver ~= nil
end

--- running 系状态 (不含暂停).
---@return boolean
function M.is_active()
  return ACTIVE[M.state] == true
end

--- loop 是否在运行 (含暂停). 此时不能切换 agent 模式.
---@return boolean
function M.is_busy()
  return M.state ~= "stopped" and M.state ~= "error"
end

---@return string
function M.label()
  return M.LABELS[M.state] or M.state
end

--- 开始. 失败时返回 false 与原因 (同时写进 notice).
---@return boolean ok
---@return string? reason
function M.start()
  if M.is_busy() then
    return false, "已在运行"
  end
  if deps.can_start then
    local ok, reason = deps.can_start()
    if not ok then
      M.notice = reason or "现在不能开始"
      return false, M.notice
    end
  end
  local chosen = driver
  if not chosen and deps.demo_enabled and deps.demo_enabled() then
    chosen = deps.demo_driver
  end
  if not chosen then
    M.notice = "内置 agent 尚未接入模型"
    stream_call("show_status", M.notice, 3)
    log("info", "Runner start refused: no driver")
    return false, M.notice
  end
  active = chosen
  M.notice = chosen == driver and "" or "演示模式: 流式条显示的是假数据"
  M.stats.last_error = ""
  set_state("running")
  log("info", "Runner started" .. (chosen == driver and "" or " (demo driver)"))
  invoke("start", M)
  return M.state ~= "error", M.state == "error" and M.stats.last_error or nil
end

--- 暂停: 取消在路上的请求, 不再执行新动作. reason 非空时是自动暂停 (防失控), 以红字显示.
---@param reason string?
---@return boolean
function M.pause(reason)
  if not M.is_active() then
    return false
  end
  set_state("paused")
  invoke("pause", M)
  stream_call("finish")
  if reason and reason ~= "" then
    M.stats.last_error = reason
    M.notice = "自动暂停: " .. reason
    stream_call("show_error", "已自动暂停: " .. reason, 8)
    log("warn", "Runner auto paused: " .. reason)
  else
    stream_call("show_status", M.pause_hint, 2)
    log("info", "Runner paused")
  end
  return true
end

--- 继续.
---@return boolean
function M.resume()
  if M.state ~= "paused" then
    return false
  end
  if deps.can_start then
    local ok, reason = deps.can_start()
    if not ok then
      M.notice = reason or "现在不能继续"
      return false
    end
  end
  M.notice = active == driver and "" or M.notice
  set_state("running")
  stream_call("show_status", "已继续", 1.2)
  log("info", "Runner resumed")
  invoke("resume", M)
  return true
end

---@return boolean
function M.toggle_pause()
  if M.state == "paused" then
    return M.resume()
  end
  return M.pause()
end

--- 停止: 取消请求, 清空上下文, loop 退出, 通知 on_stop (结束当前录像段).
---@return boolean
function M.stop()
  if M.state == "stopped" then
    return false
  end
  local was_error = M.state == "error"
  if not was_error then
    invoke("stop", M, "user")
  end
  active = nil
  set_state("stopped")
  stream_call("finish")
  stream_call("show_status", "已停止", 1.5)
  log("info", "Runner stopped")
  -- 出错停止时已经通知过.
  if not was_error then
    fire_stop("user")
  end
  return true
end

--- 不可重试的错误: loop 停止, 红字停留约 8 秒, 错误写进状态行.
---@param message string
function M.fail(message)
  if not M.is_busy() then
    return
  end
  message = tostring(message or "未知错误")
  M.stats.last_error = message
  M.notice = message
  local d = active
  active = nil
  set_state("error")
  if d and d.stop then
    local ok, err = pcall(d.stop, M, "error")
    if not ok then
      log("error", "Driver stop failed: " .. tostring(err))
    end
  end
  stream_call("finish")
  stream_call("show_error", message, 8)
  log("error", "Runner stopped by error: " .. message)
  fire_stop("error")
end

--- driver 汇报当前阶段. 暂停或停止后忽略, 免得晚到的回调把状态改回去.
---@param phase string
function M.set_phase(phase)
  if PHASES[phase] and M.is_active() then
    set_state(phase)
  end
end

function M.note_request()
  M.stats.requests = M.stats.requests + 1
end

function M.note_retry()
  M.stats.retries = M.stats.retries + 1
end

--- 累计 token 用量. 超过单局上限时自动暂停.
---@param prompt number?
---@param completion number?
function M.add_usage(prompt, completion)
  prompt = tonumber(prompt) or 0
  completion = tonumber(completion) or 0
  M.stats.prompt_tokens = M.stats.prompt_tokens + prompt
  M.stats.completion_tokens = M.stats.completion_tokens + completion
  M.stats.run_tokens = M.stats.run_tokens + prompt + completion
  local limit = deps.token_limit and deps.token_limit() or 0
  if limit > 0 and M.stats.run_tokens > limit then
    M.pause(string.format("本局 token 用量 %d 超过上限 %d", M.stats.run_tokens, limit))
  end
end

--- 新的一局开始时调用, 清零本局统计.
function M.new_run()
  M.stats.requests = 0
  M.stats.retries = 0
  M.stats.prompt_tokens = 0
  M.stats.completion_tokens = 0
  M.stats.run_tokens = 0
end

--- 每帧调用. dt 为墙钟间隔.
---@param dt number
function M.update(dt)
  if active and (M.is_active() or M.state == "paused") then
    invoke("update", dt, M)
  end
end

return M
