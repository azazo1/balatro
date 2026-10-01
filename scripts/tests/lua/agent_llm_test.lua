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
  Client.init({ bbnet = fake, chat = Chat, sse = Sse, json = json, log = function() end, now = function() return clock end })
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

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
