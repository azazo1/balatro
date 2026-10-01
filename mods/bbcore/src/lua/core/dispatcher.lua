--[[
  Request Dispatcher - Routes API requests to endpoints with 4-tier validation:
  1. Protocol (method field)  2. Schema (via Validator)
  3. Game state               4. Execution
]]

---@type Validator
local Validator = assert(SMODS.load_file("src/lua/core/validator.lua"))()
---@type BB_LOGGER
local BB_LOGGER = assert(SMODS.load_file("src/lua/utils/logger.lua"))()
local socket = require("socket")

---@type table<integer, string>?
local STATE_NAME_CACHE = nil

-- 本仓库修改: 讲解 (agent 的 notify) 还在屏幕上或队里时, 后面的请求等它退去再执行, 这样观众总是
-- 先看到文字再看到动作. 不等讲解的只有两类: 只读方法 (BB_ACTIVITY.PASSIVE: 查询状态, 查手册等),
-- 以及 start 与 menu (它们会把画面整个换掉, 与当前讲解无关).
-- notify 不是只读 (它要往屏幕上放东西), 所以它也要等前一条讲解退去, 消息一条条来.
-- 排队与退去的判断在 runtime/toast.lua (gate_id / gate_open).
local GATE_EXEMPT = { ["start"] = true, ["menu"] = true }
-- 等讲解退去的上限. 正常的等待是一两条讲解 (每条读完加停留约 10~40 秒), 这里给足余量;
-- 它只是显示异常时的兜底 (例如通知被别的东西弄没了), 到点就执行, 免得请求一直挂着.
local GATE_TIMEOUT = 120
---@type table[] 等讲解退去的请求, 按到达顺序
local deferred = {}

--- 这个方法要不要等讲解退去.
---@param method string
---@return boolean
local function gated_method(method)
  if GATE_EXEMPT[method] then
    return false
  end
  return not (BB_ACTIVITY and BB_ACTIVITY.PASSIVE and BB_ACTIVITY.PASSIVE[method] == true)
end

---@param state_value integer
---@return string
local function get_state_name(state_value)
  if not STATE_NAME_CACHE then
    STATE_NAME_CACHE = {}
    if G and G.STATES then
      for name, value in pairs(G.STATES) do
        STATE_NAME_CACHE[value] = name
      end
    end
  end
  return STATE_NAME_CACHE[state_value] or tostring(state_value)
end

---@type Dispatcher
BB_DISPATCHER = {
  endpoints = {},
  Server = nil,
}

---@param endpoint Endpoint
---@return boolean success
---@return string? error_message
local function validate_endpoint_structure(endpoint)
  if not endpoint.name or type(endpoint.name) ~= "string" then
    return false, "Endpoint missing 'name' field (string)"
  end
  if not endpoint.description or type(endpoint.description) ~= "string" then
    return false, "Endpoint '" .. endpoint.name .. "' missing 'description' field (string)"
  end
  if not endpoint.schema or type(endpoint.schema) ~= "table" then
    return false, "Endpoint '" .. endpoint.name .. "' missing 'schema' field (table)"
  end
  if not endpoint.execute or type(endpoint.execute) ~= "function" then
    return false, "Endpoint '" .. endpoint.name .. "' missing 'execute' field (function)"
  end
  if endpoint.requires_state ~= nil and type(endpoint.requires_state) ~= "table" then
    return false, "Endpoint '" .. endpoint.name .. "' 'requires_state' must be nil or table"
  end
  for field_name, field_schema in pairs(endpoint.schema) do
    if type(field_schema) ~= "table" then
      return false, "Endpoint '" .. endpoint.name .. "' schema field '" .. field_name .. "' must be a table"
    end
    if not field_schema.type then
      return false, "Endpoint '" .. endpoint.name .. "' schema field '" .. field_name .. "' missing 'type' definition"
    end
  end
  return true
end

---@param endpoint Endpoint
---@return boolean success
---@return string? error_message
function BB_DISPATCHER.register(endpoint)
  local valid, err = validate_endpoint_structure(endpoint)
  if not valid then
    return false, err
  end
  if BB_DISPATCHER.endpoints[endpoint.name] then
    return false, "Endpoint '" .. endpoint.name .. "' is already registered"
  end
  BB_DISPATCHER.endpoints[endpoint.name] = endpoint
  sendDebugMessage("Registered endpoint: " .. endpoint.name, "BB.DISPATCHER")
  return true
