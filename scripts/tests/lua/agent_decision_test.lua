-- Decision 配置, 协议和异步传输的关键行为测试.
package.path = "mods/Steamodded/libs/json/?.lua;" .. package.path
local json = require("json")
local Configuration = dofile("mods/balatrobot/agent/configuration.lua")
local Chat = dofile("mods/balatrobot/agent/llm/chat.lua")
Chat.text = dofile("mods/balatrobot/agent/text.lua")
local Protocol = dofile("mods/balatrobot/agent/decision/protocol.lua").new(Chat)
local Client = dofile("mods/balatrobot/agent/decision/client.lua")
local n = 0
local function check(name, value)
  assert(value, name); n = n + 1; print("ok   " .. name)
end
local cfg = { endpoint = "https://api.typesafe.ai/v1", model = "jev-latest", auth = "bearer", api_key = "secret-test" }
local questions = {
  action = { type = "choice", instructions = "选择动作", criteria = { play = "出牌", discard = "弃牌" } },
  accept = { type = "noul", instructions = "是否执行" },
  quality = { type = "score", instructions = "评分", criteria = { "差", "中", "好" } },
}
local sample = {
  model = "jev-1.13.0", id = "request-1", provider = "typesafe",
  answers = {
    action = { type = "choice", choice = "play", confidence = 0.53, probabilities = { play = 0.69, discard = 0.31 } },
    accept = { type = "noul", noul = 0.91 },
    quality = { type = "score", score = 1.25, confidence = 0.1, probabilities = { ["0"] = 0.1, ["1"] = 0.55, ["2"] = 0.35 } },
  },
  usage = { input_tokens = 424, output_tokens = 73, cost = 0.1 },
}
local request = assert(Protocol.request(cfg, "局面", questions))
local body = json.decode(request.body)
check("System One 请求不带聊天字段", body.model == cfg.model and body.messages == nil and body.tools == nil and body.stream == nil)
check("Choice 对象与 Score 数组", body.questions.action.criteria.play == "出牌" and #body.questions.quality.criteria == 3)
check("官方 URL 与 Bearer", request.url == "https://api.typesafe.ai/v1/systemone" and request.headers.Authorization == "Bearer secret-test")
check("完整地址不重复补路径", Protocol.url("https://aihubmix.com/v1/systemone/?x=1") == "https://aihubmix.com/v1/systemone?x=1")
check("保留 OpenRouter alpha 地址", Protocol.url("https://openrouter.ai/api/alpha/decisions") == "https://openrouter.ai/api/alpha/decisions")
check("拒绝 URL 片段和控制字符", Protocol.url("https://api.example/v1#secret") == nil and Protocol.url("https://api.example/\n") == nil)
local raw_cfg = Configuration.copy(cfg); raw_cfg.auth = "raw"
check("原始 Authorization", Protocol.request(raw_cfg, {}, questions).headers.Authorization == "secret-test")
raw_cfg.auth = "x-api-key"
check("x-api-key", Protocol.request(raw_cfg, {}, questions).headers["x-api-key"] == "secret-test")
check("Choice 支持官方 null 描述", Protocol.request(cfg, {}, {
  test = { type = "choice", instructions = "选择", criteria = { named = Chat.NULL } },
}).body:find('"named":null', 1, true))
local result, usage = Protocol.response(sample, questions)
check("保留小数 Score 和独立 confidence", result.answers.quality.score == 1.25 and result.answers.action.confidence == 0.53)
check("用量和额外元数据", usage.prompt_tokens == 424 and usage.completion_tokens == 73 and result.cost == 0.1)
for _, mutate in ipairs({
  function(s) s.answers.action.choice = "sell" end,
  function(s) s.answers.action.type = "score" end,
  function(s) s.answers.action.probabilities.play = 0/0 end,
  function(s) s.answers.action.probabilities.sell = 0 end,
  function(s) s.answers.accept.noul = 1.1 end,
  function(s) s.answers.quality.score = 3 end,
  function(s) s.answers.action.confidence = math.huge end,
  function(s) s.usage.input_tokens = "424" end,
}) do
  local invalid = Configuration.copy(sample); mutate(invalid)
  check("拒绝非法答案 " .. (n + 1), Protocol.response(invalid, questions) == nil)
end
local invalid_q = Configuration.copy(questions); invalid_q.action.criteria = { "出牌", "弃牌" }
check("不将 Choice 数组当对象", Protocol.request(cfg, {}, invalid_q) == nil)
invalid_q = Configuration.copy(questions); invalid_q.quality.criteria = { low = "差", high = "好" }
check("不将 Score 对象当数组", Protocol.request(cfg, {}, invalid_q) == nil)

local saved = dofile("mods/balatrobot/config.lua")
saved.endpoint, saved.model, saved.api_key, saved.auth = cfg.endpoint, cfg.model, cfg.api_key, cfg.auth
Configuration.migrate(saved, 3)
check("迁移保留原有 LLM 连接", saved.llm.api_key == cfg.api_key and saved.llm.model == cfg.model and saved.api_key == nil)
check("默认仍使用 LLM", saved.builtin_backend == "llm" and Configuration.validate(saved))
saved.decision.api_key = "decision-key"; Configuration.apply_preset(saved.decision, "aihubmix")
check("预设不清空或复制 key", saved.decision.api_key == "decision-key" and saved.llm.api_key == cfg.api_key)
saved.builtin_backend = "decision"; saved.llm.api_key = ""
check("独立 Decision 不需 LLM key", Configuration.validate(saved))
saved.builtin_backend = "hybrid"
check("混合必须同时配置连接", not Configuration.validate(saved))
local snapshot = Configuration.runtime(saved); saved.decision.api_key = "changed"
check("运行快照不受编辑影响", snapshot.decision.api_key == "decision-key")
Configuration.migrate(saved, 4)
check("迁移幂等且不重置方式", saved.builtin_backend == "hybrid")

local function harness()
  local env = { t = 0, handles = {}, callbacks = {}, requests = {} }
  local client = Client.new({ protocol = Protocol, chat = Chat, json = json, now = function() return env.t end,
    net = { request = function(opts)
      env.requests[#env.requests + 1] = opts
      local handle = { queue = {}, closed = false, cancelled = false }
      function handle:poll() local q = self.queue; self.queue = {}; return q end
      function handle:close() self.closed = true end
      function handle:cancel() self.cancelled = true end
      env.handles[#env.handles + 1] = handle; return handle
    end },
  })
  function env.start()
    env.req = client.start(cfg, "局面", questions, {
      on_done = function(r, u) env.done = r; env.usage = u end,
      on_retry = function() env.retries = (env.retries or 0) + 1 end,
      on_error = function(reason, detail) env.error = reason .. (detail or "") end,
    })
    return env.req
  end
  function env.response(status, value)
    local h = env.handles[#env.handles]
    h.queue = { { kind = "status", status = status }, { kind = "body", text = value }, { kind = "done" } }
    env.req:update()
  end
  return env, client
end
local env = harness(); env.start()
local encoded = json.encode(sample)
env.handles[1].queue = { { kind = "status", status = 200 }, { kind = "body", text = encoded:sub(1, 20) } }
env.req:update()
check("分片未收齐不回调", env.done == nil)
env.handles[1].queue = { { kind = "body", text = encoded:sub(21) }, { kind = "done" } }; env.req:update()
check("普通 JSON 分片合并后完成", env.done and env.usage.prompt_tokens == 424 and env.handles[1].closed)
env = harness(); env.start(); env.req:cancel(); env.response(200, encoded)
check("取消后迟到响应不生效", env.done == nil and env.handles[1].cancelled and env.handles[1].closed)
env = harness(); env.start(); env.response(529, '{"error":{"message":"overloaded"}}')
check("529 退避而非立即重发", env.req.state == "waiting" and #env.requests == 1 and env.retries == 1)
env.t = 3; env.req:update()
check("到期重发", #env.requests == 2)
env.response(200, encoded)
check("重试后完成", env.done ~= nil)
env = harness(); env.start(); env.response(401, '{"error":{"message":"invalid secret-test"}}')
check("鉴权失败不重试且脱敏", env.req.state == "error" and env.retries == nil and not env.error:find("secret-test", 1, true))
env = harness(); env.start(); env.handles[1].queue = { { kind = "event", text = encoded } }; env.req:update()
check("拒绝 SSE 响应", env.req.state == "error")
local bad_env, bad_client = harness()
local synchronous = false
local bad = bad_client.start({}, "局面", questions, { on_error = function() synchronous = true end })
check("配置错误回调延期至 update", not synchronous)
bad:update(); check("update 报告配置错误", synchronous)
print(string.format("Decision 配置与协议: %d 项通过", n))
