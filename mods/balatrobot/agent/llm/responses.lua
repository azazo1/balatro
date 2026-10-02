--[[
OpenAI Responses 协议 (/v1/responses) 的纯逻辑部分, 不依赖游戏, 单测直接加载.

历史按 chat completions 的格式存放, 这里在发请求时转换, 收到的流式事件累积成同样格式的 assistant 消息.
接口与 chat.lua 一致: build_request(cfg, messages, tools, opts), accumulator().
依赖由调用方注入: M.Chat (chat.lua).

- 无状态: store = false, 每次带上完整历史, 不依赖 previous_response_id (服务端不留对话, 换 key 或网关也能续).
- 推理: 设置了思考强度时写 reasoning = {effort, summary = "auto"}, 并要回加密推理 (include
  reasoning.encrypted_content). 推理摘要显示在流式条上; 没设思考强度时不写这两项, 免得不支持推理的模型报错.
- 回传: 输出项按顺序存进 message.native.items. 推理项只留带 encrypted_content 的 (store = false 时
  没有它的推理项回传会被拒), 消息与调用项去掉 id 与 status. 推理项后面必须紧跟它原来的下一项, 所以按原顺序存.
]]

local M = {}

---@type table chat.lua, 由调用方注入
M.Chat = nil

--- 输出项整理成可回传的形式, 不能回传的返回 nil.
---@param item table
---@return table?
local function sanitize(item)
  local t = item.type
  if t == "reasoning" then
    if type(item.encrypted_content) ~= "string" or item.encrypted_content == "" then
      return nil
    end
    local summary = {}
    for _, s in ipairs(item.summary or {}) do
      if type(s) == "table" and type(s.text) == "string" then
        summary[#summary + 1] = { type = "summary_text", text = s.text }
      end
    end
    return { type = "reasoning", id = item.id, summary = summary, encrypted_content = item.encrypted_content }
  elseif t == "message" then
    local parts = {}
    for _, c in ipairs(item.content or {}) do
      if type(c) == "table" and c.type == "output_text" and type(c.text) == "string" then
        parts[#parts + 1] = { type = "output_text", text = c.text }
      end
    end
    if #parts == 0 then
      return nil
    end
    return { type = "message", role = "assistant", content = parts }
  elseif t == "function_call" then
    return {
      type = "function_call",
      call_id = item.call_id,
      name = item.name,
      arguments = M.Chat.object_json(item.arguments),
    }
  end
  return nil
end

--- chat 格式的历史转成 instructions 与 input.
---@param messages table[]
---@return string instructions
---@return table[] input
function M.convert(messages)
  local system, input = {}, {}
  for _, m in ipairs(messages) do
    local role = m.role
    if role == "system" then
      if type(m.content) == "string" and m.content ~= "" then
        system[#system + 1] = m.content
      end
    elseif role == "user" then
      input[#input + 1] = { role = "user", content = tostring(m.content or "") }
    elseif role == "tool" then
      input[#input + 1] = {
        type = "function_call_output",
        call_id = tostring(m.tool_call_id or ""),
        output = tostring(m.content or ""),
      }
    elseif role == "assistant" then
      local native = m.native
      if type(native) == "table" and native.format == "responses" and type(native.items) == "table" then
        for _, item in ipairs(native.items) do
          input[#input + 1] = item
        end
      else
        if type(m.content) == "string" and m.content:find("%S") then
          input[#input + 1] = { role = "assistant", content = m.content }
        end
        for _, call in ipairs(m.tool_calls or {}) do
          local fn = call["function"] or {}
          input[#input + 1] = {
            type = "function_call",
            call_id = tostring(call.id or ""),
            name = tostring(fn.name or ""),
            arguments = M.Chat.object_json(fn.arguments),
          }
        end
      end
    end
  end
  return table.concat(system, "\n\n"), input
end

--- OpenAI chat 格式的工具定义转成 Responses 的扁平格式. strict 关掉: 默认的严格模式要求 schema
--- 每个属性都必填并带 additionalProperties = false, 现有的工具定义不满足.
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
      type = "function",
      name = fn.name,
      description = fn.description,
      parameters = fn.parameters or M.Chat.object({ type = "object" }),
      strict = false,
    }
  end
  return out
end

local function convert_tool_choice(choice)
  if type(choice) == "string" then
    return choice
  elseif type(choice) == "table" and type(choice["function"]) == "table" then
    return { type = "function", name = choice["function"].name }
  end
  return nil
end

--- 生成一次 Responses 请求. 参数与返回值同 chat.build_request.
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
  url, err = Chat.join_url(cfg.endpoint, "/responses")
  if not url then
    return nil, err
  end
  local stream = opts.stream ~= false
  local headers = Chat.headers(cfg, stream)

  local instructions, input = M.convert(messages)
  if #input == 0 then
    return nil, "消息列表为空"
  end
  local body = {
    model = model,
    input = input,
    stream = stream,
    store = false,
  }
  if instructions ~= "" then
    body.instructions = instructions
  end
  body.tools = convert_tools(tools)
  if body.tools and opts.tool_choice ~= nil then
    body.tool_choice = convert_tool_choice(opts.tool_choice)
  end
  local effort = Chat.effort(cfg)
  if effort then
    body.reasoning = { effort = effort, summary = "auto" }
    body.include = { "reasoning.encrypted_content" }
  end
  if opts.max_tokens then
    body.max_output_tokens = opts.max_tokens
  end
  if opts.temperature then
    body.temperature = opts.temperature
  end

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

---@class BBResponsesAccumulator
local Acc = {}
Acc.__index = Acc

---@return BBResponsesAccumulator
function M.accumulator()
  return setmetatable({
    slots = {}, -- 按 output_index 出现顺序
    by_index = {},
    reasoning_parts = {},
    content_parts = {},
    summary_key = nil, -- 当前推理摘要段, 换段时空一行
    calls = 0,
    output = nil, -- response.completed 里的完整输出, 有它时以它为准
    usage_raw = nil,
    error = nil,
    finish_reason = nil,
    done = false,
    terminal = false,
    emitted = false,
  }, Acc)
end

function Acc:slot(index, item)
  local slot = index and self.by_index[index]
  if not slot then
    slot = { item = item or {}, args = {} }
    self.slots[#self.slots + 1] = slot
    if index then
      self.by_index[index] = slot
    end
    if item and item.type == "function_call" then
      self.calls = self.calls + 1
    end
  elseif item then
    slot.item = item
  end
  return slot
end

function Acc:add_reasoning(key, text, out)
  if self.summary_key ~= nil and self.summary_key ~= key and #self.reasoning_parts > 0 then
    self.reasoning_parts[#self.reasoning_parts + 1] = "\n\n"
    out[#out + 1] = { kind = "reasoning", text = "\n\n" }
  end
  self.summary_key = key
  self.reasoning_parts[#self.reasoning_parts + 1] = text
  out[#out + 1] = { kind = "reasoning", text = text }
end

function Acc:add_content(text, out)
  self.content_parts[#self.content_parts + 1] = text
  out[#out + 1] = { kind = "content", text = text }
end

--- 完整响应 (response.completed, 或非流式) 的收尾: 记下输出, usage 与结束原因.
function Acc:take_response(resp, out, replay)
  if type(resp) ~= "table" then
    return
  end
  if type(resp.usage) == "table" then
    self.usage_raw = resp.usage
  end
  if type(resp.output) == "table" and #resp.output > 0 then
    self.output = resp.output
    if replay then
      -- 非流式: 没有增量事件, 从完整输出里取要显示的文字.
      for i, item in ipairs(resp.output) do
        local slot = self:slot(i, item)
        if item.type == "reasoning" then
          for j, s in ipairs(item.summary or {}) do
            if type(s.text) == "string" and s.text ~= "" then
              self:add_reasoning(i .. ":" .. j, s.text, out)
            end
          end
        elseif item.type == "message" then
          for _, c in ipairs(item.content or {}) do
            if c.type == "output_text" and type(c.text) == "string" and c.text ~= "" then
              self:add_content(c.text, out)
            end
          end
        end
        slot.item = item
      end
    end
  end
  if resp.status == "incomplete" then
    self.finish_reason = "length"
  end
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
  if t == "error" then
    self.error = chunk.error or chunk
    return out
  end
  if t == "response.failed" then
    local resp = chunk.response or {}
    self.error = resp.error or { message = "response failed" }
    return out
  end
  if t == nil and chunk.error ~= nil and chunk.object ~= "response" then
    self.error = chunk.error
    return out
  end
  if t == "response.output_item.added" then
    self:slot(tonumber(chunk.output_index), chunk.item)
  elseif t == "response.output_item.done" then
    self:slot(tonumber(chunk.output_index), chunk.item)
  elseif t == "response.reasoning_summary_text.delta" or t == "response.reasoning_text.delta" then
    if type(chunk.delta) == "string" and chunk.delta ~= "" then
      local key = tostring(chunk.output_index) .. ":" .. tostring(chunk.summary_index or chunk.content_index)
      self:add_reasoning(key, chunk.delta, out)
    end
  elseif t == "response.output_text.delta" then
    if type(chunk.delta) == "string" and chunk.delta ~= "" then
      self:add_content(chunk.delta, out)
    end
  elseif t == "response.function_call_arguments.delta" then
    local slot = self:slot(tonumber(chunk.output_index))
    if type(chunk.delta) == "string" then
      slot.args[#slot.args + 1] = chunk.delta
    end
  elseif t == "response.completed" or t == "response.incomplete" then
    self:take_response(chunk.response, out, false)
    self.finish_reason = self.finish_reason or (t == "response.incomplete" and "length" or nil)
    self.done = true
    self.terminal = true
  elseif t == nil and chunk.object == "response" then
    if chunk.status == "failed" then
      self.error = chunk.error or { message = "response failed" }
      return out
    end
    self:take_response(chunk, out, true)
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
  local items = {}
  if self.output then
    for i, item in ipairs(self.output) do
      items[i] = item
    end
  else
    for _, s in ipairs(self.slots) do
      local item = s.item or {}
      if item.type == "function_call" and (item.arguments == nil or item.arguments == "") then
        local copy = {}
        for k, v in pairs(item) do
          copy[k] = v
        end
        copy.arguments = table.concat(s.args)
        item = copy
      end
      items[#items + 1] = item
    end
  end

  local native, calls, texts = {}, {}, {}
  for _, item in ipairs(items) do
    if type(item) == "table" then
      local clean = sanitize(item)
      if clean then
        native[#native + 1] = clean
      end
      if item.type == "function_call" then
        calls[#calls + 1] = {
          id = tostring(item.call_id or item.id or ""),
          type = "function",
          ["function"] = { name = tostring(item.name or ""), arguments = Chat.object_json(item.arguments) },
        }
      elseif item.type == "message" then
        for _, c in ipairs(item.content or {}) do
          if type(c) == "table" and c.type == "output_text" and type(c.text) == "string" then
            texts[#texts + 1] = c.text
          end
        end
      end
    end
  end

  -- 正文以完整输出为准; 没有完整输出 (流被截断后靠 done 收尾) 时用累积的增量.
  local content = #texts > 0 and table.concat(texts) or table.concat(self.content_parts)
  local reasoning = table.concat(self.reasoning_parts)
  local message = { role = "assistant", native = { format = "responses", items = native } }
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
    self.finish_reason = self.finish_reason or "tool_calls"
  end
  self.finish_reason = self.finish_reason or "stop"
  return message, Chat.normalize_usage(self.usage_raw)
end

return M
