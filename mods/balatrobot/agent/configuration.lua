-- 内置 agent 的连接配置与预设, 不依赖游戏.
local M = {}

M.BACKENDS = { "llm", "decision", "hybrid" }
M.LABELS = { llm = "LLM", decision = "Decision", hybrid = "混合" }
M.PRESETS = {
  typesafe = { endpoint = "https://api.typesafe.ai/v1/systemone", model = "jev-latest", auth = "bearer" },
  aihubmix = { endpoint = "https://aihubmix.com/v1/systemone", model = "jev-1.13", auth = "bearer" },
}
M.LLM_FIELDS = { "endpoint", "model", "api_key", "auth", "api_format", "context_limit", "reasoning_effort", "thinking" }

function M.copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = M.copy(v) end
  return out
end

function M.apply_preset(config, provider)
  local preset = M.PRESETS[provider]
  if not preset then
    if provider ~= "custom" then return false end
    config.provider = provider
    return true
  end
  for k, v in pairs(preset) do config[k] = v end
  config.provider = provider
  return true
end

-- driver 仍使用一份扁平的运行配置, 存储只保留嵌套连接.
function M.runtime(config)
  local out = M.copy(config)
  for _, key in ipairs(M.LLM_FIELDS) do out[key] = (config.llm or {})[key] end
  return out
end

local function connection_error(connection, label)
  if type(connection) ~= "table" then return label .. " 缺少连接配置" end
  for _, item in ipairs({ { "endpoint", "endpoint" }, { "model", "模型名" }, { "api_key", "key" } }) do
    local value = connection[item[1]]
    if type(value) ~= "string" or not value:find("%S") then return label .. " 缺少 " .. item[2] end
    if value:find("[%c]") then return label .. " 配置含有控制字符" end
  end
  if not connection.endpoint:match("^https?://[^/%s?#]+") then return label .. " endpoint 无效" end
  if connection.api_key:find("%s") then return label .. " key 含有空白" end
  local auth = connection.auth
  if auth ~= "bearer" and auth ~= "raw" and auth ~= "x-api-key" then return label .. " 鉴权方式无效" end
end

function M.validate(config)
  local backend = config.builtin_backend or "llm"
  if not M.LABELS[backend] then return false, "内置决策方式无效" end
  if backend ~= "decision" then
    local err = connection_error(config.llm, "LLM")
    if err then return false, err end
    local format = config.llm.api_format
    if format ~= "chat" and format ~= "responses" and format ~= "anthropic" then
      return false, "LLM 接口协议无效"
    end
  end
  if backend ~= "llm" then
    local err = connection_error(config.decision, "Decision")
    if err then return false, err end
    local threshold = config.decision.min_confidence or 0
    if type(threshold) ~= "number" or threshold ~= threshold or threshold < 0 or threshold > 1 then
      return false, "Decision 最低置信度无效"
    end
  end
  return true
end

-- v3 的顶层连接只搬运一次, 不在运行时维护两份来源.
function M.migrate(config, previous_version)
  config.llm = config.llm or {}
  config.decision = config.decision or { provider = "typesafe", api_key = "", min_confidence = 0 }
  if not config.decision.endpoint then M.apply_preset(config.decision, "typesafe") end
  if previous_version < 4 then
    for _, key in ipairs(M.LLM_FIELDS) do
      if config[key] ~= nil then config.llm[key] = config[key] end
      config[key] = nil
    end
    config.builtin_backend = "llm"
  end
end

return M
