-- System One 的请求与类型化答案, 不依赖游戏和网络.
local M = {}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function probability(value) return finite(value) and value >= 0 and value <= 1 end
local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end
local function instructions(value)
  return (type(value) == "string" and value:find("%S") ~= nil) or type(value) == "table"
end

function M.new(chat)
  local protocol = {}

  function protocol.url(endpoint)
    if type(endpoint) ~= "string" or endpoint:find("[%c]") then return nil, "Decision endpoint 含有控制字符" end
    local url = chat.trim(endpoint)
    if not url:match("^https?://[^/%s?#]+") or url:find("[%c%s#]") then return nil, "Decision endpoint 无效" end
    local base, query = url:match("^([^?]*)(.*)$")
    base = base:gsub("/+$", "")
    if not base:match("/systemone$") and not base:match("/alpha/decisions$") then base = base .. "/systemone" end
    return base .. query
  end

  function protocol.request(cfg, state, questions)
    local url, err = protocol.url(cfg and cfg.endpoint)
    if not url then return nil, err end
    local model = chat.trim(cfg.model)
    if model == "" then return nil, "Decision 缺少模型名" end
    if type(state) ~= "string" and type(state) ~= "table" then return nil, "Decision state 类型无效" end
    if type(questions) ~= "table" or next(questions) == nil then return nil, "Decision questions 不能为空" end
    local prepared = chat.object({})
    for id, question in pairs(questions) do
      if type(id) ~= "string" or id == "" or type(question) ~= "table" or not instructions(question.instructions) then
        return nil, "Decision 问题定义无效"
      end
      local q = { type = question.type, instructions = question.instructions }
      if q.type == "choice" then
        local criteria = question.criteria
        if type(criteria) ~= "table" or count(criteria) < 1 or count(criteria) > 255 then
          return nil, "Choice 必须包含 1 至 255 个候选"
        end
        q.criteria = chat.object({})
        for key, value in pairs(criteria) do
          if type(key) ~= "string" or key == "" or (value ~= chat.NULL and not instructions(value)) then return nil, "Choice criteria 必须是选项名到描述的对象" end
          q.criteria[key] = value
        end
      elseif q.type == "score" then
        local criteria = question.criteria
        if type(criteria) ~= "table" or #criteria < 2 or #criteria > 10 or count(criteria) ~= #criteria then
          return nil, "Score criteria 必须是 2 至 10 个等级的数组"
        end
        q.criteria = {}
        for i, value in ipairs(criteria) do
          if not instructions(value) then return nil, "Score 等级描述无效" end
          q.criteria[i] = value
        end
      elseif q.type == "noul" then
        if question.criteria ~= nil then
          if type(question.criteria) ~= "table" then return nil, "Noul criteria 必须是对象" end
          q.criteria = chat.object({})
          for key, value in pairs(question.criteria) do
            if (key ~= "true" and key ~= "false") or not instructions(value) then return nil, "Noul criteria 只能定义 true / false" end
            q.criteria[key] = value
          end
        end
      else return nil, "Decision 不支持该问题类型" end
      prepared[id] = q
    end
    local body, why = chat.encode_body({ model = model, state = state, questions = prepared })
    if not body then return nil, why end
    if #body > 128 * 1024 then return nil, "Decision 请求超过 128 KiB 输入上限" end
    return { url = url, headers = chat.headers(cfg, false), body = body, model = model }
  end

  local function distribution(answer, keys)
    if type(answer.probabilities) ~= "table" or not probability(answer.confidence) then return false end
    local sum = 0
    for key in pairs(keys) do
      local p = answer.probabilities[key]
      if not probability(p) then return false end
      sum = sum + p
    end
    for key in pairs(answer.probabilities) do if not keys[key] then return false end end
    return math.abs(sum - 1) <= 0.02
  end

  function protocol.response(value, questions)
    if type(value) ~= "table" or type(value.answers) ~= "table" then return nil, "Decision 缺少 answers 对象" end
    local answers = {}
    for id, question in pairs(questions) do
      local answer = value.answers[id]
      if type(answer) ~= "table" or answer.type ~= question.type then return nil, "Decision 答案问题 ID 或类型不匹配" end
      if question.type == "choice" then
        if type(answer.choice) ~= "string" or question.criteria[answer.choice] == nil then return nil, "Decision 选择不在候选内" end
        if not distribution(answer, question.criteria) then return nil, "Decision Choice 概率或置信度无效" end
      elseif question.type == "score" then
        if not finite(answer.score) or answer.score < 0 or answer.score > #question.criteria - 1 then return nil, "Decision Score 超出等级范围" end
        local keys = {}
        for i = 1, #question.criteria do keys[tostring(i - 1)] = true end
        if not distribution(answer, keys) then return nil, "Decision Score 概率或置信度无效" end
      elseif not probability(answer.noul) then return nil, "Decision Noul 概率无效" end
      answers[id] = answer
    end
    local raw_usage = value.usage or {}
    if type(raw_usage) ~= "table" then return nil, "Decision usage 无效" end
    local usage = { prompt_tokens = raw_usage.input_tokens or 0, completion_tokens = raw_usage.output_tokens or 0 }
    for _, tokens in pairs(usage) do
      if not finite(tokens) or tokens < 0 or tokens ~= math.floor(tokens) then return nil, "Decision token 用量无效" end
    end
    return { answers = answers, model = value.model, id = value.id, provider = value.provider, cost = raw_usage.cost }, usage
  end

  return protocol
end

return M
