-- 混合模式的候选校验和 System One 选择, 不直接执行动作.
local M = {}
local function deferred(callback)
  local request = { cancelled = false, done = false }
  function request:cancel() self.cancelled = true end
  function request:update()
    if self.cancelled or self.done then return end
    self.done = true; callback()
  end
  return request
end

function M.new(deps)
  local hybrid = {}
  function hybrid.start(args, gs, cfg, callbacks)
    local candidates, errors, seen = {}, {}, {}
    local proposed = type(args) == "table" and args.candidates
    local capabilities = deps.capabilities.snapshot(gs)
    if type(proposed) ~= "table" or #proposed < 1 or #proposed > 4 then
      return deferred(function() callbacks.on_done(nil, "propose_actions 必须包含 1 至 4 项候选", {}) end)
    end
    for i, candidate in ipairs(proposed) do
      local valid = type(candidate) == "table" and type(candidate.method) == "string"
        and type(candidate.params) == "table" and type(candidate.reason) == "string" and candidate.reason:find("%S")
      local params = {}
      if valid then
        for key, value in pairs(candidate.params) do params[key] = value end
        if candidate.method == "start" and cfg.seed and cfg.seed ~= "" then params.seed = cfg.seed end
        valid = deps.planner.validate(capabilities, candidate.method, params)
      end
      if not valid then errors[#errors + 1] = "候选 " .. i .. " 方法, 参数或局面不合法"
      else
        local key = candidate.method .. deps.json.encode(params)
        if not seen[key] then
          seen[key] = true
          candidates[#candidates + 1] = { method = candidate.method, params = params, reason = candidate.reason }
        end
      end
    end
    if #candidates == 0 then
      return deferred(function() callbacks.on_done(nil, table.concat(errors, "; "), {}) end)
    end
    local observation, err = deps.observation.state(gs, cfg, {}, { candidates = candidates })
    if not observation then return deferred(function() callbacks.on_error(err) end) end
    local questions
    if #candidates == 1 then
      questions = { select_action = { type = "noul", instructions = "考虑当前局面与策略, 是否应执行 planning.candidates 中的唯一动作?" } }
    else
      local criteria = {}
      for i, candidate in ipairs(candidates) do
        criteria["c" .. i] = candidate.method .. " " .. deps.json.encode(candidate.params) .. ". 提案理由: " .. candidate.reason
      end
      questions = { select_action = { type = "choice", instructions = "选择最有利于本局目标的一个候选动作. 提案理由只是 LLM 的判断, 请结合局面核查.", criteria = criteria } }
    end
    if callbacks.on_request then callbacks.on_request(observation, questions) end
    return deps.client.start(cfg.decision, observation, questions, {
      on_retry = callbacks.on_retry,
      on_error = callbacks.on_error,
      on_done = function(result, usage)
        local answer = result.answers.select_action
        local confidence = #candidates == 1 and answer.noul or answer.confidence
        local threshold = math.max(#candidates == 1 and 0.5 or 0, cfg.decision.min_confidence or 0)
        local detail = { confidence = confidence, answer = answer, model = result.model, usage = usage, candidates = candidates,
          provider = result.provider, id = result.id, cost = result.cost }
        if #candidates == 1 and answer.noul < 0.5 then callbacks.on_done(nil, "Decision 拒绝唯一候选, 请重新提案", usage, detail); return end
        if confidence < threshold then callbacks.on_error("Decision 置信度低于阈值", nil, usage, detail); return end
        local index = #candidates == 1 and 1 or tonumber(answer.choice:match("^c(%d+)$"))
        if not index or not candidates[index] then callbacks.on_error("Decision 选择不在混合候选内", nil, usage, detail); return end
        callbacks.on_done(candidates[index], table.concat(errors, "; "), usage, detail)
      end,
    })
  end
  return hybrid
end

return M
