-- 内置 agent 主循环的单元测试, 用 luajit 在仓库根目录运行: just test-agent
package.path = "mods/Steamodded/libs/json/?.lua;" .. package.path
local json = require("json")

local DIR = "mods/balatrobot/agent/loop/"
local Tools = dofile(DIR .. "tools.lua")
local Prompt = dofile(DIR .. "prompt.lua")
local History = dofile(DIR .. "history.lua")
local Summary = dofile(DIR .. "summary.lua")
local Text = dofile("mods/balatrobot/agent/text.lua")
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
    text = Text,
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
      begin_request = function(label)
        env.label = label
      end,
      push = function() end,
      reset = function() end,
      finish = function() end,
      show_error = function(text)
        env.bar_error = text
      end,
      show_status = function() end,
    },
    client = {
      start = function(_, messages, tools, callbacks, opts)
        local snapshot = { tools = tools, label = env.label, opts = opts }
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
  --- 让当前请求以一段文字完成 (写摘要的请求).
  function env.reply_text(text, usage)
    current.callbacks.on_done({ role = "assistant", content = text }, usage or { prompt_tokens = 50, completion_tokens = 20 })
  end
  --- 让当前请求失败.
  function env.fail(reason, detail)
    current.callbacks.on_error(reason, detail)
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
  check("手册不可用时仍给 dynamics", (function()
    for _, def in ipairs(Tools.definitions({ knowledge = false })) do
      if def["function"].name == "dynamics" then
        return true
      end
    end
    return false
  end)())
  check("dynamics 是只读工具", Tools.QUERIES.dynamics == true and Tools.ACTIONS.dynamics == nil)
  -- 工具描述与端点参数要保持一致: 牌堆那两项是可选的枚举
  local dynamics_def
  for _, def in ipairs(Tools.definitions()) do
    if def["function"].name == "dynamics" then
      dynamics_def = def["function"]
    end
  end
  local props = dynamics_def and dynamics_def.parameters.properties or {}
  check(
    "dynamics 能要牌堆与弃牌堆",
    props.deck and props.deck.enum[1] == "stats" and props.discard and not props.deck.required,
    tostring(props.deck and props.deck.type)
  )
  check("dynamics 可关掉默认项", props.targets and props.targets.type == "boolean" and props.cards ~= nil)
  check("dynamics 无必填参数", dynamics_def.parameters.required == nil)
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

do -- 摘要: 牌型行带打出次数 (超新星要看它, 卡面上没有); 没打过的牌型只写等级与数值
  local s = Summary.new()
  local gs = hand_state({
    hands = {
      ["Flush"] = { order = 7, level = 2, chips = 50, mult = 6, played = 12, played_this_round = 2 },
      ["Pair"] = { order = 11, level = 1, chips = 10, mult = 2, played = 8, played_this_round = 0 },
      ["Three of a Kind"] = { order = 9, level = 3, chips = 40, mult = 5, played = 0, played_this_round = 0 },
      -- 没打过也没升级的不列
      ["High Card"] = { order = 12, level = 1, chips = 5, mult = 1, played = 0, played_this_round = 0 },
    },
  })
  local text = s:render(gs)
  check("打过时给本赛局与本回合次数", text:find("同花 Lv2 50x6 已打12(本回合2)", 1, true) ~= nil, text)
  check("本回合没打过时次数为 0", text:find("对子 Lv1 10x2 已打8(本回合0)", 1, true) ~= nil, text)
  check("升级但没打过时只给等级与数值", text:find("三条 Lv3 40x5", 1, true) ~= nil and not text:find("三条 Lv3 40x5 已打", 1, true), text)
  check("没打过也没升级的不出现", not text:find("高牌", 1, true), text)
end

do -- 摘要: 手册文本还剩占位的牌 (认牌目标, 成长值) 每次都用实时文本, 不拿占位糊弄模型
  local s = Summary.new(function(key)
    if key == "j_castle" then
      return { name = "城堡", effect = "每弃掉一张[本回合目标花色]牌 这张小丑牌获得+3 筹码 (当前为+[当前筹码]筹码)" }
    end
    if key == "j_joker" then
      return { name = "小丑", effect = "+4 倍率" }
    end
  end)
  local gs = hand_state({
    jokers = {
      limit = 5,
      cards = {
        { key = "j_castle", label = "城堡", value = { effect = "每弃掉一张梅花牌 这张小丑牌获得+3筹码 (当前为+12筹码)" }, modifier = {}, state = {} },
        { key = "j_joker", label = "小丑", value = { effect = "+4 倍率" }, modifier = {}, state = {} },
      },
    },
  })
  local first = s:render(gs)
  check("占位换成实时文本", first:find("城堡: 每弃掉一张梅花牌 这张小丑牌获得+3筹码 (当前为+12筹码)", 1, true) ~= nil, first)
  check("不出现占位", not first:find("[本回合目标花色]", 1, true) and not first:find("[当前筹码]", 1, true))
  check("静态效果的牌第一次附效果", first:find("小丑: +4 倍率", 1, true) ~= nil, first)
  local second = s:render(gs)
  check("第二次仍给实时文本", second:find("当前为+12筹码", 1, true) ~= nil)
  gs.jokers.cards[1].value.effect = "每弃掉一张方片牌 这张小丑牌获得+3筹码 (当前为+15筹码)"
  local third = s:render(gs)
  check("值变了摘要也跟着变", third:find("当前为+15筹码", 1, true) ~= nil and not third:find("当前为+12筹码", 1, true))
  check("静态效果的牌第二次不再附效果", third:find("+4 倍率", 1, true) == nil, third)
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

do -- 摘要: 上一手只给一行结果, 明细不塞进摘要 (明细在出牌那一步的结果里给一次)
  local s = Summary.new()
  local gs = hand_state({
    round = {
      chips = 3915,
      hands_left = 4,
      discards_left = 3,
      last_hand = { line = "上一手: 同花 Lv1 = 3915", text = "红桃K | +10 筹码 | 45x4" },
    },
  })
  local text = s:render(gs)
  check("摘要带上一手那一行", text:find("\n上一手: 同花 Lv1 = 3915\n", 1, true) ~= nil, text)
  check("摘要不带明细", not text:find("45x4", 1, true))
end

do -- 出牌那一步: 结果开头是这一手的计分过程, 后面接新的状态摘要
  local env = harness()
  env.responder = function(method)
    if method == "play" then
      return hand_state({
        round = {
          chips = 3915,
          hands_left = 3,
          discards_left = 3,
          last_hand = {
            line = "上一手: 同花 Lv1 = 3915",
            text = "上一手: 同花 Lv1 = 3915\n出牌: 红桃A* 黑桃10\n基础 35x4\n红桃A | +11 筹码 | 46x4\n= 3915",
          },
        },
      })
    end
    return env.gs
  end
  env.driver.start()
  env.tick()
  env.reply({ { "play", { cards = { 0, 1 }, reason = "打同花" } } })
  env.settle()
  local tool = env.requests[2][#env.requests[2]]
  check("出牌结果开头是计分过程", tool.role == "tool" and tool.content:find("^计分过程:\n") ~= nil, tool.content)
  check("计分过程带逐项明细", tool.content:find("红桃A | +11 筹码 | 46x4", 1, true) ~= nil)
  check(
    "明细之后接新的状态摘要",
    tool.content:find("完成. 当前状态:", 1, true) ~= nil and tool.content:find("本回合: 已得 3915 分", 1, true) ~= nil
  )
end

do -- 不是出牌的动作不设计分过程, 但摘要里仍有上一手那一行
  local env = harness()
  env.gs = hand_state({
    round = {
      chips = 3915,
      hands_left = 4,
      discards_left = 3,
      last_hand = { line = "上一手: 同花 Lv1 = 3915", text = "红桃A | +11 筹码 | 46x4" },
    },
  })
  env.driver.start()
  env.tick()
  env.reply({ { "discard", { cards = { 0 }, reason = "弃掉黑桃10" } } })
  env.settle()
  local tool = env.requests[2][#env.requests[2]]
  check("弃牌结果不以计分过程开头", tool.content:find("^计分过程") == nil, tool.content)
  check("弃牌结果里仍有上一手那一行", tool.content:find("上一手: 同花 Lv1 = 3915", 1, true) ~= nil)
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
  check("本局设置排在策略之前", system:find("## 本局设置", 1, true) < system:find("## 玩家指定的策略", 1, true))
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
  check("清除策略后再开始, 只剩默认与本局设置", fresh == Prompt.system(env.cfg))
end

do -- 本局设置: 通关之后继续无尽还是停下, 在胜利之前就要让模型知道
  local env = harness()
  env.cfg.after_win = "endless"
  env.driver.start()
  env.tick()
  local endless = env.requests[1][1].content
  check("开无尽时提醒要为长线规划", endless:find("之后继续无尽模式", 1, true) ~= nil, endless)
  check("两种设置都提到通关条件", endless:find("打完底注 8 的 Boss 即通关", 1, true) ~= nil)

  env.cfg.after_win = "menu"
  env.reply({ { "notify", { message = "先看看" } } })
  env.settle()
  check(
    "运行中改设置不影响这一次",
    (env.requests[2] and env.requests[2][1].content or ""):find("之后继续无尽模式", 1, true) ~= nil
  )
  env.driver.stop()
  env.driver.start()
  env.tick()
  local menu = env.requests[#env.requests][1].content
  check("重新开始后换成停下那一段", menu:find("之后回主菜单并停止", 1, true) ~= nil, menu)
  check("停下的那一段不再提无尽规划", not menu:find("一直打下去", 1, true))

  local plain = harness()
  plain.cfg.after_win = nil
  plain.driver.start()
  plain.tick()
  check(
    "设置缺省时按停下写",
    (plain.requests[1][1].content):find("之后回主菜单并停止", 1, true) ~= nil
  )
end

do -- 固定种子: 设置了就覆盖模型给的种子 (没给也补上), 结果里告诉模型
  local env = harness()
  env.gs = hand_state({ state = "MENU" })
  env.cfg.seed = "ABC123"
  env.driver.start()
  env.tick()
  env.reply({
    { "start", { deck = "RED", stake = "WHITE", seed = "ZZZZ", reason = "开局" } },
  })
  env.settle()
  local start = env.calls[1]
  check("固定种子覆盖模型给的种子", start and start.method == "start" and start.params.seed == "ABC123")
  local msgs = env.requests[2] or {}
  check("开局结果告诉模型用了固定种子", msgs[#msgs] and msgs[#msgs].content:find("ABC123", 1, true) ~= nil)

  local plain = harness()
  plain.gs = hand_state({ state = "MENU" })
  plain.driver.start()
  plain.tick()
  plain.reply({ { "start", { deck = "RED", stake = "WHITE", reason = "开局" } } })
  plain.settle()
  check("没设种子时按模型给的参数开局", plain.calls[1] and plain.calls[1].params.seed == nil)
end

do -- 思考强度: 设置了就写进请求的 extra, 默认不写 (由服务端决定)
  local env = harness()
  env.driver.start()
  env.tick()
  local first = env.requests[1]
  check("默认不带思考强度", first and (first.opts == nil or first.opts.extra == nil or first.opts.extra.reasoning_effort == nil))
  env.cfg.reasoning_effort = "high"
  env.reply({ { "notify", { message = "先看看" } } })
  env.settle()
  local second = env.requests[2]
  check("设置后请求带上 reasoning_effort", second and second.opts and second.opts.extra and second.opts.extra.reasoning_effort == "high")
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

do -- 超长查询结果截断后必须仍是合法 UTF-8: 裸切半个汉字会让服务端拒掉整个请求
  -- (实测 400: invalid unicode code point, 手册内容超过 6000 字节时就会走到这里).
  local env = harness()
  -- 中文内容按 JSON 编码后每字 3 字节, 每 7 字节一个循环: 6000 正好落在汉字中间
  local big = string.rep("中文a", 2000)
  env.responder = function(method)
    if method == "lookup" then
      return { cards = { { id = "j_test", effect_zh = big } } }
    end
    return env.gs
  end
  env.driver.start()
  env.tick()
  env.reply({ { "lookup", { keys = { "j_test" } } } })
  env.settle()
  local tool = env.requests[2][#env.requests[2]]
  check("查询结果按上限截断", tool.role == "tool" and #tool.content < 6400, tostring(#tool.content))
  local ok, at = Text.valid_utf8(tool.content)
  check("截断后的内容仍是合法 UTF-8", ok, at and ("非法字节在第 " .. at .. " 字节") or nil)
  check("截断后带提示尾巴", tool.content:find("已截断", 1, true) ~= nil)
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

--- 先正常打几轮, 让历史里有可以压缩的较早部分. 最后一轮的用量由 last_usage 决定.
---@param env table
---@param turns integer
---@param last_usage table?
local function play_turns(env, turns, last_usage)
  env.driver.start()
  env.tick()
  for i = 1, turns do
    env.reply({ { "notify", { message = "第 " .. i .. " 轮的解说" } } }, i == turns and last_usage or nil)
    env.settle()
  end
end

---@param snapshot table? env.requests 里的一项
---@return boolean
local function is_compaction(snapshot)
  return snapshot ~= nil and snapshot[1].content == Prompt.COMPACT_SYSTEM
end

do -- 压缩: 用量过 80% 时先发写摘要的请求 (不带工具, 带前缀), 完成后较早的部分换成摘要, 最近的原文保留
  local env = harness()
  env.cfg.context_limit = 1000
  play_turns(env, 3, { prompt_tokens = 900, completion_tokens = 10 })
  local compact = env.requests[#env.requests]
  check("用量过 80% 时发写摘要的请求", is_compaction(compact), tostring(#env.requests))
  check("写摘要的请求不带工具, 流式条带压缩前缀", compact and compact.tools == nil and compact.label == "压缩中: ")
  check("写摘要的请求带上较早的对话", compact and compact[2].content:find("阶段: 出牌", 1, true) ~= nil)
  local before = env.driver.stats.requests
  env.reply_text("红色牌组白注, 打到第 1 底注小盲注, 主打对子.")
  env.settle()
  local after = env.requests[#env.requests]
  check("写摘要的请求计入请求次数与用量", env.driver.stats.requests == before + 1 and env.driver.stats.completion_tokens >= 20)
  check("摘要之后发正常的请求", after and not is_compaction(after) and after.tools ~= nil)
  local kept_last = false
  for _, m in ipairs(after or {}) do
    for _, call in ipairs(m.tool_calls or {}) do
      kept_last = kept_last or call["function"].arguments:find("第 3 轮的解说", 1, true) ~= nil
    end
  end
  check(
    "较早的部分换成摘要, 最近一轮保留原文",
    after and after[2].role == "user" and after[2].content:find("主打对子", 1, true) ~= nil
      and not after[2].content:find("阶段: 出牌", 1, true) and kept_last,
    after and tostring(#after)
  )
  check("压缩后历史成对", after and paired(after))
end

do -- 压缩: 写摘要失败时退回每步一行的记录继续打, 不停下
  local env = harness()
  env.cfg.context_limit = 1000
  play_turns(env, 3, { prompt_tokens = 900, completion_tokens = 10 })
  env.fail("连接断开")
  env.settle()
  local after = env.requests[#env.requests]
  check("写摘要失败后不停下", env.driver.state ~= "halted", env.driver.state)
  check(
    "写摘要失败后退回记录方式, 继续发正常请求",
    after and not is_compaction(after) and after.tools ~= nil and #after == 2 and after[2].role == "user",
    after and tostring(#after)
  )
end

do -- 压缩: 服务端报上下文超长时压缩后重发一次, 再超长才停下
  local env = harness()
  env.cfg.context_limit = 1000
  play_turns(env, 3)
  env.fail("400 上下文超长", "maximum context length exceeded")
  env.settle()
  check("超长后先压缩", is_compaction(env.requests[#env.requests]) and env.driver.state ~= "halted", env.driver.state)
  env.reply_text("摘要")
  env.settle()
  check("压缩后重发", not is_compaction(env.requests[#env.requests]))
  env.fail("400 上下文超长", "maximum context length exceeded")
  env.settle()
  check("重发后仍超长时停下", env.driver.state == "halted", env.driver.state)
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
