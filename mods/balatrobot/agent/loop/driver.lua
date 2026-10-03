--[[
内置 agent 的主循环 (driver). 依赖全部注入, 不直接碰全局, 方便单测.

一轮: 看状态 -> (需要时) 追加状态摘要 -> 流式请求模型 -> 逐个执行工具调用 -> 结果写回历史 -> 下一轮.

- 没有选择的步骤自动处理, 不问模型: 解锁弹窗 continue, 结算 cash_out.
- 出牌那一步的结果开头带上这一手的计分过程 (谁加了多少, 从基础涨到多少), 摘要里只有一行结果.
- 胜利按配置 after_win 处理 ("endless" 进入无尽模式继续打, "menu" 回主菜单).
  回到主菜单后按 after_run 处理 ("stop" 停止 loop, "continue" 保留对话历史, 由模型自己开下一局);
  输了同样回主菜单, 再按 after_run 走.
- 人打开了设置等菜单 (overlay 为 other), 或动画没停时等待, 不发请求也不执行动作.
- 压缩上下文: 上一次请求报的 prompt_tokens + completion_tokens (没报用量时按字数估算) 超过最大上下文
  (配置 context_limit) 的 80% 时, 在下一轮开始前压缩. 较早的部分发一次不带工具的请求让模型写摘要,
  流式条显示 "压缩中: " 加摘要输出; 最近约 30% 的原文保留. 写摘要失败时退回每步一行的记录, 继续打.
  服务端以上下文超长拒绝请求时, 压缩后重发一次, 再超长才停下.
- 防失控: 模型连续几次不调用工具, 同一个调用连续失败, 或模型请求出现不可重试的错误时停下 (halted),
  由运行控制转为自动暂停, 等 user 处理后继续. 单局 token 上限由运行控制按汇报的用量判断.
- 暂停: 进行中的请求直接取消 (半截回复丢弃, 不进历史); 正在执行的动作做完为止, 剩余的工具调用
  回一条 "未执行", 保证每个 tool_call 都有结果. 继续时重新给一次状态摘要 (暂停期间 user 可能手动操作过).
- 手动操作 (manual, user 解开锁操作后在运行中点了游戏): 之前按旧状态做的计划作废, 处理方式同暂停,
  只是不停下: 请求取消, 正在执行的动作做完为止, 剩余调用回 "未执行". 等 user 停手 MANUAL_QUIET 秒后
  按新状态重新请求, 状态前附上说明. 写摘要的请求不受影响 (它不看游戏状态).

deps:
- client.start(cfg, messages, tools, callbacks) -> req, req:update(), req:cancel()
  callbacks: on_delta(kind, text), on_reset(), on_retry(attempt, max, reason, wait_seconds),
  on_done(message, usage), on_error(reason, detail)
- call(method, params, reason, cb) -> ok, err: 进程内调用端点, cb(response)
- abandon(): 放弃等待中的调用
- text: agent/text.lua (UTF-8 安全的截断), 查询结果超长时用它切.
- gamestate() -> table; overlay() -> "unlock"|"win"|"other"|nil; busy() -> boolean (动画或游戏暂停)
- config() -> {endpoint, model, api_key, auth, api_format, reasoning_effort, thinking, after_win, after_run,
  strategy, context_limit, seed}
  seed 非空时 start 一律用它开局, 覆盖模型给的种子.
  after_win / after_run / strategy 只在从停止状态开始时拼进系统提示, 运行中改动不影响提示词.
  after_win 与 after_run 的实际分支在一局结束时读当前配置.
  配置整个交给 client.start, 协议 (api_format) 与思考相关的字段由协议层自己读, 每次请求 (含写摘要) 都按当前值.
- json {encode, decode}; now() -> 秒
- bar: begin_request(label?, agent?), push(kind, text), reset(), finish(), show_error(text 或 fun(): string, hold), show_status(text, hold)
  label 是固定显示在行首的前缀 (压缩时为 "压缩中: "), agent 只含 endpoint 和 model, 用于回放记录.
- describe(key) -> {name, effect}? (给摘要用)
- on_state(state, detail): 可选, 子状态变化 (idle, requesting, acting, retry_wait, waiting, paused, halted, stopped)
- report(event, ...): 可选, 向运行控制 (agent/runner.lua) 汇报, 由它负责单局 token 上限, 暂停与停止:
  "request"; "retry"; "usage"(prompt, completion); "new_run"; "halt"(reason) 防失控或不可恢复的错误;
  "finish"(result) 本局结束 ("win" / "lose") 且 after_run 不是 continue 时, 应停止 loop.
  没有 report 时 driver 自己处理 halt 与 finish.
- transcript(entry): 可选, 转录一条记录
- log(level, msg): 可选
]]