end

--- 加载并注册端点. 端点可以来自别的 mod (balatrobot 的手册查询), 所以路径按 mod_id 解析.
---@param endpoint_files string[]
---@param mod_id string? 端点文件所在的 mod, 默认 bbcore
---@return boolean success
---@return string? error_message
function BB_DISPATCHER.load_endpoints(endpoint_files, mod_id)
  mod_id = mod_id or "bbcore"
  local loaded_count = 0
  for _, filepath in ipairs(endpoint_files) do
    sendDebugMessage("Loading endpoint: " .. mod_id .. "/" .. filepath, "BB.DISPATCHER")
    local success, endpoint = pcall(function()
      return assert(SMODS.load_file(filepath, mod_id))()
    end)
    if not success then
      return false, "Failed to load endpoint '" .. filepath .. "': " .. tostring(endpoint)
    end
    local reg_success, reg_err = BB_DISPATCHER.register(endpoint)
    if not reg_success then
      return false, "Failed to register endpoint '" .. filepath .. "': " .. reg_err
    end
    loaded_count = loaded_count + 1
  end
  sendDebugMessage("Loaded " .. loaded_count .. " endpoint(s)", "BB.DISPATCHER")
  return true
end

--- 端点的结果都交给 Server.send_response. 本仓库里它是 bbcore 的 BB_TRANSPORT, 不是 HTTP 服务:
--- HTTP 服务 (balatrobot), 内置 loop 的本地调用与回放都从 BB_TRANSPORT 取结果, 见 runtime/transport.lua.
---@param server_module table
---@param endpoint_files string[]?
---@param mod_id string? 端点文件所在的 mod, 见 load_endpoints
---@return boolean success
function BB_DISPATCHER.init(server_module, endpoint_files, mod_id)
  BB_DISPATCHER.Server = server_module
  endpoint_files = endpoint_files or { "src/lua/endpoints/health.lua" }
  local success, err = BB_DISPATCHER.load_endpoints(endpoint_files, mod_id)
  if not success then
    sendErrorMessage("Dispatcher initialization failed: " .. err, "BB.DISPATCHER")
    return false
  end
  sendDebugMessage("Dispatcher initialized successfully", "BB.DISPATCHER")
  return true
end

---@param message string
---@param error_code string
function BB_DISPATCHER.send_error(message, error_code)
  if not BB_DISPATCHER.Server then
    sendDebugMessage("Cannot send error - Server not initialized", "BB.DISPATCHER")
    return
  end
  BB_DISPATCHER.Server.send_response({
    message = message,
    name = error_code,
  })
end

