-- 把本仓库新增的接口写进 rpc.discover 返回的 OpenRPC 文档: notify 方法, 以及各方法的可选 reason 参数.

local json = require("json")

local M = {}

local REASON = {
  name = "reason",
  description = "Optional short decision message, shown in game and written to the recording timeline",
  required = false,
  schema = { type = "string", maxLength = 200 },
}

local NOTIFY = {
  name = "notify",
  summary = "Show an agent message in game",
  description = "Shows a short message in the vanilla notification style. Works in any game state.",
  params = {
    { name = "message", required = true, schema = { type = "string", minLength = 1, maxLength = 200 } },
    { name = "title", required = false, schema = { type = "string", maxLength = 40 } },
    { name = "duration", required = false, schema = { type = "number", exclusiveMinimum = 0, maximum = 30 } },
  },
  result = {
    name = "notify",
    schema = {
      type = "object",
      properties = { success = { type = "boolean", const = true } },
      required = { "success" },
    },
  },
  errors = {},
}

local ENDLESS = {
  name = "endless",
  summary = "Continue in endless mode from the win screen",
  description = "After beating the ante 8 boss the win screen opens and other actions are rejected. "
    .. "Closes it like the Endless Mode button, then returns once round evaluation shows cash_out.",
  params = {},
  result = {
    name = "gamestate",
    description = "Game state in ROUND_EVAL, ready for cash_out",
    schema = { ["$ref"] = "#/components/schemas/GameState" },
  },
  errors = { { ["$ref"] = "#/components/errors/InvalidState" } },
}

local CONTINUE = {
  name = "continue",
  summary = "Close the unlock notification",
  description = "Closes the unlock notification like its Continue button. If an earlier request returned early "
    .. "because the notification opened, waits for that request and returns its result; otherwise returns the current state.",
  params = {},
  result = {
    name = "gamestate",
    description = "Result of the interrupted request, or the current game state",
    schema = { ["$ref"] = "#/components/schemas/GameState" },
  },
  errors = { { ["$ref"] = "#/components/errors/InvalidState" } },
}

-- 没有弹窗时字段不出现 (Lua 的 nil 不会被编码).
local OVERLAY = {
  type = "string",
  enum = { "unlock", "win", "other" },
  description = "Overlay menu that is open, absent when none. 'unlock': unlock notification, call continue. "
    .. "'win': win screen, call endless or menu. 'other': a menu opened in game. "
    .. "Most actions are rejected while it is set, and a waiting request returns early when one opens",
}

---@param spec_text string
---@param passive table<string, boolean>
---@return string
function M.extend(spec_text, passive)
  local ok, spec = pcall(json.decode, spec_text)
  if not ok or type(spec) ~= "table" or type(spec.methods) ~= "table" then
    return spec_text
  end
  for _, method in ipairs(spec.methods) do
    if not passive[method.name] and type(method.params) == "table" then
      table.insert(method.params, REASON)
    end
  end
  table.insert(spec.methods, NOTIFY)
  table.insert(spec.methods, ENDLESS)
  table.insert(spec.methods, CONTINUE)
  local schemas = spec.components and spec.components.schemas
  if schemas and schemas.GameState and schemas.GameState.properties then
    schemas.GameState.properties.overlay = OVERLAY
  end
  local encoded_ok, encoded = pcall(json.encode, spec)
  return encoded_ok and encoded or spec_text
end

return M
