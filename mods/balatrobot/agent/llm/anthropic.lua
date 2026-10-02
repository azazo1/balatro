--[[
Anthropic Messages 协议 (/v1/messages) 的纯逻辑部分, 不依赖游戏, 单测直接加载.

历史按 chat completions 的格式存放, 这里在发请求时转换, 收到的流式事件累积成同样格式的 assistant 消息.
接口与 chat.lua 一致: build_request(cfg, messages, tools, opts), accumulator().
依赖由调用方注入: M.Chat (chat.lua, 编码器与公共函数), M.decode (JSON 解码, 校验工具参数用).

思考 (cfg.thinking):
- "adaptive" (默认): thinking = {type = "adaptive", display = "summarized"}, 由模型决定想不想, 想多深.
  Opus 4.6 及以后的模型支持; display 写明 summarized, 否则 Opus 4.7 以后默认不返回思考文本.
- "budget": thinking = {type = "enabled", budget_tokens}, 预算按思考强度折算. 给只支持固定预算的
  Opus 4.5, Sonnet 4.5, Haiku 4.5 这类模型用; Opus 4.7 以后的模型会以 400 拒绝.
- "omit": 不写 thinking, 由服务端决定 (Opus 5 以后默认自适应但不返回思考文本, 更早的模型默认不思考).
思考强度 (cfg.reasoning_effort) 在 adaptive 与 omit 下写进 output_config.effort, 在 budget 下只用来折算预算.

回传: 收到的内容块 (含 thinking 的签名与 redacted_thinking) 原样存进 message.native.blocks.
带工具调用的那一轮必须把 thinking 块原样带回去, 否则 400. 中途换协议得到的历史没有 native,
按 content 与 tool_calls 重建, 没有签名的推理文本丢掉 (服务端不认).

缓存: 系统提示与最后一条消息的最后一块打 cache_control, 工具定义, 系统提示和此前的对话都能命中前缀缓存.
]]

local M = {}

M.VERSION = "2023-06-01"
-- max_tokens 是必填项, 思考也计在里面. Claude 4 以后的模型输出上限都不低于 32K.
M.MAX_TOKENS = 32000
-- 固定预算模式下, 思考强度对应的 budget_tokens. 要小于 MAX_TOKENS, 给正文留出余量.
M.BUDGETS = { low = 4000, medium = 10000, high = 16000, xhigh = 24000, max = 24000 }
M.DEFAULT_BUDGET = 10000

---@type table chat.lua, 由调用方注入
M.Chat = nil
---@type fun(s: string): any JSON 解码, 由调用方注入
M.decode = nil

local EMPTY_TEXT = "(空)"

local function nonempty(s)
  if type(s) == "string" and s:find("%S") then
    return s
  end
  return EMPTY_TEXT
end

--- tool_use 的 id 只允许字母, 数字, "_" 和 "-". 别的协议生成的 id (如 "functions.play:0") 换掉非法字符,
--- tool_use 与 tool_result 两边用同一个函数, 仍然对得上.
local function tool_id(id)
  local s = tostring(id or "")
  if s == "" then
    return "toolu_bb"
  end
  return (s:gsub("[^%w_%-]", "_"))
end

--- 工具参数 (JSON 文本) 原样写出, 不是合法的 JSON 对象时换成 {}.
local function input_of(args)
  return M.Chat.raw(M.Chat.object_json(args, M.decode))
end

