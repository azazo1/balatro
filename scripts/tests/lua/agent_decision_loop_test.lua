-- Decision 动作约束与分层参数选择的关键行为测试.
package.path = "mods/Steamodded/libs/json/?.lua;" .. package.path
local json = require("json")
local Planner = dofile("mods/balatrobot/agent/decision/planner.lua")
local Capabilities = dofile("mods/balatrobot/agent/decision/capabilities.lua")
local Rules = dofile("mods/bbcore/src/lua/utils/target_rules.lua")
local Slots = dofile("mods/bbcore/src/lua/utils/slots.lua")
local Summary = dofile("mods/balatrobot/agent/loop/summary.lua")
local Observation = dofile("mods/balatrobot/agent/decision/observation.lua")
local n = 0
local function check(name, value) assert(value, name); n = n + 1; print("ok   " .. name) end
local function choose(plan, id)
  assert(plan.question()); assert(plan.answer({ decision = { choice = id, confidence = 1 } }))
end
local function area(items, limit) return { cards = items or {}, config = { card_limit = limit or 5, highlighted_limit = 5 } } end
local function card(set, key, extra)
  local c = { ability = { set = set }, config = { center = { key = key, config = {} } }, cost = 2,
    can_sell_card = function(self) return not self.ability.eternal end,
    can_use_consumeable = function() return true end }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end
local g = { GAME = { dollars = 4, bankrupt_at = 0 }, P_CENTERS = { b_red = {} }, hand = area({}, 8),
  jokers = area(), consumeables = area(), shop_jokers = area(), shop_vouchers = area(), shop_booster = area(), pack_cards = area() }