local M = {}

local MAX_NUDGES = 3 -- 连续不调用工具的次数上限
local MAX_REPEAT_FAILS = 3 -- 同一个调用连续失败的次数上限
local QUERY_RESULT_MAX = 6000 -- 手册查询结果交给模型的最大字节数
local DEFAULT_CONTEXT = 256000 -- 配置里没有最大上下文时的默认值
local COMPACT_AT = 0.8 -- 上下文到最大上下文的这个比例时压缩
local COMPACT_KEEP = 0.3 -- 压缩时最近的原文约占最大上下文的比例
local COMPACT_LABEL = "压缩中: "
local MANUAL_QUIET = 1.5 -- 人手动操作后, 停手这么久才按新状态重新请求
local MANUAL_NOTE = "(user 刚才手动操作了游戏, 之前的计划已作废, 以下面的状态为准)"

---@param deps table
---@return table
function M.new(deps)
  local lifecycle = assert(deps.lifecycle, "需要注入共用 lifecycle").new(deps)
  local tools = deps.tools or assert(deps.load("tools"))
  local prompt = deps.prompt or assert(deps.load("prompt"))
  local history_mod = deps.history or assert(deps.load("history"))
  local summary_mod = deps.summary or assert(deps.load("summary"))
  local text = deps.text or assert(deps.load("text"))

  local self = {
    state = "stopped",
    stats = { requests = 0, prompt_tokens = 0, completion_tokens = 0, cached_tokens = 0, actions = 0 },
    last_error = nil,
  }

  -- 系统提示词带 user 的策略, 通关走向, 以及一局结束后是否接着打.
  -- 每次从停止状态开始时按当时的配置重建, 运行中改了不影响这一次的提示词.
  local function system_prompt()
    local cfg = deps.config and deps.config() or {}
    return prompt.system and prompt.system(cfg) or prompt.SYSTEM
  end
  local history = history_mod.new(system_prompt())
  local summarizer = summary_mod.new(deps.describe)
  local req = nil -- 进行中的模型请求
  local queue = nil -- {calls, index}
  local calling = false -- 端点调用进行中
  local pending_call = nil -- 已提交但仍在等端点结果的原始工具调用
  local fresh = false -- 模型是否已经拿到最新的状态摘要 (动作结果或用户消息里)
  local note = nil -- 下一轮附在状态前的说明
  local nudges = 0
  local fail_key, fail_count = nil, 0
  local proposals_failed = 0
  local rearranges = 0
  local proposal_active = false
  local request_version, decision_version
  local decision_generation = 0
  local pause_requested = false
  local manual_requested = false -- 人在动作执行中手动操作了, 这个动作做完后作废剩下的计划
  local manual_at = nil -- 最近一次手动操作的时刻, 人停手 MANUAL_QUIET 秒后才重新请求
  local retry = nil -- {at, attempt, max, reason}
  local context_used = nil -- 上一次请求报的上下文大小, nil 时按字数估算
  local compacting = nil -- {cut, older_tokens} 写摘要的请求进行中
  local force_compact = false -- 服务端报上下文超长, 下一轮先压缩
  -- 压缩后到下一次正常请求返回之前不再判断: 那时只有估算, 系统提示较大时会反复压缩.
  local just_compacted = false
  local overflow_retried = false -- 这次超长已经压缩重发过, 再超长就停下

  local function report(event, ...)
    if deps.report then
      deps.report(event, ...)
      return true
    end
    return false
  end

  local function log(level, msg)
    if deps.log then
      deps.log(level, msg)
    end
  end

  local function transcript(entry)
    if deps.transcript then
      entry.t = deps.now()
      pcall(deps.transcript, entry)
    end
  end

  local function set_state(state, detail)
    self.state = state
    if deps.on_state then
      deps.on_state(state, detail)
    end
  end

  ---@param reason string
  local function halt(reason)
    self.last_error = reason
    log("warn", "Agent loop halted: " .. reason)
    transcript({ type = "halt", reason = reason })
    set_state("halted", reason)
    -- 运行控制会自动暂停 (红字显示原因) 并回调 pause; 继续时保留历史.
    if not report("halt", reason) then
      deps.bar.show_error(reason, 8)
    end
  end

  ---@param result string "win" | "lose"
  local function finish_run(result)
    transcript({ type = "finish", result = result })
    local cfg = deps.config and deps.config() or {}
    if cfg.after_run == "continue" then
      -- 不调 stop, 历史原样留下. 下一轮模型看到主菜单, 自己 start.
      note = (note and note .. "\n" or "") .. "(对话历史保留, 请开下一局)"
      deps.bar.show_status(result == "win" and "赢下本局, 继续下一局" or "本局结束, 继续下一局", 3)
      if self.state == "acting" then
        set_state("idle")
      end
      return
    end
    if not report("finish", result) then
      self.stop(result)
    end
  end

  --- 自动步骤: 调用端点, 完成后回到 idle, 下一轮重新给状态.
  local function auto(method, params, text, after)
    calling = true
    set_state("acting", method)
    local ok, err = deps.call(method, params, nil, function(response)
      calling = false
      fresh = false
      if response.message then
        log("warn", "Auto step " .. method .. " failed: " .. tostring(response.message))
        note = (note and note .. "\n" or "") .. string.format("(自动 %s 失败: %s)", method, response.message)
      else
        history:note(text)
        note = (note and note .. "\n" or "") .. "(" .. text .. ")"
      end
      transcript({ type = "auto", method = method, ok = response.message == nil })
      if after then
        after(response)
      elseif self.state == "acting" then
        set_state("idle")
      end
    end)
    if not ok then
      calling = false
      halt("自动 " .. method .. " 调用失败: " .. tostring(err))
    end
  end

  ---@param gs table
  ---@return string
  local function turn_message(gs)
    local text = prompt.turn(summarizer:render(gs), note)
    note = nil
    return text
  end

  local function on_delta(kind, text)
    deps.bar.push(kind, text)
  end

  local function finish_request()
    req = nil
    retry = nil
  end

  local callbacks = {}

  local function send_request()
    local cfg = deps.config()
    self.stats.requests = self.stats.requests + 1
    report("request")
    deps.bar.begin_request(nil, { endpoint = cfg.endpoint, model = cfg.model })
    set_state("requesting")
    transcript({ type = "request", messages = #history.messages })
    request_version = deps.version and deps.version() or nil
    local started = deps.now()
    callbacks.started = started
    req = deps.client.start(
      cfg,
      history.messages,
      tools.definitions({ knowledge = deps.knowledge ~= false, hybrid = cfg.builtin_backend == "hybrid" }),
      callbacks
    )
  end

  function callbacks.on_delta(kind, text)
    retry = nil
    on_delta(kind, text)
  end

  function callbacks.on_reset()
    deps.bar.reset()
  end

  function callbacks.on_retry(attempt, max, reason, wait)
    local entry = { at = deps.now() + wait, attempt = attempt, max = max, reason = reason }
    retry = entry
    transcript({ type = "retry", attempt = attempt, reason = reason, wait = wait })
    log("info", string.format("Model request retry %d/%d in %ds: %s", attempt, max, wait, reason))
    report("retry")
    -- 文字用函数, 流式条每次刷新重新求值, 倒计时实时更新; 重发后第一个增量会换回正常内容.
    deps.bar.show_error(function()
      local left = math.max(0, math.ceil(entry.at - deps.now()))
      return string.format("%s, %d 秒后重试 (%d/%d)", entry.reason, left, entry.attempt, entry.max)
    end, wait + 1)
    set_state("retry_wait", reason)
  end

  function callbacks.on_error(reason, detail)
    finish_request()
    transcript({ type = "error", reason = reason, detail = detail })
    -- 上下文超长: 先压缩再重发一次. 历史里已有最新状态 (fresh 不变), 压缩后的下一轮直接重发.
    if tostring(reason):find("上下文超长", 1, true) and not overflow_retried and history:settled() then
      overflow_retried = true
      force_compact = true
      log("warn", "Model request rejected as too long, compacting and retrying once")
      set_state("idle")
      return
    end
    -- 配置错误这类原因太笼统, 带上具体说明 user 才知道改哪里.
    local message = tostring(reason)
    if type(detail) == "string" and detail ~= "" and not message:find(detail, 1, true) then
      local short = detail:gsub("%s+", " ")
      if #short > 120 then
        short = text.cut(short, 120) .. "..."
      end
      message = message .. ": " .. short
    end
    halt(message)
  end

  ---@param usage table
  local function add_usage(usage)
    self.stats.prompt_tokens = self.stats.prompt_tokens + (usage.prompt_tokens or 0)
    self.stats.completion_tokens = self.stats.completion_tokens + (usage.completion_tokens or 0)
    self.stats.cached_tokens = self.stats.cached_tokens + (usage.cached or 0)
  end

  function callbacks.on_done(message, usage)
    finish_request()
    deps.bar.finish()
    usage = usage or {}
    add_usage(usage)
    -- 这次请求的输入加上回复, 就是下一次请求时历史的大致大小 (下一次再加新的状态).
    if (usage.prompt_tokens or 0) > 0 then
      context_used = usage.prompt_tokens + (usage.completion_tokens or 0)
    else
      context_used = nil
    end
    overflow_retried = false
    just_compacted = false
    transcript({
      type = "response",
      seconds = deps.now() - (callbacks.started or deps.now()),
      usage = usage,
      content = message.content,
      reasoning = message.reasoning_content,
      tool_calls = message.tool_calls,
    })
    history:add(message)

    local calls = message.tool_calls or {}
    if #calls == 0 then
      nudges = nudges + 1
      if nudges >= MAX_NUDGES then
        halt("模型连续 " .. nudges .. " 次没有调用工具")
        return
      end
      history:add({ role = "user", content = prompt.NUDGE })
      fresh = true -- 状态没变, 不必再附一遍摘要
      set_state("idle")
    else
      nudges = 0
      queue = { calls = calls, index = 1, version = request_version }
      set_state("acting")
    end
    -- 放在最后: 超过单局上限时运行控制会同步回调 pause, 此时队列已经就位, 能正确回 "未执行".
    report("usage", usage.prompt_tokens or 0, usage.completion_tokens or 0)
  end

  ---@return integer
  local function context_limit()
    local limit = tonumber((deps.config() or {}).context_limit)
    if not limit or limit <= 0 then
      return DEFAULT_CONTEXT
    end
    return limit
  end

  --- 当前上下文占用: 上一次请求的用量, 还没有时按历史估算; 第二个返回值是最大上下文.
  ---@return integer used
  ---@return integer limit
  function self.context_usage()
    return context_used or history:estimate(), context_limit()
  end

  --- 当前上下文是否到了压缩点.
  ---@return boolean
  local function over_threshold()
    if just_compacted then
      return false
    end
    local used = context_used or history:estimate()
    return used > context_limit() * COMPACT_AT
  end

  --- 退路压缩: 丢掉旧消息, 换成每步一行的记录和当前状态.
  ---@param gs table 当前状态
  ---@param why string 退路的原因, 写进日志和转录
  local function compact_with_digest(gs, why)
    summarizer:forget()
    history:compact(turn_message(gs), prompt.recap)
    context_used = nil
    just_compacted = true
    fresh = true
    log("info", "Agent history compacted with step log: " .. why)
    transcript({ type = "compact", method = "digest", reason = why })
  end

  -- 写摘要请求的回调: 流式输出照常显示 (带 "压缩中: " 前缀), 重试与普通请求相同.
  local compact_callbacks = {
    on_delta = callbacks.on_delta,
    on_reset = callbacks.on_reset,
    on_retry = callbacks.on_retry,
  }

  --- 开始压缩: 较早的部分交给模型写摘要. 没有可以压的较早部分时返回 false.
  ---@return boolean
  local function start_compaction()
    -- 实际用量含系统提示和工具定义, 过线时对话本身可能还没到 30%: 这时至少把较早的一半对话交给摘要,
    -- 否则切不出较早的部分, 只能退回记录方式. 系统提示不参与切分, 所以这里只按对话估算.
    local keep = math.min(math.floor(context_limit() * COMPACT_KEEP), math.floor(history:estimate(true) / 2))
    local cut = history:split(keep)
    if not cut then
      return false
    end
    local older = history:render_older(cut, deps.json.encode)
    local messages = {
      { role = "system", content = prompt.COMPACT_SYSTEM },
      { role = "user", content = prompt.compact_request(older) },
    }
    compacting = { cut = cut, messages = cut - 2 }
    self.stats.requests = self.stats.requests + 1
    report("request")
    local cfg = deps.config()
    deps.bar.begin_request(COMPACT_LABEL, { endpoint = cfg.endpoint, model = cfg.model })
    set_state("requesting", "compact")
    log("info", string.format("Compacting agent history: summarizing %d older messages", cut - 2))
    transcript({ type = "compact_start", messages = cut - 2 })
    compact_callbacks.started = deps.now()
    -- 不带工具: 模型只写摘要, 不会在这次请求里操作游戏.
    req = deps.client.start(cfg, messages, nil, compact_callbacks)
    return true
  end

  function compact_callbacks.on_error(reason, detail)
    finish_request()
    local job = compacting
    compacting = nil
    transcript({ type = "error", reason = reason, detail = detail, during = "compact" })
    if not job then
      return
    end
    log("warn", "Agent history summary failed, falling back to step log: " .. tostring(reason))
    deps.bar.show_error("压缩失败, 改用简要记录: " .. tostring(reason), 5)
    compact_with_digest(deps.gamestate(), "summary failed: " .. tostring(reason))
    set_state("idle")
  end

  function compact_callbacks.on_done(message, usage)
    finish_request()
    deps.bar.finish()
    local job = compacting
    compacting = nil
    usage = usage or {}
    add_usage(usage)
    local text = type(message and message.content) == "string" and message.content or ""
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if not job then
      return
    end
    if text == "" then
      log("warn", "Agent history summary was empty, falling back to step log")
      compact_with_digest(deps.gamestate(), "summary empty")
    else
      history:apply_summary(job.cut, prompt.summary(text))
      context_used = nil
      just_compacted = true
      log("info", string.format("Agent history compacted: %d older messages summarized", job.messages))
      transcript({
        type = "compact",
        method = "summary",
        messages = job.messages,
        seconds = deps.now() - (compact_callbacks.started or deps.now()),
        usage = usage,
        summary = text,
      })
    end
    set_state("idle")
    -- 放在最后: 超过单局上限时运行控制会同步回调 pause.
    report("usage", usage.prompt_tokens or 0, usage.completion_tokens or 0)
  end

  ---@param call table
  ---@param content string
  local function tool_result(call, content)
    history:add({ role = "tool", tool_call_id = call.id, content = content })
  end

  --- 剩余的工具调用都回 "未执行".
  ---@param why string
  local function skip_rest(why)
    if not queue then
      return
    end
    for i = queue.index, #queue.calls do
      tool_result(queue.calls[i], "未执行: " .. why)
    end
    queue = nil
  end

  local function cancel_waiting(why)
    if not calling or not deps.cancel_waiting or not deps.cancel_waiting() then return false end
    calling = false
    if pending_call then tool_result(pending_call, "未执行: " .. why); pending_call = nil end
    return true
  end

  --- 出牌那一步的计分过程: 谁加了多少, 从基础涨到多少 (bbcore 的 runtime/scoring.lua 记的).
  --- 明细只在这次结果里给一次, 摘要里只有一行结果, 免得每一轮都重发十几行.
  ---@param method string
  ---@param response table
  ---@return string 不是出牌或没有记录时为空串
  local function scoring_block(method, response)
    if method ~= "play" then
      return ""
    end
    local record = response.round and response.round.last_hand
    if type(record) ~= "table" or type(record.text) ~= "string" then
      return ""
    end
    return "计分过程:\n" .. record.text .. "\n\n"
  end

  --- 查询结果按 JSON 交给模型, 超过上限时截断.
  --- 截断必须落在 UTF-8 字符边界上: 请求体里的字符串是原样发出去的 (编码器只转义控制字符),
  --- 切出半个汉字会让整个请求被服务端拒绝 (400: invalid unicode code point).
  ---@param value any
  ---@return string
  local function encode_query(value)
    local ok, encoded = pcall(deps.json.encode, value)
    local body = ok and encoded or tostring(value)
    if #body > QUERY_RESULT_MAX then
      body = text.cut(body, QUERY_RESULT_MAX) .. "...(已截断, 用 offset 或更具体的 section 继续读)"
    end
    return body
  end

  local function reject_proposal(call, why)
    tool_result(call, "未执行: " .. why)
    skip_rest("需要重新提案")
    proposals_failed = proposals_failed + 1
    fresh = false
    if proposals_failed >= 3 then halt("混合模式连续 3 次无可执行提案") else set_state("idle") end
  end

  --- 执行队列里的下一个工具调用.
  local function run_next()
    if queue.version and deps.version and queue.version ~= deps.version() then
      skip_rest("观察已变化, 重新决策")
      fresh = false
      return
    end
    local call = queue.calls[queue.index]
    queue.index = queue.index + 1
    local selected = queue.selected
    queue.selected = nil
    local fn = selected and { name = selected.method, arguments = deps.json.encode(selected.params) } or call["function"] or {}
    local name = fn.name
    local args = {}
    if fn.arguments and fn.arguments ~= "" then
      local ok, decoded = pcall(deps.json.decode, fn.arguments)
      if not ok or type(decoded) ~= "table" then
        if name == "propose_actions" and deps.config().builtin_backend == "hybrid" then
          reject_proposal(call, "arguments 不是合法的 JSON 对象")
        else tool_result(call, "失败: arguments 不是合法的 JSON 对象") end
        return
      end
      args = decoded
    end
    if name == "propose_actions" and (deps.config() or {}).builtin_backend == "hybrid" and not selected then
      queue.index = queue.index - 1
      decision_generation = decision_generation + 1
      local token, proposal_queue = decision_generation, queue
      proposal_active = true
      decision_version = deps.version and deps.version() or nil
      local decision_started = deps.now()
      set_state("requesting", "decision")
      transcript({ type = "decision_proposal", candidates = args.candidates })
      req = deps.hybrid.start(args, deps.gamestate(), deps.config(), {
        on_request = function(observation, questions)
          report("request", "decision")
          deps.bar.begin_request("Decision 选择中: ", { endpoint = deps.config().decision.endpoint, model = deps.config().decision.model })
          transcript({ type = "decision_request", state = observation, questions = questions })
        end,
        on_retry = function(attempt, max, reason, wait)
          if token ~= decision_generation then return end
          report("retry", "decision"); set_state("retry_wait", reason)
          deps.bar.show_error(reason .. ", " .. wait .. " 秒后重试 (" .. attempt .. "/" .. max .. ")", wait + 1)
        end,
        on_error = function(reason, detail, usage, decision)
          if token ~= decision_generation then return end
          req = nil; proposal_active = false; deps.bar.finish()
          if usage then report("usage", usage.prompt_tokens or 0, usage.completion_tokens or 0, "decision") end
          if token ~= decision_generation then return end
          transcript({ type = "decision_response", detail = decision, error = reason })
          skip_rest("Decision 失败, 未执行")
          halt(reason .. (detail and (": " .. detail) or ""))
        end,
        on_done = function(choice, feedback, usage, decision)
          if token ~= decision_generation or queue ~= proposal_queue then return end
          req = nil; proposal_active = false; deps.bar.finish()
          usage = usage or {}
          transcript({ type = "decision_response", selected = choice, feedback = feedback, detail = decision, usage = usage,
            seconds = deps.now() - decision_started })
          report("usage", usage.prompt_tokens or 0, usage.completion_tokens or 0, "decision")
          if token ~= decision_generation or queue ~= proposal_queue then return end
          if decision then report("choice", choice and choice.method or "拒绝", decision.confidence) end
          if choice then
            proposals_failed = 0
            queue.selected = choice
            queue.decision = decision
            set_state("acting")
          else
            queue.index = queue.index + 1
            tool_result(call, "未执行: " .. tostring(feedback))
            proposals_failed = proposals_failed + 1
            skip_rest("需要重新提案")
            fresh = false
            if proposals_failed >= 3 then halt("混合模式连续 3 次无可执行提案") else set_state("idle") end
          end
        end,
      })
      return
    end
    if not selected and (deps.config() or {}).builtin_backend == "hybrid" and tools.ACTIONS[name] then
      reject_proposal(call, "混合模式必须通过 propose_actions 提案")
      return
    end
    local method, params, reason = tools.to_request(name, args)
    if selected then reason = selected.reason end
    if not method then
      tool_result(call, "失败: " .. tostring(reason))
      return
    end
    -- 设置页给了固定种子时, 开局一律用它, 模型给的种子 (或没给) 都不算.
    local fixed_seed = nil
    if method == "start" then
      local seed = (deps.config() or {}).seed
      if type(seed) == "string" and seed ~= "" then
        fixed_seed = seed
        params.seed = seed
      end
    end
    if selected and deps.planner and not deps.planner.validate(deps.capabilities.snapshot(deps.gamestate()), method, params) then
      tool_result(call, "未执行: 选中动作已不合法")
      skip_rest("重新观察后提案"); fresh = false
      return
    end
    local key = name .. " " .. tostring(fn.arguments)

    calling = true
    pending_call = call
    transcript({ type = "call", method = method, params = params, reason = reason })
    local ok, err = deps.call(method, params, reason, function(response)
      calling = false
      pending_call = nil
      local failed = response.message ~= nil
      if queue and deps.version then queue.version = deps.version() end
      if selected then
        local details = "Decision 已选择: " .. method .. " " .. deps.json.encode(params)
        if queue and queue.decision then details = details .. ", confidence=" .. tostring(queue.decision.confidence) end
        local result_content = scoring_block(method, response) .. "完成. 当前状态:\n" .. summarizer:render(response)
        if failed then result_content = "失败: " .. tostring(response.message) end
        tool_result(call, details .. "\n" .. result_content)
        if not failed then
          self.stats.actions = self.stats.actions + 1
          if method == "start" then summarizer:forget(); report("new_run") end
          fail_key, fail_count = nil, 0
          fresh = true
          history:note(method .. " " .. deps.json.encode(params) .. " (Decision 选择)")
          -- 后续提案必须基于新状态, 同一轮剩余工具结果补齐后重新请求.
          skip_rest("一个提案动作已完成, 请根据新状态继续")
          rearranges = method == "rearrange" and (rearranges + 1) or 0
          if rearranges >= 3 then halt("混合模式连续 3 次只重排, 已暂停") end
          return
        end
        -- 失败计数走下方共用路径, 但避免给同一个 tool_call 两条结果.
      end
      if failed then
        if not selected then tool_result(call, "失败: " .. tostring(response.message)) end
        history:note(string.format("%s 失败: %s", method, tostring(response.message)))
        if key == fail_key then
          fail_count = fail_count + 1
        else
          fail_key, fail_count = key, 1
        end
        -- 失败后状态可能和模型以为的不同, 剩下的调用不再执行.
        skip_rest("前一个操作失败")
        if fail_count >= MAX_REPEAT_FAILS then
          halt("同一个操作连续失败 " .. fail_count .. " 次: " .. method)
        end
        return
      end
      fail_key, fail_count = nil, 0
      if tools.ACTIONS[method] then
        self.stats.actions = self.stats.actions + 1
        if method == "start" then
          summarizer:forget()
          report("new_run")
        end
        local done = "完成. 当前状态:\n"
        if fixed_seed then
          done = "完成 (玩家指定了固定种子 " .. fixed_seed .. ", 已按它开局). 当前状态:\n"
        end
        tool_result(call, scoring_block(method, response) .. done .. summarizer:render(response))
        fresh = true
        history:note(string.format("%s %s%s", method, deps.json.encode(params), reason and (" (" .. reason .. ")") or ""))
      elseif tools.QUERIES[method] then
        tool_result(call, encode_query(response))
      else
        tool_result(call, "已显示")
      end
    end)
    if not ok then
      calling = false
      pending_call = nil
      tool_result(call, "失败: " .. tostring(err))
      skip_rest("前一个操作失败")
    end
  end

  --- idle 时决定下一步.
  local function step_idle()
    if manual_at and deps.now() - manual_at < MANUAL_QUIET then return end
    manual_at = nil
    local next_step = lifecycle.next()
    if next_step.kind == "wait" then set_state("waiting", next_step.detail); return end
    if next_step.kind == "auto" then
      auto(next_step.method, nil, next_step.note, next_step.result and function()
        finish_run(next_step.result)
      end or nil)
      return
    end
    local gs = next_step.gamestate

    -- 上下文到了压缩点 (或服务端报了超长) 时先压缩, 只在一轮完整结束的边界上做.
    -- 写摘要是一次单独的请求, 完成后回到 idle, 下一次进来再发正常的请求.
    if history:settled() and #history.messages > 2 and (force_compact or over_threshold()) then
      force_compact = false
      if start_compaction() then
        return
      end
      -- 较早的部分不够切 (最近一轮本身就很长): 只能整段换成记录.
      compact_with_digest(gs, "nothing older to summarize")
    elseif not fresh then
      history:add({ role = "user", content = turn_message(gs) })
    end
    -- 模型已经拿到最新状态; 之后只有动作, 自动步骤或暂停继续会让它过期.
    fresh = true
    send_request()
  end

  function self.start()
    if self.state ~= "stopped" and self.state ~= "halted" then
      return
    end
    if self.state == "stopped" then
      history.system = system_prompt()
      history:reset()
      summarizer:forget()
      context_used = nil
      overflow_retried = false
      local strategy = (deps.config and deps.config() or {}).strategy
      if type(strategy) == "string" and strategy:find("%S") then
        -- 只记长度, 策略内容在设置页里看.
        log("info", string.format("Agent strategy applied (%d bytes)", #strategy))
      end
    end
    nudges, fail_key, fail_count = 0, nil, 0
    proposals_failed, rearranges = 0, 0
    fresh, note, pause_requested = false, nil, false
    manual_requested, manual_at = false, nil
    compacting, force_compact, just_compacted = nil, false, false
    self.last_error = nil
    transcript({ type = "start" })
    set_state("idle")
  end

  --- 停下后继续 (halted 状态), 保留历史.
  self.retry = self.start

  function self.pause()
    if self.state == "stopped" or self.state == "paused" then
      return
    end
    decision_generation = decision_generation + 1
    proposal_active = false
    if req then
      req:cancel()
      finish_request()
      deps.bar.reset()
    end
    -- 写摘要的请求取消后历史没动, 继续时会重新判断要不要压缩.
    compacting = nil
    -- 暂停后继续本来就重新给状态, 手动操作的作废与等停手都不用再做.
    manual_requested, manual_at = false, nil
    if calling and not cancel_waiting("已暂停") then
      pause_requested = true
      return
    end
    skip_rest("已暂停")
    transcript({ type = "pause" })
    set_state("paused")
  end

  --- 作废按旧状态做的计划: 剩余调用回 "未执行", 下一轮重新给状态并附上说明.
  local function drop_plan()
    skip_rest("user 手动操作了游戏")
    fresh = false
    if not (note and note:find(MANUAL_NOTE, 1, true)) then
      note = (note and note .. "\n" or "") .. MANUAL_NOTE
    end
  end

  --- 人在运行中手动操作了游戏 (解开锁操作后). 写摘要的请求照常进行, 其余见文件头.
  function self.manual()
    local state = self.state
    if state == "stopped" or state == "paused" or state == "halted" then
      return
    end
    manual_at = deps.now()
    if compacting then
      return
    end
    if calling and not cancel_waiting("user 手动操作了游戏") then
      -- 动作正在执行: 做完 (它的结果写进历史) 后在 update 里作废剩下的.
      manual_requested = true
      return
    end
    decision_generation = decision_generation + 1
    proposal_active = false
    if req then
      req:cancel()
      finish_request()
      deps.bar.reset()
    end
    transcript({ type = "manual", state = state })
    log("info", "Manual input during " .. state .. ", dropping the current plan")
    drop_plan()
    if state ~= "idle" then
      set_state("idle")
    end
  end

  function self.resume()
    if self.state ~= "paused" and not pause_requested then
      return
    end
    pause_requested = false
    fresh = false
    note = "(暂停后继续, 期间可能有手动操作, 以下面的状态为准)"
    transcript({ type = "resume" })
    set_state("idle")
  end

  ---@param why string?
  function self.stop(why)
    decision_generation = decision_generation + 1
    proposal_active = false
    if req then
      req:cancel()
      finish_request()
    end
    if calling then
      calling = false
      deps.abandon()
    end
    queue, pending_call = nil, nil
    pause_requested = false
    manual_requested, manual_at = false, nil
    compacting, force_compact, context_used, just_compacted = nil, false, nil, false
    history:reset()
    transcript({ type = "stop", reason = why })
    set_state("stopped", why)
  end

  function self.update()
    if proposal_active and deps.version and decision_version ~= deps.version() then
      self.manual()
      return
    end
    if req then
      req:update()
      if retry and req and self.state == "retry_wait" and deps.now() >= retry.at then
        set_state("requesting")
      end
      return
    end
    if calling then
      return
    end
    if pause_requested then
      pause_requested = false
      skip_rest("已暂停")
      set_state("paused")
      return
    end
    if manual_requested then
      manual_requested = false
      transcript({ type = "manual", state = self.state })
      log("info", "Manual input during an action, dropping the rest of the plan")
      drop_plan()
      if self.state == "acting" then
        set_state("idle")
      end
      return
    end
    if self.state == "acting" then
      if queue and queue.index <= #queue.calls then
        if deps.busy() or deps.overlay() == "other" then
          return
        end
        run_next()
        return
      end
      queue = nil
      set_state("idle")
      return
    end
    if self.state == "idle" or self.state == "waiting" then
      step_idle()
    end
  end

  -- 只给测试用.
  self._history = history

  return self
end

return M