--- 没有 native 的 assistant 消息按 content 与 tool_calls 重建内容块.
---@param m table
---@return table[]
local function rebuild_assistant(m)
  local blocks = {}
  if type(m.content) == "string" and m.content:find("%S") then
    blocks[#blocks + 1] = { type = "text", text = m.content }
  end
  for _, call in ipairs(m.tool_calls or {}) do
    local fn = call["function"] or {}
    blocks[#blocks + 1] = {
      type = "tool_use",
      id = tool_id(call.id),
      name = tostring(fn.name or ""),
      input = input_of(fn.arguments),
    }
  end
  return blocks
end

--- assistant 消息的内容块: 同协议的原样回传, 否则重建. 只有思考没有正文和调用时视为空.
---@param m table
---@return table[]
local function assistant_blocks(m)
  local native = m.native
  local blocks
  if type(native) == "table" and native.format == "anthropic" and type(native.blocks) == "table" then
    blocks = native.blocks
  else
    blocks = rebuild_assistant(m)
  end
  for _, b in ipairs(blocks) do
    if b.type ~= "thinking" and b.type ~= "redacted_thinking" then
      return blocks
    end
  end
  return {}
end

--- chat 格式的历史转成 system 与 messages. 相邻同角色的消息并成一条 (tool 结果和后面的状态都是 user).
---@param messages table[]
---@return string system
---@return table[] out
function M.convert(messages)
  local system = {}
  local out = {}
  local function push(role, blocks)
    if #blocks == 0 then
      return
    end
    local last = out[#out]
    if last and last.role == role then
      for _, b in ipairs(blocks) do
        last.content[#last.content + 1] = b
      end
    else
      local content = {}
      for i, b in ipairs(blocks) do
        content[i] = b
      end
      out[#out + 1] = { role = role, content = content }
    end
  end
  for _, m in ipairs(messages) do
    local role = m.role
    if role == "system" then
      if type(m.content) == "string" and m.content ~= "" then
        system[#system + 1] = m.content
      end
    elseif role == "user" then
      push("user", { { type = "text", text = nonempty(m.content) } })
    elseif role == "tool" then
      push("user", {
        { type = "tool_result", tool_use_id = tool_id(m.tool_call_id), content = nonempty(m.content) },
      })
    elseif role == "assistant" then
      push("assistant", assistant_blocks(m))
    end
  end
  return table.concat(system, "\n\n"), out
end

--- OpenAI 格式的工具定义转成 Anthropic 的 {name, description, input_schema}.
---@param tools table[]?
---@return table[]?
local function convert_tools(tools)
  if type(tools) ~= "table" or #tools == 0 then
    return nil
  end
  local out = {}
  for _, t in ipairs(tools) do
    local fn = t["function"] or t
    out[#out + 1] = {
      name = fn.name,
      description = fn.description,
      input_schema = fn.parameters or M.Chat.object({ type = "object" }),
    }
  end
  return out
end

--- chat 风格的 tool_choice 转成 Anthropic 的对象.
local function convert_tool_choice(choice)
  if choice == "auto" then
    return { type = "auto" }
  elseif choice == "required" then
    return { type = "any" }
  elseif choice == "none" then
    return { type = "none" }
  elseif type(choice) == "table" and type(choice["function"]) == "table" then
    return { type = "tool", name = choice["function"].name }
  end
  return nil
end

--- 给最后一条 user 消息的最后一块打缓存断点. 复制那一块, 不改历史里的表.
---@param out table[]
local function mark_cache(out)
  local last = out[#out]
  if not last or last.role ~= "user" then
    return
  end
  local n = #last.content
  local block = last.content[n]
  if not block then
    return
  end
  local copy = {}
  for k, v in pairs(block) do
    copy[k] = v
  end
  copy.cache_control = { type = "ephemeral" }
  last.content[n] = copy
end

--- 生成一次 Messages 请求. 参数与返回值同 chat.build_request.
---@param cfg BBLlmConfig
---@param messages table[]
---@param tools table[]?
---@param opts BBLlmRequestOpts?
---@return string? url
---@return table|string headers
---@return string? body
function M.build_request(cfg, messages, tools, opts)
  local Chat = M.Chat
  opts = opts or {}
  local model, err = Chat.check_request(cfg, messages)
  if not model then
    return nil, err
  end
  local url
  url, err = Chat.join_url(cfg.endpoint, "/messages", "/v1")
  if not url then
    return nil, err
  end
  local stream = opts.stream ~= false
  local headers = Chat.headers(cfg, stream)
  headers["anthropic-version"] = M.VERSION

  local system, converted = M.convert(messages)
  if #converted == 0 then
    return nil, "消息列表为空"
  end
  mark_cache(converted)

  local body = {
    model = model,
    messages = converted,
    max_tokens = opts.max_tokens or M.MAX_TOKENS,
    stream = stream,
  }
  if system ~= "" then
    body.system = { { type = "text", text = system, cache_control = { type = "ephemeral" } } }
  end
  body.tools = convert_tools(tools)
  if body.tools and opts.tool_choice ~= nil then
    body.tool_choice = convert_tool_choice(opts.tool_choice)
  end

  local effort = Chat.effort(cfg)
  local mode = cfg.thinking
  if mode == "budget" then
    local budget = effort and M.BUDGETS[effort] or M.DEFAULT_BUDGET
    body.thinking = { type = "enabled", budget_tokens = budget, display = "summarized" }
  else
    if mode ~= "omit" then
      body.thinking = { type = "adaptive", display = "summarized" }
    end
    if effort then
      body.output_config = { effort = effort }
    end
  end
  -- 思考开着时 temperature 不能改, 新模型上任何时候都不能改; 所以不发 opts.temperature.

  local encoded
  encoded, err = Chat.encode_body(body)
  if not encoded then
    return nil, err
  end
  return url, headers, encoded
end

-------------------------------------------------------------------------------
-- 流式累积
-------------------------------------------------------------------------------

---@class BBAnthropicAccumulator
local Acc = {}
Acc.__index = Acc

---@return BBAnthropicAccumulator
function M.accumulator()
  return setmetatable({
    slots = {}, -- 按出现顺序的内容块
    by_index = {},
    reasoning_parts = {},
    content_parts = {},
    calls = 0,
    usage_raw = nil,
    error = nil,
    finish_reason = nil,
    done = false,
    terminal = false, -- 收到 message_stop, 不必等连接关闭
    emitted = false,
  }, Acc)
end

function Acc:merge_usage(u)
  if type(u) ~= "table" then
    return
  end
  self.usage_raw = self.usage_raw or {}
  for k, v in pairs(u) do
    if type(v) == "number" then
      self.usage_raw[k] = v
    end
  end
end

local STOP_REASONS = {
  tool_use = "tool_calls",
  end_turn = "stop",
  stop_sequence = "stop",
  max_tokens = "length",
  model_context_window_exceeded = "length",
  pause_turn = "stop",
  refusal = "content_filter",
}

function Acc:start_block(index, block, out)
  local slot = { type = block.type, text = {}, thinking = {}, json = {} }
  self.slots[#self.slots + 1] = slot
  if index then
    self.by_index[index] = slot
  end
  if block.type == "thinking" then
    -- 多段思考 (工具调用之间) 之间空一行.
    if #self.reasoning_parts > 0 then
      self.reasoning_parts[#self.reasoning_parts + 1] = "\n\n"
      out[#out + 1] = { kind = "reasoning", text = "\n\n" }
    end
    slot.signature = block.signature
    if type(block.thinking) == "string" and block.thinking ~= "" then
      self:add_thinking(slot, block.thinking, out)
    end
  elseif block.type == "redacted_thinking" then
    slot.data = block.data
  elseif block.type == "text" then
    if type(block.text) == "string" and block.text ~= "" then
      self:add_text(slot, block.text, out)
    end
  elseif block.type == "tool_use" then
    slot.id, slot.name = block.id, block.name
    self.calls = self.calls + 1
    -- 流式时 input 是 {}, 参数在 input_json_delta 里; 非流式时是完整对象.
    if type(block.input) == "table" and next(block.input) ~= nil then
      slot.json[1] = M.Chat.encode(block.input)
    end
  end
  return slot
end

function Acc:add_thinking(slot, text, out)
  slot.thinking[#slot.thinking + 1] = text
  self.reasoning_parts[#self.reasoning_parts + 1] = text
  out[#out + 1] = { kind = "reasoning", text = text }
end

function Acc:add_text(slot, text, out)
  slot.text[#slot.text + 1] = text
  self.content_parts[#self.content_parts + 1] = text
  out[#out + 1] = { kind = "content", text = text }
end

--- 喂入一个已解码的事件 (或非流式的完整响应). 返回要显示的增量.
---@param chunk table
---@return BBLlmDelta[]
function Acc:feed(chunk)
  local out = {}
  if type(chunk) ~= "table" then
    return out
  end
  local t = chunk.type
  if t == "error" or (t == nil and chunk.error ~= nil) then
    self.error = chunk.error or chunk
    return out
  end
  if t == "message_start" then
    local msg = chunk.message or {}
    self:merge_usage(msg.usage)
  elseif t == "content_block_start" then
    self:start_block(tonumber(chunk.index), chunk.content_block or {}, out)
  elseif t == "content_block_delta" then
    local slot = self.by_index[tonumber(chunk.index)]
    local d = chunk.delta or {}
    if slot then
      if d.type == "text_delta" and type(d.text) == "string" and d.text ~= "" then
        self:add_text(slot, d.text, out)
      elseif d.type == "thinking_delta" and type(d.thinking) == "string" and d.thinking ~= "" then
        self:add_thinking(slot, d.thinking, out)
      elseif d.type == "signature_delta" and type(d.signature) == "string" then
        slot.signature = (slot.signature or "") .. d.signature
      elseif d.type == "input_json_delta" and type(d.partial_json) == "string" then
        slot.json[#slot.json + 1] = d.partial_json
      end
    end
  elseif t == "message_delta" then
    self:merge_usage(chunk.usage)
    local reason = chunk.delta and chunk.delta.stop_reason
    if type(reason) == "string" then
      self.finish_reason = STOP_REASONS[reason] or reason
      self.done = true
    end
  elseif t == "message_stop" then
    self.done = true
    self.terminal = true
  elseif t == "message" then
    -- 非流式响应 (服务端忽略了 stream=true).
    self:merge_usage(chunk.usage)
    for i, block in ipairs(chunk.content or {}) do
      self:start_block(i, block, out)
    end
    if type(chunk.stop_reason) == "string" then
      self.finish_reason = STOP_REASONS[chunk.stop_reason] or chunk.stop_reason
    end
    self.done = true
  end
  if #out > 0 then
    self.emitted = true
  end
  return out
end

function Acc:mark_done()
  self.done = true
end

function Acc:has_output()
  return self.emitted or self.calls > 0
end

function Acc:tool_call_count()
  return self.calls
end

--- 组装 assistant 消息 (chat 格式, 附带 native 原样回传) 与规范化后的 usage.
---@return table message
---@return table? usage
function Acc:finish()
  local Chat = M.Chat
  local blocks, calls = {}, {}
  for _, s in ipairs(self.slots) do
    if s.type == "thinking" then
      -- 没有签名的思考块回传会被拒, 不留.
      if type(s.signature) == "string" and s.signature ~= "" then
        blocks[#blocks + 1] = { type = "thinking", thinking = table.concat(s.thinking), signature = s.signature }
      end
    elseif s.type == "redacted_thinking" then
      blocks[#blocks + 1] = { type = "redacted_thinking", data = s.data }
    elseif s.type == "text" then
      local text = table.concat(s.text)
      if text ~= "" then
        blocks[#blocks + 1] = { type = "text", text = text }
      end
    elseif s.type == "tool_use" then
      local args = Chat.object_json(table.concat(s.json), M.decode)
      blocks[#blocks + 1] = { type = "tool_use", id = s.id, name = s.name, input = Chat.raw(args) }
      calls[#calls + 1] = { id = s.id, type = "function", ["function"] = { name = tostring(s.name or ""), arguments = args } }
    end
  end

  local content = table.concat(self.content_parts)
  local reasoning = table.concat(self.reasoning_parts):gsub("^%s+", "")
  local message = { role = "assistant", native = { format = "anthropic", blocks = blocks } }
  if content ~= "" then
    message.content = content
  elseif #calls > 0 then
    message.content = Chat.NULL
  else
    message.content = ""
  end
  if reasoning ~= "" then
    message.reasoning_content = reasoning
  end
  if #calls > 0 then
    message.tool_calls = calls
  end
  return message, Chat.normalize_usage(self.usage_raw)
end

return M