---@param request Request.Server
function BB_DISPATCHER.dispatch(request)
  -- Trigger render for this frame if render_on_api mode is enabled
  if BB_RENDER ~= nil then
    BB_RENDER = true
  end

  -- TIER 1: Protocol Validation (jsonrpc version checked in server.receive())
  if not request.method or type(request.method) ~= "string" then
    BB_DISPATCHER.send_error("Request missing 'method' field", BB_ERROR_NAMES.BAD_REQUEST)
    return
  end

  -- Handle rpc.discover (OpenRPC Service Discovery)
  if request.method == "rpc.discover" then
    if BB_DISPATCHER.Server and BB_DISPATCHER.Server.openrpc_spec then
      local json = require("json")
      local success, spec = pcall(json.decode, BB_DISPATCHER.Server.openrpc_spec)
      if success then
        BB_DISPATCHER.Server.send_response(spec)
      else
        BB_DISPATCHER.send_error("Failed to parse OpenRPC spec", BB_ERROR_NAMES.INTERNAL_ERROR)
      end
    else
      BB_DISPATCHER.send_error("OpenRPC spec not available", BB_ERROR_NAMES.INTERNAL_ERROR)
    end
    return
  end

  local params = request.params or {}
  local endpoint = BB_DISPATCHER.endpoints[request.method]
  if not endpoint then
    BB_DISPATCHER.send_error("Unknown method: " .. request.method, BB_ERROR_NAMES.BAD_REQUEST)
    return
  end

  -- Log incoming request with params
  local start_time = socket.gettime()
  sendDebugMessage(request.method .. BB_LOGGER.serialize_params(params), "BB.REQUEST")

  -- TIER 2: Schema Validation
  local valid, err_msg, err_code = Validator.validate(params, endpoint.schema)
  if not valid then
    sendWarnMessage(request.method .. ": " .. (err_msg or "Validation failed"), "BB.VALIDATION")
    BB_DISPATCHER.send_error(err_msg or "Validation failed", err_code or BB_ERROR_NAMES.BAD_REQUEST)
    return
  end

  -- TIER 3: Game State Validation
  local function state_check()
    if not endpoint.requires_state then
      return true
    end
    local current_state = G and G.STATE or "UNKNOWN"
    for _, required_state in ipairs(endpoint.requires_state) do
      if current_state == required_state then
        return true
      end
    end
    local state_names = {}
    for _, state in ipairs(endpoint.requires_state) do
      table.insert(state_names, get_state_name(state))
    end
    local current_state_name = get_state_name(current_state)
    local message = "Method '" .. request.method .. "' requires one of these states: " .. table.concat(state_names, ", ")
    sendWarnMessage(
      string.format("%s: requires %s, current=%s", request.method, table.concat(state_names, "|"), current_state_name),
      "BB.STATE"
    )
    return false, message
  end
  local state_ok, state_message = state_check()
  if not state_ok then
    BB_DISPATCHER.send_error(state_message, BB_ERROR_NAMES.INVALID_STATE)
    return
  end

  -- TIER 4: Execute Endpoint
  local function send_response(response)
    if BB_DISPATCHER.Server then
      -- Log response with timing
      local duration_ms = (socket.gettime() - start_time) * 1000
      local is_error = response.message ~= nil
      if is_error then
        sendDebugMessage(string.format("%s ERR (%.0fms)", request.method, duration_ms), "BB.RESPONSE")
      else
        sendDebugMessage(string.format("%s OK (%.0fms)", request.method, duration_ms), "BB.RESPONSE")
      end
      BB_DISPATCHER.Server.send_response(response)
    else
      sendDebugMessage("Cannot send response - Server not initialized", "BB.DISPATCHER")
    end
  end
  local function execute()
    -- 本仓库修改: 等讲解的这段时间里阶段可能变了, 执行前再查一次.
    local still_ok, still_message = state_check()
    if not still_ok then
      BB_DISPATCHER.send_error(still_message, BB_ERROR_NAMES.INVALID_STATE)
      return
    end
    local exec_success, exec_error = pcall(function()
      endpoint.execute(params, send_response)
    end)
    if not exec_success then
      sendErrorMessage(request.method .. ": " .. tostring(exec_error), "BB.EXEC")
      BB_DISPATCHER.send_error(tostring(exec_error), BB_ERROR_NAMES.INTERNAL_ERROR)
    end
  end

  -- 本仓库修改: 讲解还没退去时先挂起, 由 BB_DISPATCHER.update 在它退去后执行.
  local gate = (BB_TOAST and gated_method(request.method)) and BB_TOAST.gate_id() or nil
  if gate then
    deferred[#deferred + 1] = {
      method = request.method,
      gate = gate,
      at = socket.gettime(),
      run = execute,
    }
    sendDebugMessage(request.method .. ": waiting for agent commentary to clear", "BB.DISPATCHER")
    return
  end
  execute()
end

--- 每帧调用 (bbcore 的 love.update): 把讲解已经退去的请求按顺序执行掉.
function BB_DISPATCHER.update()
  while #deferred > 0 do
    local item = deferred[1]
    local ready = (not BB_TOAST) or BB_TOAST.gate_open(item.gate)
    if not ready and socket.gettime() - item.at < GATE_TIMEOUT then
      return -- 队首还在等: 后面的也一起等, 顺序不乱
    end
    table.remove(deferred, 1)
    if not ready then
      sendWarnMessage(
        string.format("%s: 等讲解退去超过 %d 秒, 直接执行", item.method, GATE_TIMEOUT),
        "BB.DISPATCHER"
      )
    end
    item.run()
  end
end
