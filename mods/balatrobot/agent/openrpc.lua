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
  local encoded_ok, encoded = pcall(json.encode, spec)
  return encoded_ok and encoded or spec_text
end

return M
