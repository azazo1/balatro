-- 内置 agent 的 LLM 协议层单元测试, 用 luajit 在仓库根目录运行: just test-agent
package.path = "mods/Steamodded/libs/json/?.lua;" .. package.path
local json = require("json")
local Sse = dofile("mods/balatrobot/agent/llm/sse.lua")
local Chat = dofile("mods/balatrobot/agent/llm/chat.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function delta_chunk(delta, finish)
  return { choices = { { index = 0, delta = delta, finish_reason = finish } } }
end

do -- SSE: 分割, 多行 data, 注释, [DONE]
  check("单行 data", Sse.parse('data: {"a":1}') == '{"a":1}')
  check("多行 data 用换行拼接", Sse.parse("event: x\r\ndata: a\ndata:b") == "a\nb")
  check("只有注释时没有 data", Sse.parse(": keep-alive") == nil)
  check("识别 [DONE]", Sse.is_done(Sse.parse("data: [DONE]")) and not Sse.is_done('{"a":"[DONE]"}'))
  local events, rest = Sse.split("data: 1\r\n\r\ndata: 2\n\n\n\ndata: 3")
  check("按 \\n\\n 与 \\r\\n\\r\\n 分割", #events == 2 and events[1] == "data: 1" and events[2] == "data: 2",
    json.encode(events))
  check("未结束的事件留在剩余文本", rest == "data: 3")
end

do -- tool call: 多个 index 交错, id 只出现一次, arguments 分多段
  local acc = Chat.accumulator()
  local function tc(list)
    acc:feed(delta_chunk({ tool_calls = list }))
  end
  tc({ { index = 0, id = "call_a", type = "function", ["function"] = { name = "pl", arguments = "" } } })
  tc({ { index = 1, id = "call_b", ["function"] = { name = "notify", arguments = '{"te' } } })
  tc({ { index = 0, ["function"] = { name = "ay", arguments = '{"cards":' } } })
  tc({ { index = 1, ["function"] = { arguments = 'xt":"hi"}' } }, { index = 0, ["function"] = { arguments = "[0,1]}" } } })
  acc:feed(delta_chunk({}, "tool_calls"))
  local msg = acc:finish()
  local calls = msg.tool_calls or {}
  check("两个调用按 index 排列", #calls == 2 and calls[1].id == "call_a" and calls[2].id == "call_b")
  check("name 分段拼接", calls[1]["function"].name == "play" and calls[2]["function"].name == "notify")
  check("arguments 分段拼接", calls[1]["function"].arguments == '{"cards":[0,1]}'
    and calls[2]["function"].arguments == '{"text":"hi"}')
  check("finish_reason 表示结束", acc.done and acc.finish_reason == "tool_calls")

  -- 部分实现把所有调用报成同一个 index, 靠新的 id 区分.
  local same = Chat.accumulator()
  same:feed(delta_chunk({ tool_calls = { { index = 0, id = "x", ["function"] = { name = "a", arguments = "{}" } } } }))
  same:feed(delta_chunk({ tool_calls = { { index = 0, id = "y", ["function"] = { name = "b", arguments = "{}" } } } }))
  check("同 index 不同 id 视为两个调用", #(same:finish().tool_calls or {}) == 2)
end

do -- 推理字段三种来源, 以及只有工具调用时 content 为 null
  local function reasoning_of(delta)
    local acc = Chat.accumulator()
    local out = acc:feed(delta_chunk(delta))
    return out[1] and out[1].kind == "reasoning" and out[1].text or nil
  end
  check("reasoning_content", reasoning_of({ reasoning_content = "r1", reasoning = "no" }) == "r1")
  check("reasoning", reasoning_of({ reasoning = "r2" }) == "r2")
  check("reasoning_details[].text 与 .content", reasoning_of({
    reasoning_details = { { type = "reasoning.text", text = "a" }, { type = "reasoning.encrypted", data = "zz" }, { content = "b" } },
  }) == "ab")

  local acc = Chat.accumulator()
  acc:feed(delta_chunk({ reasoning_content = "想" }))
  acc:feed(delta_chunk({ reasoning_content = "一想" }))
  acc:feed(delta_chunk({ tool_calls = { { index = 0, id = "c1", ["function"] = { name = "play", arguments = "{}" } } } }, "tool_calls"))
  local msg = acc:finish()
  local decoded = json.decode(Chat.encode(msg))
  local raw = Chat.encode(msg)
  check("只有工具调用时 content 为 null", raw:find('"content":null', 1, true) ~= nil, raw)
  check("reasoning_content 与 tool_calls 在同一条消息", decoded.reasoning_content == "想一想" and #decoded.tool_calls == 1)

  local text = Chat.accumulator()
  local out = text:feed(delta_chunk({ content = "好" }))
  check("正文增量", out[1] and out[1].kind == "content" and text:finish().content == "好")
  local err = Chat.accumulator()
  err:feed({ error = { message = "boom", code = "server_is_overloaded" } })
  check("data 里的 error 视为失败", err.error ~= nil)
end

do -- 请求: endpoint 规则, stream_options, 空 schema 编码为对象, 鉴权头
  check("base 补 /chat/completions", Chat.resolve_url("https://api.deepseek.com/v1/") == "https://api.deepseek.com/v1/chat/completions")
  check("完整地址原样使用", Chat.resolve_url("http://127.0.0.1:11434/v1/chat/completions") == "http://127.0.0.1:11434/v1/chat/completions")
  check("保留查询串", Chat.resolve_url("https://x.test/openai?api-version=1") == "https://x.test/openai/chat/completions?api-version=1")
  check("拒绝非 http 地址", Chat.resolve_url("api.deepseek.com") == nil)

  local tools = { { type = "function", ["function"] = { name = "menu", parameters = { type = "object", properties = {} } } } }
  local url, headers, body = Chat.build_request(
    { endpoint = "https://api.test/v1", model = "m", api_key = " k ", auth = "x-api-key" },
    { { role = "user", content = "hi" } }, tools)
  local b = json.decode(body)
  check("请求地址", url == "https://api.test/v1/chat/completions")
  check("x-api-key 鉴权", headers["x-api-key"] == "k" and headers.Authorization == nil)
  check("流式并请求 usage", b.stream == true and b.stream_options.include_usage == true)
  check("空 properties 编码为对象", body:find('"properties":{}', 1, true) ~= nil, body)
  local _, bearer = Chat.build_request({ endpoint = "https://api.test/v1", model = "m", api_key = "k" }, { { role = "user", content = "hi" } })
  check("默认 Bearer", bearer.Authorization == "Bearer k")
end

do -- 请求体兜底: 内容里有非法 UTF-8 时换成替换字符, 不让服务端拒掉整个请求
  local Text = dofile("mods/balatrobot/agent/text.lua")
  local broken = "正常的字" .. string.char(0xE6) .. "后面还有"
  local cfg = { endpoint = "https://api.test/v1", model = "m" }
  -- 没注入 text 模块时按原样编码 (单独加载本模块的用法)
  Chat.text = nil
  local _, _, raw = Chat.build_request(cfg, { { role = "user", content = broken } })
  check("没注入时不做修复", not Text.valid_utf8(raw))
  Chat.text = Text
  local _, _, body = Chat.build_request(cfg, { { role = "user", content = broken } })
  check("注入后请求体是合法 UTF-8", Text.valid_utf8(body) == true)
  check("前后正常内容都保留", body:find("正常的字", 1, true) ~= nil and body:find("后面还有", 1, true) ~= nil)
  local ok, decoded = pcall(json.decode, body)
  check(
    "修完仍能解析, 坏字节变成替换字符",
    ok and decoded.messages[1].content == "正常的字\239\191\189后面还有",
    ok and decoded.messages[1].content or nil
  )
  Chat.text = nil
end

do -- usage 规范化
  local u = Chat.normalize_usage({ prompt_tokens = 100, completion_tokens = 20, prompt_tokens_details = { cached_tokens = 30 },
    completion_tokens_details = { reasoning_tokens = 7 } })
  check("OpenAI usage", u.prompt_tokens == 100 and u.completion_tokens == 20 and u.cached == 30 and u.reasoning_tokens == 7
    and u.total_tokens == 120)
  check("DeepSeek 缓存命中", Chat.normalize_usage({ prompt_tokens = 10, prompt_cache_hit_tokens = 8 }).cached == 8)
end

do -- 错误分类
  local function action(...)
    return (Chat.classify(...))
  end
  check("429 重试", action(429, "slow down") == "retry")
  check("5xx 重试", action(502, nil) == "retry" and action(503, {}) == "retry")
  check("超时与连接断开重试", action(nil, nil, "timeout") == "retry" and action(0, nil, "connection reset") == "retry")
  check("取消不重试也不算错误", action(nil, nil, "cancelled") == "cancel")
  check("过载错误码重试", action(200, { error = { code = "server_is_overloaded" } }) == "retry"
    and action(200, { code = "slow_down" }) == "retry")
  check("401/403 不重试", action(401, nil) == "fatal" and action(403, nil) == "fatal")
  check("429 的额度用尽不重试", action(429, { error = { type = "insufficient_quota", message = "quota" } }) == "fatal")
  check("上下文超长不重试", action(400, { error = { code = "context_length_exceeded" } }) == "fatal"
    and action(400, "This model's maximum context length is 8192 tokens") == "fatal")
  check("其余 4xx 不重试", action(400, { error = { message = "bad" } }) == "fatal" and action(422, nil) == "fatal")
  check("流中带数字码的 error 按数字码判断", action(200, { error = { code = 502, message = "upstream" } }) == "retry")
end

do -- 退避
  local seq = {}
  for i = 1, 6 do
    seq[i] = Chat.backoff(i)
  end
  check("退避 2, 4, 8, 16, 30", table.concat(seq, ",") == "2,4,8,16,30,30", table.concat(seq, ","))
  check("最多 5 次", Chat.MAX_RETRIES == 5)
  check("Retry-After 取较大者", Chat.backoff(1, Chat.retry_after("Content-Type: x\nretry-after: 7\n")) == 7)
end

do -- client: 流在中途断开时清空并整个重发, 重发成功后完成
  local clock = 0
  local scripts = {
    { { kind = "status", status = 200, text = "Content-Type: text/event-stream\n" },
      { kind = "event", text = 'data: {"choices":[{"index":0,"delta":{"reasoning_content":"半截"}}]}' },
      { kind = "error", text = "connection reset" } },
    { { kind = "status", status = 200, text = "" },
      { kind = "event", text = 'data: {"choices":[{"index":0,"delta":{"content":"好"},"finish_reason":"stop"}]}' },
      { kind = "event", text = 'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":1}}' },
      { kind = "event", text = "data: [DONE]" },
      { kind = "done" } },
  }
  local sent = 0
  local fake = {
    set_logger = function() end,
    set_sse = function() end,
    load = function() return true end,
    available = function() return true end,
    backend = function() return "bbnet" end,
    info = function() end,
    request = function()
      sent = sent + 1
      local items = scripts[sent]
      return { poll = function() local out = items; items = {}; return out end, close = function() end }
    end,
  }
  local Client = dofile("mods/balatrobot/agent/llm/client.lua")
  -- text 也注入: client.init 会把它接到请求体编码上 (没有 SMODS 时它没法自己加载)
  Client.init({
    bbnet = fake,
    chat = Chat,
    anthropic = dofile("mods/balatrobot/agent/llm/anthropic.lua"),
    responses = dofile("mods/balatrobot/agent/llm/responses.lua"),
    sse = Sse,
    text = dofile("mods/balatrobot/agent/text.lua"),
    json = json,
    log = function() end,
    now = function() return clock end,
  })
  local ev = {}
  local req = Client.start({ endpoint = "http://127.0.0.1:1/v1", model = "m" }, { { role = "user", content = "hi" } }, nil, {
    on_delta = function(kind, text) ev[#ev + 1] = kind .. ":" .. text end,
    on_reset = function() ev[#ev + 1] = "reset" end,
    on_retry = function(n, max, _, wait) ev[#ev + 1] = string.format("retry %d/%d %d", n, max, wait) end,
    on_done = function(msg, usage) ev[#ev + 1] = "done:" .. tostring(msg.content) .. ":" .. usage.prompt_tokens end,
    on_error = function(reason) ev[#ev + 1] = "error:" .. reason end,
  })
  req:update()
  check("断开后进入等待", req.state == "waiting" and req:retry_remaining() == 2, req.state)
  clock = 1
  req:update()
  check("等待未到不重发", sent == 1)
  clock = 2
  req:update() -- 重发
  req:update() -- 收完
  check("清空后重发并完成", table.concat(ev, "|") == "reasoning:半截|reset|retry 1/5 2|content:好|done:好:5", table.concat(ev, "|"))
  check("完成状态", req.state == "done" and sent == 2)
end

local Anthropic = dofile("mods/balatrobot/agent/llm/anthropic.lua")
Anthropic.Chat, Anthropic.decode = Chat, json.decode
local Responses = dofile("mods/balatrobot/agent/llm/responses.lua")
Responses.Chat = Chat

local TOOLS = {
  { type = "function", ["function"] = { name = "menu", description = "回主菜单", parameters = { type = "object", properties = {} } } },
}

--- 把一串事件喂给累积器, 返回 finish 的结果.
local function run(acc, events)
  for _, e in ipairs(events) do
    acc:feed(e)
  end
  return acc:finish()
end

do -- 地址: 三种协议共用 endpoint, 已有的协议路径先去掉
  check("chat 去掉 /messages 再补", Chat.join_url("https://x.test/v1/messages", "/chat/completions") == "https://x.test/v1/chat/completions")
  check("anthropic 根地址补 /v1", Chat.join_url("https://api.anthropic.com", "/messages", "/v1") == "https://api.anthropic.com/v1/messages")
  check("anthropic 已有版本段不重复", Chat.join_url("https://gw.test/api/v1/", "/messages", "/v1") == "https://gw.test/api/v1/messages")
  check("responses 换掉 chat 路径并保留查询串",
    Chat.join_url("https://x.test/openai/v1/chat/completions?k=1", "/responses") == "https://x.test/openai/v1/responses?k=1")
end

do -- chat: 思考强度写进请求体, 别的协议的 native 不发出去, 历史不改
  local history = {
    { role = "user", content = "hi" },
    { role = "assistant", content = "好", native = { format = "anthropic", blocks = {} } },
  }
  local _, _, body = Chat.build_request({ endpoint = "https://x.test/v1", model = "m", reasoning_effort = "high" }, history)
  local b = json.decode(body)
  check("chat 带 reasoning_effort", b.reasoning_effort == "high")
  check("chat 不发 native", body:find("native", 1, true) == nil and b.messages[2].content == "好", body)
  check("历史里的 native 还在", history[2].native ~= nil)
  local _, _, plain = Chat.build_request({ endpoint = "https://x.test/v1", model = "m", reasoning_effort = "" }, history)
  check("默认不带 reasoning_effort", json.decode(plain).reasoning_effort == nil)
end

do -- anthropic 请求: 思考方式, system, 工具, 相邻 user 合并, 缓存断点
  local history = {
    { role = "system", content = "你是 agent" },
    { role = "user", content = "状态" },
    { role = "assistant", content = Chat.NULL, tool_calls = {
      { id = "functions.menu:0", type = "function", ["function"] = { name = "menu", arguments = "" } },
    } },
    { role = "tool", tool_call_id = "functions.menu:0", content = "完成" },
    { role = "user", content = "新状态" },
  }
  local cfg = { endpoint = "https://api.anthropic.com", model = "claude-opus-5-5", api_key = "k", auth = "x-api-key",
    thinking = "adaptive", reasoning_effort = "medium" }
  local url, headers, body = Anthropic.build_request(cfg, history, TOOLS)
  local b = json.decode(body)
  check("anthropic 地址与版本头", url == "https://api.anthropic.com/v1/messages" and headers["anthropic-version"] ~= nil
    and headers["x-api-key"] == "k")
  check("自适应思考并显示摘要", b.thinking.type == "adaptive" and b.thinking.display == "summarized"
    and b.thinking.budget_tokens == nil and b.output_config.effort == "medium", body)
  check("system 单独放并打缓存", b.system[1].text == "你是 agent" and b.system[1].cache_control.type == "ephemeral")
  check("工具转成 input_schema, 空 properties 仍是对象", b.tools[1].input_schema ~= nil
    and body:find('"properties":{}', 1, true) ~= nil, body)
  check("消息角色交替", #b.messages == 3 and b.messages[1].role == "user" and b.messages[2].role == "assistant"
    and b.messages[3].role == "user")
  local use = b.messages[2].content[1]
  check("重建 tool_use: id 去掉非法字符, 空参数是对象", use.type == "tool_use" and use.id == "functions_menu_0"
    and body:find('"input":{}', 1, true) ~= nil, body)
  local last = b.messages[3].content
  check("tool 结果与后面的状态并成一条 user, 结果在前", last[1].type == "tool_result" and last[1].tool_use_id == "functions_menu_0"
    and last[2].text == "新状态")
  check("最后一块打缓存断点", last[2].cache_control and last[2].cache_control.type == "ephemeral")

  cfg.thinking, cfg.reasoning_effort = "budget", "high"
  local _, _, budget = Anthropic.build_request(cfg, history, TOOLS)
  local bb = json.decode(budget)
  check("固定预算按强度折算, 小于 max_tokens", bb.thinking.type == "enabled" and bb.thinking.budget_tokens == Anthropic.BUDGETS.high
    and bb.thinking.budget_tokens < bb.max_tokens and bb.output_config == nil)
  cfg.thinking, cfg.reasoning_effort = "omit", ""
  local _, _, omit = Anthropic.build_request(cfg, history, TOOLS)
  check("不指定时不写 thinking", json.decode(omit).thinking == nil and json.decode(omit).output_config == nil)
end

do -- anthropic 流: 思考 + 签名 + 正文 + 工具调用, native 原样回传
  local acc = Anthropic.accumulator()
  local shown = {}
  local events = {
    { type = "message_start", message = { usage = { input_tokens = 10, cache_read_input_tokens = 90, output_tokens = 1 } } },
    { type = "content_block_start", index = 0, content_block = { type = "thinking", thinking = "", signature = "" } },
    { type = "content_block_delta", index = 0, delta = { type = "thinking_delta", thinking = "先看" } },
    { type = "content_block_delta", index = 0, delta = { type = "thinking_delta", thinking = "手牌" } },
    { type = "content_block_delta", index = 0, delta = { type = "signature_delta", signature = "SIG" } },
    { type = "content_block_stop", index = 0 },
    { type = "content_block_start", index = 1, content_block = { type = "redacted_thinking", data = "ENC" } },
    { type = "content_block_start", index = 2, content_block = { type = "text", text = "" } },
    { type = "content_block_delta", index = 2, delta = { type = "text_delta", text = "出对子" } },
    { type = "content_block_start", index = 3, content_block = { type = "tool_use", id = "toolu_1", name = "play", input = {} } },
    { type = "content_block_delta", index = 3, delta = { type = "input_json_delta", partial_json = '{"cards":[0,1],' } },
    { type = "content_block_delta", index = 3, delta = { type = "input_json_delta", partial_json = '"opt":{}}' } },
    { type = "message_delta", delta = { stop_reason = "tool_use" }, usage = { output_tokens = 50 } },
  }
  for _, e in ipairs(events) do
    for _, d in ipairs(acc:feed(e)) do
      shown[#shown + 1] = d.kind .. ":" .. d.text
    end
  end
  check("增量按顺序", table.concat(shown, "|") == "reasoning:先看|reasoning:手牌|content:出对子", table.concat(shown, "|"))
  check("message_delta 后还没到最后", acc.done and not acc.terminal)
  acc:feed({ type = "message_stop" })
  check("message_stop 是最后一个事件", acc.terminal and acc.finish_reason == "tool_calls")
  local msg, usage = acc:finish()
  check("chat 格式的调用", msg.tool_calls[1].id == "toolu_1" and msg.tool_calls[1]["function"].arguments == '{"cards":[0,1],"opt":{}}'
    and msg.reasoning_content == "先看手牌" and msg.content == "出对子")
  check("输入 token 含缓存读取", usage.prompt_tokens == 100 and usage.cached == 90 and usage.completion_tokens == 50)
  local blocks = msg.native.blocks
  check("native 保留签名与 redacted_thinking, 顺序不变", #blocks == 4 and blocks[1].signature == "SIG" and blocks[1].thinking == "先看手牌"
    and blocks[2].type == "redacted_thinking" and blocks[2].data == "ENC" and blocks[3].type == "text" and blocks[4].type == "tool_use")

  -- 下一轮原样带回去, 工具参数里嵌套的空对象不变成数组, 历史里的块不被缓存断点改动.
  local history = {
    { role = "user", content = "状态" },
    msg,
    { role = "tool", tool_call_id = "toolu_1", content = "完成" },
  }
  local _, _, body = Anthropic.build_request({ endpoint = "https://api.anthropic.com/v1", model = "m" }, history)
  local b = json.decode(body)
  local back = b.messages[2].content
  check("回传 thinking 块与签名", back[1].type == "thinking" and back[1].signature == "SIG" and back[2].data == "ENC")
  check("回传的工具参数原样", body:find('"input":{"cards":[0,1],"opt":{}}', 1, true) ~= nil, body)
  check("缓存断点不改历史", history[3].cache_control == nil and msg.native.blocks[4].cache_control == nil)
end

do -- anthropic: 流里的 error 事件与非流式响应
  local err = Anthropic.accumulator()
  err:feed({ type = "error", error = { type = "overloaded_error", message = "Overloaded" } })
  check("error 事件可重试", err.error ~= nil and Chat.classify(200, err.error) == "retry")
  check("prompt is too long 算上下文超长", select(2, Chat.classify(400, { type = "error", error = { type = "invalid_request_error",
    message = "prompt is too long: 210000 tokens > 200000 maximum" } })):find("上下文超长", 1, true) ~= nil)
  local msg = run(Anthropic.accumulator(), { {
    type = "message", stop_reason = "end_turn", usage = { input_tokens = 3, output_tokens = 2 },
    content = { { type = "text", text = "好的" } },
  } })
  check("非流式响应", msg.content == "好的" and msg.tool_calls == nil)
end

do -- responses 请求: 无状态, instructions, 扁平工具, 推理只在设了强度时要
  local history = {
    { role = "system", content = "你是 agent" },
    { role = "user", content = "状态" },
    { role = "assistant", content = "看看", tool_calls = {
      { id = "call_1", type = "function", ["function"] = { name = "menu", arguments = "{}" } },
    } },
    { role = "tool", tool_call_id = "call_1", content = "完成" },
  }
  local url, _, body = Responses.build_request({ endpoint = "https://api.openai.com/v1", model = "gpt-x", reasoning_effort = "high" },
    history, TOOLS)
  local b = json.decode(body)
  check("responses 地址", url == "https://api.openai.com/v1/responses")
  check("无状态并带 instructions", b.store == false and b.instructions == "你是 agent" and b.messages == nil)
  check("推理强度, 摘要与加密推理", b.reasoning.effort == "high" and b.reasoning.summary == "auto"
    and b.include[1] == "reasoning.encrypted_content")
  check("工具扁平且关掉 strict", b.tools[1].name == "menu" and b.tools[1].strict == false and b.tools[1]["function"] == nil)
  check("调用与结果按 call_id 对应", b.input[3].type == "function_call" and b.input[3].call_id == "call_1"
    and b.input[4].type == "function_call_output" and b.input[4].call_id == "call_1" and b.input[4].output == "完成")
  local _, _, plain = Responses.build_request({ endpoint = "https://api.openai.com/v1", model = "gpt-x" }, history, TOOLS)
  check("没设强度时不要推理", json.decode(plain).reasoning == nil and json.decode(plain).include == nil)
end

do -- responses 流: 推理摘要, 正文, 调用; native 只留可回传的项且顺序不变
  local acc = Responses.accumulator()
  local shown = {}
  local reasoning_item = { type = "reasoning", id = "rs_1", summary = { { type = "summary_text", text = "先看手牌" } },
    encrypted_content = "ENC" }
  local call_item = { type = "function_call", id = "fc_1", call_id = "call_9", name = "play", arguments = '{"cards":[0]}', status = "completed" }
  local events = {
    { type = "response.created", response = { status = "in_progress" } },
    { type = "response.output_item.added", output_index = 0, item = { type = "reasoning", id = "rs_1" } },
    { type = "response.reasoning_summary_text.delta", output_index = 0, summary_index = 0, delta = "先看" },
    { type = "response.reasoning_summary_text.delta", output_index = 0, summary_index = 0, delta = "手牌" },
    { type = "response.reasoning_summary_text.delta", output_index = 0, summary_index = 1, delta = "再出牌" },
    { type = "response.output_item.added", output_index = 1, item = { type = "reasoning", id = "rs_2" } },
    { type = "response.output_item.added", output_index = 2, item = { type = "message", role = "assistant", content = {} } },
    { type = "response.output_text.delta", output_index = 2, delta = "出一张" },
    { type = "response.output_item.added", output_index = 3, item = { type = "function_call", call_id = "call_9", name = "play", arguments = "" } },
    { type = "response.function_call_arguments.delta", output_index = 3, delta = '{"cards":' },
    { type = "response.function_call_arguments.delta", output_index = 3, delta = "[0]}" },
  }
  for _, e in ipairs(events) do
    for _, d in ipairs(acc:feed(e)) do
      shown[#shown + 1] = d.kind .. ":" .. d.text
    end
  end
  check("摘要换段空一行", table.concat(shown, "|") == "reasoning:先看|reasoning:手牌|reasoning:\n\n|reasoning:再出牌|content:出一张",
    table.concat(shown, "|"))
  check("调用计数", acc:tool_call_count() == 1 and not acc.terminal)
  acc:feed({ type = "response.completed", response = {
    status = "completed",
    usage = { input_tokens = 100, output_tokens = 20, input_tokens_details = { cached_tokens = 60 },
      output_tokens_details = { reasoning_tokens = 12 } },
    output = {
      reasoning_item,
      { type = "reasoning", id = "rs_2", summary = {} }, -- 没有加密内容, 不能回传
      { type = "message", id = "msg_1", status = "completed", role = "assistant",
        content = { { type = "output_text", text = "出一张", annotations = {} } } },
      call_item,
    },
  } })
  check("response.completed 是最后一个事件", acc.terminal)
  local msg, usage = acc:finish()
  check("chat 格式的调用", msg.tool_calls[1].id == "call_9" and msg.tool_calls[1]["function"].arguments == '{"cards":[0]}'
    and msg.content == "出一张" and acc.finish_reason == "tool_calls")
  check("usage: 缓存与推理", usage.prompt_tokens == 100 and usage.cached == 60 and usage.reasoning_tokens == 12)
  local items = msg.native.items
  check("native 去掉不能回传的推理, 保持顺序", #items == 3 and items[1].type == "reasoning" and items[1].encrypted_content == "ENC"
    and items[2].type == "message" and items[3].type == "function_call")
  check("消息与调用项去掉 id 与 status", items[2].id == nil and items[3].id == nil and items[3].status == nil
    and items[3].call_id == "call_9")

  local history = { { role = "user", content = "状态" }, msg, { role = "tool", tool_call_id = "call_9", content = "完成" } }
  local _, _, body = Responses.build_request({ endpoint = "https://api.openai.com/v1", model = "gpt-x" }, history)
  local b = json.decode(body)
  check("回传加密推理与调用", b.input[2].type == "reasoning" and b.input[2].encrypted_content == "ENC"
    and b.input[4].type == "function_call" and b.input[5].type == "function_call_output")
  check("推理项的空 summary 是数组", json.decode(Chat.encode({ type = "reasoning", summary = {} })).summary ~= nil)

  local failed = Responses.accumulator()
  failed:feed({ type = "response.failed", response = { error = { code = "server_error", message = "boom" } } })
  check("response.failed 可重试", failed.error ~= nil and Chat.classify(200, failed.error) == "retry")
end

do -- client: anthropic 协议收到 message_stop 就完成, 不等连接关闭
  local items = {
    { kind = "status", status = 200, text = "Content-Type: text/event-stream\n" },
    { kind = "event", text = 'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}' },
    { kind = "event", text = 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"好"}}' },
    { kind = "event", text = 'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}' },
    { kind = "event", text = 'event: message_stop\ndata: {"type":"message_stop"}' },
  }
  local sent_url
  local fake = {
    set_logger = function() end,
    set_sse = function() end,
    load = function() return true end,
    available = function() return true end,
    backend = function() return "bbnet" end,
    info = function() end,
    request = function(r)
      sent_url = r.url
      return { poll = function() local out = items; items = {}; return out end, close = function() end }
    end,
  }
  local Client = dofile("mods/balatrobot/agent/llm/client.lua")
  Client.init({
    bbnet = fake, chat = Chat, sse = Sse, anthropic = Anthropic, responses = Responses,
    text = dofile("mods/balatrobot/agent/text.lua"), json = json, log = function() end, now = function() return 0 end,
  })
  local done
  local req = Client.start({ endpoint = "https://api.anthropic.com", model = "m", api_format = "anthropic" },
    { { role = "user", content = "hi" } }, nil, { on_done = function(msg) done = msg end })
  req:update()
  check("anthropic 请求走 /v1/messages", sent_url == "https://api.anthropic.com/v1/messages", sent_url)
  check("message_stop 后完成", req.state == "done" and done and done.content == "好" and done.native.format == "anthropic",
    req.state)
  check("不认识的协议按 chat", Client.protocol({ api_format = "nope" }) == Chat)
  Chat.text = nil
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
