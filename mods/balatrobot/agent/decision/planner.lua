-- 有界的分层动作参数选择, 只在完成后交出真实动作.
local M = {}
local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}; for k, v in pairs(t) do out[k] = copy(v) end; return out
end
local function contains(values, value)
  for _, v in ipairs(values or {}) do if v == value then return true end end
  return false
end
local function indices(value, allowed, min, max, required)
  if type(value) ~= "table" or #value < min or #value > max then return false end
  local seen, count = {}, 0
  for k, v in pairs(value) do
    if type(k) ~= "number" or k < 1 or k > #value or k ~= math.floor(k) then return false end
    if type(v) ~= "number" or v ~= math.floor(v) or seen[v] or not contains(allowed, v) then return false end
    seen[v] = true; count = count + 1
  end
  if count ~= #value then return false end
  for _, v in ipairs(required or {}) do if not seen[v] then return false end end
  return true
end

function M.validate(capabilities, method, params)
  if type(params) ~= "table" then return false end
  for _, action in ipairs(capabilities.actions) do
    if method == action.method then
      local ok, fields = true, {}
      for key, value in pairs(action.params) do
        fields[key] = true; if params[key] ~= value then ok = false end
      end
      if action.decks then
        fields.deck, fields.stake, fields.seed = true, true, true
        ok = ok and contains(action.decks, params.deck) and contains(action.stakes, params.stake)
        if params.seed ~= nil and (type(params.seed) ~= "string" or #params.seed > 8 or not params.seed:match("^[A-Za-z0-9]+$")) then ok = false end
      end
      if action.target then
        local t = action.target; fields[t.field] = true
        ok = ok and indices(params[t.field], t.indices, t.min, t.max, t.forced)
      end
      if action.move then
        local move = action.move; fields[move.area] = true
        local allowed = {}; for i = 1, move.count do allowed[i] = i - 1 end
        local permutation = params[move.area]
        ok = ok and indices(permutation, allowed, move.count, move.count)
        local changed = false
        if ok then for i, v in ipairs(permutation) do if v ~= i - 1 then changed = true end end end
        ok = ok and changed
      end
      for field in pairs(params) do if not fields[field] then ok = false end end
      if ok then return true end
    end
  end
  return false
end

function M.new(capabilities, cfg)
  local self = { phase = "action", selected = {}, requests = 0 }
  local pending, mapped, action
  local function option(label, value) return { label = label, value = value } end
  local function finish()
    self.result = { method = action.method, params = copy(action.params), label = action.label }
    if self.result.method == "start" and cfg.seed and cfg.seed ~= "" then self.result.params.seed = cfg.seed end
    self.phase = "done"
  end
  local function after_action()
    if action.decks then self.phase = "deck"
    elseif action.method == "play" and action.play_options and #action.play_options > 0 then self.phase = "play_set"
    elseif action.target then self.phase = "targets"; self.selected = copy(action.target.forced or {})
    elseif action.move then self.phase = "move_card"
    else finish() end
  end
  local function options()
    local out = {}
    if self.phase == "action" then
      for i, item in ipairs(capabilities.actions) do out[i] = option(item.label, i) end
    elseif self.phase == "deck" or self.phase == "stake" then
      for i, value in ipairs(self.phase == "deck" and action.decks or action.stakes) do out[i] = option(value, value) end
    elseif self.phase == "play_set" then
      for _, candidate in ipairs(action.play_options) do out[#out + 1] = option(candidate.label, candidate.indices) end
      out[#out + 1] = option("自定义完整出牌组合, 继续逐张选择", "manual")
    elseif self.phase == "targets" then
      local target = action.target
      if #self.selected < target.max then
        for _, index in ipairs(target.indices) do
          if not contains(self.selected, index) then
            local label = "追加 hand[" .. index .. "]"
            if action.method == "play" and capabilities.preview_hand then
              local proposed = copy(self.selected); proposed[#proposed + 1] = index
              local preview = capabilities.preview_hand(proposed)
              label = label .. ", 追加后 " .. (preview.label or preview.note)
              if preview.reference_score then label = label .. ", 参考 " .. preview.reference_score .. " 分" end
            end
            out[#out + 1] = option(label, index)
          end
        end
      end
      if #self.selected >= target.min then
        out[#out + 1] = option("完成选牌, 立即 " .. action.method .. " 已选的 " .. #self.selected .. " 张: hand[" .. table.concat(self.selected, ",") .. "]", "finish")
      end
    elseif self.phase == "move_card" or self.phase == "move_position" then
      for i = 0, action.move.count - 1 do
        if self.phase == "move_card" or i ~= self.move_card then
          out[#out + 1] = option((self.phase == "move_card" and "移动 " .. action.move.area .. "[" .. i .. "]" or "移到位置 " .. i), i)
        end
      end
    end
    return out
  end

  function self.context()
    return { step = self.phase, action = action and action.method, params = action and copy(action.params),
      selected_hand_indices = copy(self.selected), move_card = self.move_card,
      selection_limits = action and action.target and { min = action.target.min, max = action.target.max },
      selected_hand_preview = action and action.method == "play" and capabilities.preview_hand and capabilities.preview_hand(self.selected) or nil }
  end

  function self.question()
    if self.phase == "done" then return nil end
    pending = pending or options()
    if #pending == 0 then return nil, "没有可用的动作或参数" end
    if self.requests >= 64 then return nil, "Decision 单次动作规划超过 64 次请求" end
    self.requests = self.requests + 1
    mapped = {}
    local criteria = {}
    if #pending > 255 then
      local size = math.ceil(#pending / 255)
      for i = 1, #pending, size do
        local group = {}
        for j = i, math.min(i + size - 1, #pending) do group[#group + 1] = pending[j] end
        local id = "g" .. (#mapped + 1)
        mapped[#mapped + 1] = { id = id, value = { group = group } }
        criteria[id] = "候选 " .. i .. " 至 " .. math.min(i + size - 1, #pending) .. ": " .. group[1].label .. " ... " .. group[#group].label
      end
    else
      for i, item in ipairs(pending) do
        local id = "o" .. i; mapped[i] = { id = id, value = item.value, label = item.label }; criteria[id] = item.label
      end
    end
    local instructions = "根据当前局面与策略选择最有利的一项. 当前参数选择步骤: " .. self.phase
    if self.phase == "play_set" then
      instructions = instructions .. ". 每项是一组立即打出的完整手牌, 下标为 0-based. 比较整组牌型, 得分需求与留牌收益. "
        .. "参考分未计特殊效果, 不等于实际分. 单张通常只是高牌, 不要在能组成有效多牌牌型时无理由只打 1 张. 若需要其他组合选自定义."
    elseif self.phase == "targets" and action.method == "play" then
      instructions = instructions .. ". 选牌尚未执行. 追加项会继续组成手牌, 完成项会立即打出当前已选牌. "
        .. "先完成计划牌型再执行, 仅选 1 张通常为高牌, 并不代表系统替你选好了整副牌."
    end
    return { decision = { type = "choice", instructions = instructions, criteria = criteria } }
  end

  function self.answer(answers)
    local answer = answers and answers.decision
    if not answer then return false, "缺少 Decision 选择" end
    local found
    for _, item in ipairs(mapped or {}) do if item.id == answer.choice then found = item; break end end
    if not found then return false, "Decision 选择不在当前候选内" end
    local value = found.value
    mapped = nil
    if type(value) == "table" and value.group then pending = value.group; return true end
    pending = nil
    if self.phase == "action" then action = copy(capabilities.actions[value]); after_action()
    elseif self.phase == "deck" then action.params.deck = value; self.phase = "stake"
    elseif self.phase == "stake" then action.params.stake = value; finish()
    elseif self.phase == "play_set" then
      if value == "manual" then self.phase = "targets"; self.selected = copy(action.target.forced or {})
      else
        local params = copy(action.params); params[action.target.field] = copy(value)
        if not M.validate(capabilities, action.method, params) then return false, "完整出牌组合不合法" end
        action.params, action.label = params, found.label; self.selected = copy(value); finish()
      end
    elseif self.phase == "targets" then
      if value == "finish" then action.params[action.target.field] = copy(self.selected); finish()
      else self.selected[#self.selected + 1] = value end
    elseif self.phase == "move_card" then self.move_card = value; self.phase = "move_position"
    elseif self.phase == "move_position" then
      local order = {}; for i = 0, action.move.count - 1 do if i ~= self.move_card then order[#order + 1] = i end end
      table.insert(order, value + 1, self.move_card)
      action.params[action.move.area] = order; finish()
    else return false, "Decision 参数选择状态无效" end
    return true
  end

  return self
end

return M
