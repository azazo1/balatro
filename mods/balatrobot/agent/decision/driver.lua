-- 独立 Decision 循环: 观察, 分层选择, 再校验, 一次执行一个动作.
local M = {}

function M.new(deps)
  local self = { state = "stopped", stats = { requests = 0, actions = 0 } }
  local lifecycle = deps.lifecycle.new(deps)
  local req, plan, snapshot, version, calling, paused_after, manual_at
  local trail, generation, fail_key, fail_count, rearranges = {}, 0, nil, 0, 0
  local function report(event, ...) if deps.report then deps.report(event, ...) end end
  local function transcript(entry)
    if deps.transcript then entry.t = deps.now(); pcall(deps.transcript, entry) end
  end
  local function state(value, detail)
    self.state = value; if deps.on_state then deps.on_state(value, detail) end
  end
  local function forget()
    generation = generation + 1
    if req then req:cancel(); req = nil end
    plan, snapshot, version = nil, nil, nil
    deps.bar.finish()
  end
  local function halt(reason)
    forget(); self.last_error = reason; state("halted", reason)
    transcript({ type = "halt", backend = "decision", reason = reason })
    report("halt", reason)
  end
  local function record(method, params, response)
    trail[#trail + 1] = { method = method, params = params, error = response.message,
      state = response.state, money = response.money, round = response.round and {
        chips = response.round.chips, hands_left = response.round.hands_left, discards_left = response.round.discards_left,
        last_hand = response.round.last_hand and response.round.last_hand.line } }
    while #trail > 20 do table.remove(trail, 1) end
  end
  local function action_done(method, params, response, after)
    calling = false
    record(method, params, response)
    transcript({ type = "call_result", method = method, ok = response.message == nil, error = response.message })
    if response.message then
      local key = method .. " " .. deps.json.encode(params)
      if key == fail_key then fail_count = fail_count + 1 else fail_key, fail_count = key, 1 end
      if fail_count >= 3 then halt("同一个 Decision 动作连续失败 3 次: " .. method); return end
    else
      fail_key, fail_count = nil, 0
      self.stats.actions = self.stats.actions + 1
      if method == "start" then trail = {}; report("new_run") end
      rearranges = method == "rearrange" and (rearranges + 1) or 0
      if rearranges >= 3 then halt("Decision 连续 3 次只重排, 已暂停"); return end
    end
    forget()
    if self.state == "stopped" then return end
    if paused_after then paused_after = false; state("paused") else state("idle") end
    if after and not response.message then after() end
  end
  local function invoke(method, params, reason, after)
    calling = true; state("acting", method)
    transcript({ type = "call", backend = "decision", method = method, params = params, reason = reason })
    local token = generation
    local ok, err = deps.call(method, params, reason, function(response)
      if token ~= generation then return end
      action_done(method, params, response, after)
    end)
    if not ok then calling = false; halt("Decision 动作无法提交: " .. tostring(err)) end
  end
  local function send()
    local questions, err = plan.question()
    if not questions then halt(err or "Decision 参数选择失败"); return end
    local cfg = deps.config()
    local observation, why = deps.observation.state(snapshot, cfg, trail, plan.context())
    if not observation then halt(why); return end
    local token, started = generation, deps.now()
    self.stats.requests = self.stats.requests + 1
    report("request", "decision")
    deps.bar.begin_request("Decision 选择中: ", { endpoint = cfg.decision.endpoint, model = cfg.decision.model })
    state("requesting", "decision")
    transcript({ type = "decision_request", step = plan.phase, questions = questions, state = observation })
    req = deps.client.start(cfg.decision, observation, questions, {
      on_retry = function(attempt, max, reason, wait)
        if token ~= generation then return end
        report("retry", "decision"); state("retry_wait", reason)
        deps.bar.show_error(reason .. ", " .. wait .. " 秒后重试 (" .. attempt .. "/" .. max .. ")", wait + 1)
      end,
      on_error = function(reason, detail)
        if token ~= generation then return end
        req = nil; halt(reason .. (detail and (": " .. detail) or ""))
      end,
      on_done = function(result, usage)
        if token ~= generation then return end
        req = nil; deps.bar.finish()
        local answer = result.answers.decision
        transcript({ type = "decision_response", seconds = deps.now() - started, answers = result.answers,
          usage = usage, model = result.model, provider = result.provider, id = result.id })
        report("usage", usage.prompt_tokens, usage.completion_tokens, "decision")
        -- 用量汇报可能同步触发暂停并清掉 plan.
        if token ~= generation or not plan then return end
        report("choice", questions.decision.criteria[answer.choice], answer.confidence)
        local threshold = cfg.decision.min_confidence or 0
        if answer.confidence < threshold then halt("Decision 置信度低于阈值, 请手动调整局面或停止后修改阈值"); return end
        local ok, why_answer = plan.answer(result.answers)
        if not ok then halt(why_answer); return end
        state("idle")
      end,
    })
  end

  function self.start()
    forget(); trail, fail_key, fail_count, rearranges = {}, nil, 0, 0
    calling, paused_after, manual_at = false, false, nil
    lifecycle.reset(); self.last_error = nil
    transcript({ type = "start", backend = "decision" }); state("idle")
  end
  function self.pause()
    if self.state == "stopped" or self.state == "paused" then return end
    if calling then
      if not deps.cancel_waiting or not deps.cancel_waiting() then paused_after = true; return end
      calling = false
    end
    forget(); transcript({ type = "pause", backend = "decision" }); state("paused")
  end
  function self.resume()
    if self.state ~= "paused" and self.state ~= "halted" then return end
    forget(); paused_after = false; self.last_error = nil; state("idle")
  end
  self.retry = self.resume
  function self.stop(reason)
    forget()
    if calling then deps.abandon() end
    calling, paused_after, manual_at = false, false, nil
    transcript({ type = "stop", backend = "decision", reason = reason }); state("stopped")
  end
  function self.manual()
    if self.state == "stopped" or self.state == "paused" or self.state == "halted" then return end
    manual_at = deps.now()
    if calling then
      if not deps.cancel_waiting or not deps.cancel_waiting() then return end
      calling = false
    end
    forget(); transcript({ type = "manual", backend = "decision" }); state("idle")
  end
  function self.context_usage() return 0, 0 end
  function self.update()
    if self.state == "stopped" or self.state == "paused" or self.state == "halted" or calling then return end
    if manual_at and deps.now() - manual_at < 1.5 then return end
    if plan and deps.version and version ~= deps.version() then forget(); state("idle") end
    if req then req:update(); return end
    if deps.busy() then return end
    if plan then
      if deps.overlay() then forget(); state("idle"); return end
      if plan.result then
        local action = plan.result
        if not deps.planner.validate(deps.capabilities.snapshot(deps.gamestate()), action.method, action.params) then
          forget(); state("idle"); return
        end
        invoke(action.method, action.params, "按 Decision 的选择执行. " .. action.label .. ".")
      else send() end
      return
    end
    local next_step = lifecycle.next()
    if next_step.kind == "wait" then state("waiting", next_step.detail); return end
    if next_step.kind == "auto" then
      invoke(next_step.method, {}, nil, next_step.result and function()
        transcript({ type = "finish", result = next_step.result, backend = "decision" })
        if deps.config().after_run ~= "continue" then report("finish", next_step.result) end
      end or nil)
      return
    end
    manual_at = nil
    snapshot = next_step.gamestate
    local capabilities = deps.capabilities.snapshot(snapshot)
    if capabilities.unsupported then halt("Decision 遇到无法适配的卡牌目标规则"); return end
    if #capabilities.actions == 0 then halt("Decision 当前局面没有可用候选动作"); return end
    version = deps.version and deps.version() or nil
    plan = deps.planner.new(capabilities, deps.config())
    send()
  end

  return self
end

return M