local capability = Capabilities.new({ game = function() return g end, slots = Slots, target_rules = Rules })
local gs = { state = "SELECTING_HAND", round = { hands_left = 4, discards_left = 3 }, hand = { cards = {} } }
g.hand.cards = { card("Default", "H_A"), card("Default", "S_A"), card("Default", "D_A") }
g.hand.cards[1].ability.forced_selection = true
local caps = capability.snapshot(gs)
local plan = Planner.new(caps, {})
choose(plan, "o1"); choose(plan, "o1"); choose(plan, "o2")
check("出牌参数去重且包含强制牌", plan.result and plan.result.params.cards[1] == 0 and plan.result.params.cards[2] == 1 and #plan.result.params.cards == 2)
check("完整动作通过本地校验", Planner.validate(caps, plan.result.method, plan.result.params))
check("拒绝重复下标与漏掉强制牌", not Planner.validate(caps, "play", { cards = { 0, 0 } }) and not Planner.validate(caps, "play", { cards = { 1 } }))
check("拒绝未知方法与额外参数", not Planner.validate(caps, "set", {}) and not Planner.validate(caps, "play", { cards = { 0 }, unknown = true }))
local move_caps = { actions = { { method = "rearrange", params = {}, label = "重排", move = { area = "jokers", count = 3 } } } }
plan = Planner.new(move_caps, {}); choose(plan, "o1"); choose(plan, "o1"); choose(plan, "o2")
check("移动构造完整排列", plan.result.params.jokers[1] == 1 and plan.result.params.jokers[2] == 2 and plan.result.params.jokers[3] == 0)
check("重排拒绝原地不动", not Planner.validate(move_caps, "rearrange", { jokers = { 0, 1, 2 } }))
local many = { actions = {} }
for i = 1, 260 do many.actions[i] = { method = "buy", params = { card = i - 1 }, label = tostring(i) } end
plan = Planner.new(many, {})
local question = plan.question(); local count = 0; for _ in pairs(question.decision.criteria) do count = count + 1 end
check("大量候选分组不超过协议上限", count <= 255)
assert(plan.answer({ decision = { choice = "g130" } })); choose(plan, "o2")
check("分组仍能选到末尾候选", plan.result.params.card == 259)
plan = Planner.new({ actions = { { method = "start", params = {}, label = "开局", decks = { "RED" }, stakes = { "WHITE" } } } }, { seed = "TEST1234" })
choose(plan, "o1"); choose(plan, "o1"); choose(plan, "o1")
check("开局选择与固定种子", plan.result.params.deck == "RED" and plan.result.params.stake == "WHITE" and plan.result.params.seed == "TEST1234")
check("Aura 与 Ankh 共享特殊规则", Rules.requirements("c_aura", {}).min == 1 and Rules.requirements("c_ankh", {}).requires_joker)
check("目标规则拒绝无效范围", Rules.requirements("c_test", { max_highlighted = -1 }) == nil)
g.consumeables.cards = { card("Tarot", "c_death", { ability = { set = "Tarot", consumeable = { min_highlighted = 2, max_highlighted = 2 } } }) }
caps = capability.snapshot(gs)
local use
for _, action in ipairs(caps.actions) do if action.method == "use" then use = action end end
check("消耗牌携带目标数量而不提前选牌", use and use.target.min == 2 and use.target.max == 2 and #use.target.indices == 3 and g.hand.highlighted == nil)
g.jokers = area({ card("Joker", "j_joker", { ability = { set = "Joker", eternal = true } }) }, 1)
g.shop_jokers.cards = { card("Joker", "j_other"), card("Joker", "j_negative", { ability = { set = "Joker", card_limit = 1 } }) }
gs.state = "SHOP"; gs.round = { reroll_cost = 5 }
caps = capability.snapshot(gs)
check("永恒牌不可卖且无足够钱不可刷新", not Planner.validate(caps, "sell", { joker = 0 }) and not Planner.validate(caps, "reroll", {}))
check("满槽仍可买负片", not Planner.validate(caps, "buy", { card = 0 }) and Planner.validate(caps, "buy", { card = 1 }))
g.GAME.bankrupt_at = -20
caps = capability.snapshot(gs)
check("购买和刷新考虑信用额度", Planner.validate(caps, "reroll", {}))
gs.state = "SMODS_BOOSTER_OPENED"
g.pack_cards.cards = { card("Tarot", "c_test", { config = { center = { key = "c_test", config = { min_highlighted = 4, max_highlighted = 4 } } }, ability = { set = "Tarot", consumeable = {} } }) }
caps = capability.snapshot(gs)
check("卡包不足目标不提供选牌但仍可跳过", not Planner.validate(caps, "pack", { card = 0 }) and Planner.validate(caps, "pack", { skip = true }))
local observed = Observation.new({ summary = Summary, json = json })
local secret_gs = { state = "SELECTING_HAND", money = 4, round = { hands_left = 4 },
  cards = { cards = { { key = "secret-deck-order" } } },
  hand = { cards = { { key = "secret-hand", state = { hidden = true }, value = { rank = "A", suit = "H" } } } },
  jokers = { cards = { { key = "secret-joker", state = { hidden = true }, value = { effect = "secret-effect" } } } } }
local trail = {}; for i = 1, 25 do trail[i] = { method = "play", params = { cards = { 0 } } } end
local state = observed.state(secret_gs, { strategy = "策略", decision = { api_key = "secret-key" } }, trail, {})
local encoded = json.encode(state)
check("观察不发送 key, hidden 身份或摸牌顺序", not encoded:find("secret", 1, true) and #state.recent_actions == 20)
local rich = { state = "SHOP", jokers = { cards = { { key = "j_joker", label = "小丑", value = { effect = "收益" }, cost = { sell = 1 } } } } }
local first = observed.state(rich, {}, {}, {}); local second = observed.state(rich, {}, {}, {})
check("Decision 每次观察完整介绍卡牌", first.game == second.game and first.game:find("收益", 1, true))
local DecisionDriver = dofile("mods/balatrobot/agent/decision/driver.lua")
local Lifecycle = dofile("mods/balatrobot/agent/loop/lifecycle.lua")
local function driver_env()
  local env = { t = 0, version = 1, calls = {}, requests = {}, cfg = { decision = { min_confidence = 0 } },
    gs = { state = "SHOP" }, overlay = nil, busy = false }
  local fake_caps = { actions = { { method = "next_round", params = {}, label = "离店" } } }
  env.driver = DecisionDriver.new({
    lifecycle = Lifecycle, planner = Planner, json = json,
    config = function() return env.cfg end, now = function() return env.t end,
    gamestate = function() return env.gs end, overlay = function() return env.overlay end,
    busy = function() return env.busy end, version = function() return env.version end,
    capabilities = { snapshot = function() return fake_caps end },
    observation = { state = function() return {} end },
    client = { start = function(_, _, _, callbacks)
      local r = { callbacks = callbacks, update = function() end, cancel = function(self) self.cancelled = true end }
      env.requests[#env.requests + 1] = r; return r
    end },
    bar = { begin_request = function() end, finish = function() end, show_error = function() end },
    call = function(method, params, reason, cb)
      env.calls[#env.calls + 1] = { method = method, params = params }
      cb({ state = "BLIND_SELECT" }); return true
    end,
    abandon = function() end,
    report = function(event, a)
      if event == "halt" then env.halt = a
      elseif event == "usage" and env.pause_usage then env.driver.pause() end
    end,
  })
  function env.reply(confidence)
    env.requests[#env.requests].callbacks.on_done({ answers = { decision = { type = "choice", choice = "o1", confidence = confidence or 1 } } },
      { prompt_tokens = 1, completion_tokens = 1 })
  end
  env.driver.start(); env.driver.update()
  return env
end
local env = driver_env(); env.reply(); env.driver.update()
check("独立 driver 选择后执行单步", #env.calls == 1 and env.calls[1].method == "next_round")
env = driver_env(); local old = env.requests[1]; env.driver.pause(); env.reply(); env.driver.update()
check("独立 driver 暂停取消且迟到结果无效", old.cancelled and #env.calls == 0 and env.driver.state == "paused")
env.driver.resume(); env.driver.update()
check("恢复重新请求", #env.requests == 2)
env = driver_env(); env.reply(); env.version = 2; env.driver.update()
check("选择后观察过期重新规划", #env.calls == 0 and #env.requests == 2)
env = driver_env(); env.cfg.decision.min_confidence = 0.7; env.reply(0.5); env.driver.update()
check("低置信度暂停不执行", env.halt and #env.calls == 0)
env = driver_env(); env.pause_usage = true; env.reply(); env.driver.update()
check("用量回调同步暂停无执行", env.driver.state == "paused" and #env.calls == 0)
env = driver_env(); env.driver.manual(); env.driver.update()
check("手动操作取消旧请求", env.requests[1].cancelled and #env.requests == 1)
env.t = 2; env.driver.update()
check("手动停手后再请求", #env.requests == 2)
print(string.format("Decision 参数选择与循环: %d 项通过", n))
