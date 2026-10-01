-- 内置 agent 主循环的单元测试, 用 luajit 在仓库根目录运行: just test-agent
package.path = "mods/Steamodded/libs/json/?.lua;" .. package.path
local json = require("json")

local DIR = "mods/balatrobot/agent/loop/"
local Tools = dofile(DIR .. "tools.lua")
local Prompt = dofile(DIR .. "prompt.lua")
local History = dofile(DIR .. "history.lua")
local Summary = dofile(DIR .. "summary.lua")
local Driver = dofile(DIR .. "driver.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function hand_state(extra)
  local gs = {
    state = "SELECTING_HAND",
    ante_num = 1,
    round_num = 1,
    money = 4,
    round = { chips = 0, hands_left = 4, discards_left = 3 },
    hand = {
      cards = {
        { key = "H_A", value = { suit = "H", rank = "A" }, modifier = {}, state = {} },
        { key = "S_T", value = { suit = "S", rank = "T" }, modifier = { enhancement = "GLASS" }, state = {} },
      },
    },
    jokers = { limit = 5, cards = { { key = "j_joker", label = "Joker", value = { effect = "+4 Mult" }, cost = { sell = 1 } } } },
  }
  for k, v in pairs(extra or {}) do
    gs[k] = v
  end
  return gs
end

--- 假环境: 模型请求由测试手动完成, 端点调用立即按 responder 返回.
local function harness()
  local env = {
    t = 0,
    gs = hand_state(),
    overlay = nil,
    busy = false,
    requests = {}, -- 每次请求时的 messages 快照
    calls = {}, -- 端点调用记录
    cancelled = 0,
    cfg = { token_limit = 0, after_win = "menu" },
  }
  env.responder = function()
    return env.gs
  end
  local current = nil
  local deps = {
    tools = Tools,
    prompt = Prompt,
    history = History,
    summary = Summary,
    json = json,
    now = function()
      return env.t
    end,
    config = function()
      return env.cfg
    end,
    gamestate = function()
      return env.gs
    end,
    overlay = function()
      return env.overlay
    end,
    busy = function()
      return env.busy
    end,
    call = function(method, params, reason, cb)
      env.calls[#env.calls + 1] = { method = method, params = params, reason = reason }
      cb(env.responder(method, params))
      return true
    end,
    abandon = function() end,
    report = function(...)
      if env.report then
        env.report(...)
      end
    end,
    bar = {
      begin_request = function() end,
      push = function() end,
      reset = function() end,
      finish = function() end,
      show_error = function(text)
        env.bar_error = text
      end,
      show_status = function() end,
    },
    client = {
      start = function(_, messages, _, callbacks)
        local snapshot = {}
        for i, m in ipairs(messages) do
          snapshot[i] = m
        end
        env.requests[#env.requests + 1] = snapshot
        current = {
          callbacks = callbacks,
          update = function() end,
          cancel = function()
            env.cancelled = env.cancelled + 1
          end,
        }
        return current
      end,
    },
  }
  env.driver = Driver.new(deps)
  --- 让当前请求以给定的工具调用完成.
  function env.reply(calls, usage)
    local message = { role = "assistant", content = nil, tool_calls = {} }
    for i, c in ipairs(calls) do
      message.tool_calls[i] = {
        id = "call_" .. #env.requests .. "_" .. i,
        type = "function",
        ["function"] = { name = c[1], arguments = c[2] and json.encode(c[2]) or "{}" },
      }
    end
    if #calls == 0 then
      message.tool_calls = nil
      message.content = "我想想"
    end
    current.callbacks.on_done(message, usage or { prompt_tokens = 100, completion_tokens = 10 })
  end
  function env.tick(n)
    for _ = 1, n or 1 do
      env.driver.update()
    end
  end
  --- 推进到发出下一次请求, 或者停下 (最多 20 帧).
  function env.settle()
    local before = #env.requests
    for _ = 1, 20 do
      env.driver.update()
      local s = env.driver.state
      if #env.requests > before or s == "halted" or s == "stopped" or s == "paused" then
        return
      end
    end
  end
  return env
end

---@param messages table[]
---@return boolean 每个 tool_call 都有对应的 tool 结果
local function paired(messages)
  local open = {}
  for _, m in ipairs(messages) do
    for _, c in ipairs(m.tool_calls or {}) do
      open[c.id] = true
    end
    if m.role == "tool" then
      open[m.tool_call_id] = nil
    end
  end
  return next(open) == nil
end

do -- 工具: reason 拆出, 空参数不编码成 properties: []
  local method, params, reason = Tools.to_request("play", { cards = { 0, 1 }, reason = "打对子" })
  check("reason 从参数里拆出", method == "play" and reason == "打对子" and params.reason == nil and #params.cards == 2)
  check("未知工具报错", Tools.to_request("set", {}) == nil)
  local encoded = json.encode(Tools.definitions())
  check("没有空的 properties 数组", not encoded:find('"properties":%[%]'))
  check("可以不提供手册工具", #Tools.definitions({ knowledge = false }) == #Tools.definitions() - 4)
end

do -- 摘要: 下标从 0 开始, 效果只在第一次出现时附上
  local s = Summary.new(function(key)
    if key == "j_joker" then
      return { name = "小丑", effect = "+4 倍率" }
    end
  end)
  local first = s:render(hand_state())
  check("手牌下标从 0 开始", first:find("[0]红桃A", 1, true) and first:find("[1]黑桃10 (玻璃牌)", 1, true), first)
  check("第一次附效果", first:find("小丑 卖 $1: +4 倍率", 1, true), first)
  local second = s:render(hand_state())
  check("第二次不再附效果", not second:find("+4 倍率", 1, true))
  s:forget()
  check("forget 后重新介绍", s:render(hand_state()):find("+4 倍率", 1, true))
end

do -- 正常一轮: 顺序执行多个调用, 结果按 id 写回, 下一轮不重复给状态
  local env = harness()
  env.driver.start()
  env.tick()
  check("开始后发出请求", #env.requests == 1 and env.requests[1][2].role == "user")
  env.reply({ { "notify", { message = "对子能过" } }, { "play", { cards = { 0 }, reason = "打 A" } } })
  env.settle()
  check("两个调用依次执行", #env.calls == 2 and env.calls[1].method == "notify" and env.calls[2].method == "play")
  check("reason 交给 dispatcher", env.calls[2].reason == "打 A" and env.calls[2].params.reason == nil)
  check("进入下一次请求", #env.requests == 2)
  local msgs = env.requests[2]
  check("结果与调用成对", paired(msgs))
  check("动作结果带状态, 不再追加用户消息", msgs[#msgs].role == "tool" and msgs[#msgs].content:find("当前状态", 1, true))
end

do -- 策略: 开始时拼进系统提示词, 运行中改了不影响这一次, 停止后再开始才换
  local env = harness()
  env.cfg.strategy = "主打同花, 不买加筹码的小丑"
  env.driver.start()
  env.tick()
  local system = env.requests[1] and env.requests[1][1].content or ""
  check(
    "策略拼在系统提示词末尾",
    system:sub(1, #Prompt.SYSTEM) == Prompt.SYSTEM and system:find("主打同花", #Prompt.SYSTEM, true) ~= nil
  )
  env.cfg.strategy = "主打对子"
  env.reply({ { "notify", { message = "先看看" } } })
  env.settle()
  local running = env.requests[2] and env.requests[2][1].content or ""
  check("运行中改策略不影响这一次", running:find("主打同花", 1, true) ~= nil and not running:find("主打对子", 1, true))
  env.driver.stop()
  env.cfg.strategy = ""
  env.driver.start()
  env.tick()
  local fresh = env.requests[#env.requests][1].content
  check("清除策略后再开始, 系统提示词与默认一致", fresh == Prompt.SYSTEM)
end

do -- 只有解说没有动作时, 下一轮不重复附状态
  local env = harness()
  env.driver.start()
  env.tick()
  env.reply({ { "notify", { message = "先看看" } } })
  env.settle()
  local msgs = env.requests[2] or {}
  check("只解说后不追加状态", #env.requests == 2 and msgs[#msgs].role == "tool", msgs[#msgs] and msgs[#msgs].role)
end

do -- 失败: 剩余调用不执行; 同一调用连续失败 3 次停下
  local env = harness()
  env.responder = function(method)
    if method == "play" then
      return { message = "非法下标", name = "BAD_REQUEST" }
    end
    return env.gs
  end
  env.driver.start()
  env.tick()
  env.reply({ { "play", { cards = { 9 } } }, { "discard", { cards = { 0 } } } })
  env.settle()
  check("失败后剩余调用不执行", #env.calls == 1)
  check("剩余调用也有结果", paired(env.requests[2] or {}))
  for _ = 1, 2 do
    env.reply({ { "play", { cards = { 9 } } } })
    env.settle()
  end
  check("连续失败 3 次停下", env.driver.state == "halted", env.driver.state)
end

do -- 自动步骤: 解锁弹窗 continue, 结算 cash_out, 说明附在下一轮状态前
  local env = harness()
  env.overlay = "unlock"
  env.responder = function(method)
    if method == "continue" then
      env.overlay = nil
      env.gs = hand_state({ state = "ROUND_EVAL" })
    elseif method == "cash_out" then
      env.gs = hand_state({ state = "SHOP" })
    end
    return env.gs
  end
  env.driver.start()
  env.settle()
  check("依次自动 continue 与 cash_out", #env.calls == 2 and env.calls[1].method == "continue" and env.calls[2].method == "cash_out")
  local last = env.requests[1][#env.requests[1]]
  check("自动步骤的说明附在状态前", last.role == "user" and last.content:find("结算", 1, true) and last.content:find("商店", 1, true))
end

do -- 暂停: 取消进行中的请求, 恢复后重新给状态
  local env = harness()
  env.driver.start()
  env.tick()
  env.driver.pause()
  check("暂停取消请求", env.cancelled == 1 and env.driver.state == "paused")
  env.tick(3)
  check("暂停期间不发请求", #env.requests == 1)
  env.driver.resume()
  env.settle()
  local msgs = env.requests[2] or {}
  check("恢复后重新请求, 末尾是新的状态", #env.requests == 2 and msgs[#msgs].role == "user" and msgs[#msgs].content:find("暂停", 1, true))
end

do -- 模型不调用工具: 提醒, 连续 3 次停下
  local env = harness()
  env.driver.start()
  env.tick()
  for _ = 1, 3 do
    env.reply({})
    env.settle()
  end
  local nudged = env.requests[2] or {}
  check("提醒后不重复追加状态", nudged[#nudged].content == Prompt.NUDGE)
  check("连续不调用工具停下", env.driver.state == "halted" and #env.requests == 3, env.driver.state)
end

do -- 用量汇报后运行控制同步暂停 (单局上限): 队列里的调用都回 "未执行", 不再发请求
  local env = harness()
  local reports = {}
  env.report = function(event, ...)
    reports[#reports + 1] = { event, ... }
    if event == "usage" then
      env.driver.pause()
    end
  end
  env.driver.start()
  env.tick()
  env.reply({ { "notify", { message = "a" } }, { "play", { cards = { 0 } } } }, { prompt_tokens = 200, completion_tokens = 10 })
  env.settle()
  local usage
  for _, r in ipairs(reports) do
    if r[1] == "usage" then
      usage = r
    end
  end
  check("汇报用量", usage and usage[2] == 200 and usage[3] == 10)
  check("暂停后不执行也不再请求", env.driver.state == "paused" and #env.calls == 0 and #env.requests == 1, env.driver.state)
  check("未执行的调用也有结果", paired(env.driver._history.messages))
end

do -- 进入新底注时压缩历史
  local env = harness()
  env.gs = hand_state({ state = "BLIND_SELECT", ante_num = 1 })
  env.responder = function(method)
    if method == "select" then
      env.gs = hand_state({ state = "BLIND_SELECT", ante_num = 2 })
    end
    return env.gs
  end
  env.driver.start()
  env.tick()
  env.reply({ { "select", { reason = "打" } } })
  env.settle()
  local msgs = env.requests[2] or {}
  check("压缩后只剩系统提示与一条用户消息", #msgs == 2 and msgs[2].role == "user", tostring(#msgs))
  check("压缩后带之前的记录", msgs[2].content:find("select", 1, true))
end

do -- 胜利后回主菜单并停止
  local env = harness()
  local finished
  env.report = function(event, result)
    if event == "finish" then
      finished = result
      env.driver.stop(result)
    end
  end
  env.overlay = "win"
  env.driver.start()
  env.tick()
  check("胜利后自动 menu 并汇报结束", env.calls[1].method == "menu" and finished == "win" and env.driver.state == "stopped")
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("all passed")
