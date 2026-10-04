--[[
BB Dump: 把每一步动作与它产生的完整游戏状态追加写成一个 JSONL 文件, 供离线分析, 或给规则引擎的重写
实现当基准数据.

刻意不改任何现有 mod: 只订阅 bbcore 的活动事件 (BB_ACTIVITY 的 "response"). 那个事件本身就覆盖了全部
执行路径 (外部 HTTP 调用, 内置 loop 的本地调用, 游戏内回放), 所以三种玩法都录得到, 也不需要 bbreplay
配合. 订阅只读, 不拦不改任何请求或响应.

为什么需要它: 回放文件里每一步只有 digest (状态摘要), 不含分数; 内置 agent 的转录 (-agent.jsonl) 里
LLM 型只记 messages 的条数, Decision 型的 state 是中文摘要, 都拿不到端点返回里的 round.last_hand
(那一手的完整计分明细). 分数对不上就没法逐手校准重写实现.

开启与输出:

- BBDUMP=1              开启. 没开时这个 mod 完全不动, 不影响正常游玩.
- BBDUMP_DIR=<路径>     输出目录, 默认 <存档目录>/dumps.
- BBDUMP_MODE=full      一行一次动作: 时间, 方法, 成败, 完整端点返回 (默认).
- BBDUMP_MODE=score     只留计分与局面相关的字段, 体积约为 full 的十分之一.

输出格式: 文件名 <启动时间>.dump.jsonl, 一行一个动作, 追加写且写完即关, 中途崩溃也不会丢已写出的部分.
]]

local MOD = SMODS.current_mod
local LOGGER = "BB.DUMP"

-- json 不是全局, 要显式 require (bbreplay 的 replay/log.lua 也是这么拿的).
local json = require("json")

local enabled = os.getenv("BBDUMP") == "1"
local mode = os.getenv("BBDUMP_MODE") or "full"
local out_dir = os.getenv("BBDUMP_DIR")
if out_dir == "" then out_dir = nil end

--- 查"mod 到底有没有跑起来"用的记录.
---
--- 它是唯一一条**不看 BBDUMP** 就写的输出: 路径取不到就静默放弃. 定位不到问题时先看它,
--- 因为它能区分三种情况 —— mod 没加载 / 钩子没被调用 / 环境变量没传到游戏进程.
local function trace(message)
  pcall(function()
    local dir = out_dir or love.filesystem.getSaveDirectory()
    local file = io.open(dir .. "/bbdump-trace.log", "a")
    if file then
      file:write(string.format("%s %s\n", os.date("%Y-%m-%d %H:%M:%S"), message))
      file:close()
    end
  end)
end

trace(string.format(
  "mod 加载: enabled=%s mode=%s dir=%s",
  tostring(enabled), mode, tostring(out_dir)
))

-- 实际写出状态.
local state = {
  path = nil,
  lines = 0,
  failed = 0,
  warned = false,
}

local function warn_once(message)
  if state.warned then return end
  state.warned = true
  sendWarnMessage(message, LOGGER)
end

--- 建目录. 存档目录内用 love.filesystem, 自定义路径交给 nativefs.
local function ensure_dir(dir)
  local ok, nativefs = pcall(require, "nativefs")
  if ok and nativefs and nativefs.createDirectory then
    pcall(nativefs.createDirectory, dir)
  end
  local save = love.filesystem.getSaveDirectory()
  if dir:sub(1, #save + 1) == save .. "/" then
    pcall(love.filesystem.createDirectory, dir:sub(#save + 2))
  end
end

--- 一行一个动作, 追加写.
local function append(entry)
  local ok, encoded = pcall(json.encode, entry)
  if not ok then
    state.failed = state.failed + 1
    trace("编码失败: " .. tostring(encoded))
    warn_once("Failed to encode dump entry: " .. tostring(encoded))
    return
  end
  local file, err = io.open(state.path, "ab")
  if not file then
    state.failed = state.failed + 1
    trace("打开失败: " .. tostring(err))
    warn_once("Failed to open dump file: " .. tostring(err))
    return
  end
  file:write(encoded, "\n")
  file:close()
  state.lines = state.lines + 1

  -- 不走 love.filesystem 的写包装, 要单独通知 Android 修正权限, 否则文件管理器与 adb 读不到.
  local ok_storage, storage = pcall(require, "android_storage")
  if ok_storage and type(storage) == "table" and storage.fix_path then
    pcall(storage.fix_path, state.path)
  end
end

--- score 模式: 只留计分与局面相关的字段.
local function slim(method, ok, error_message, response)
  local entry = {
    method = method,
    ok = ok,
  }
  if error_message then entry.error = error_message end
  if type(response) ~= "table" then
    return entry
  end

  entry.state = response.state
  entry.ante_num = response.ante_num
  entry.round_num = response.round_num
  entry.money = response.money
  -- 种子是复盘的前提. `start` 没指定种子时它是随机来的, 只有记下这一个才能重开同一局.
  entry.seed = response.seed
  entry.deck = response.deck
  entry.stake = response.stake

  -- 本盲注累计分数与这一手的计分明细都在这里, 是这份导出的主要目的.
  if type(response.round) == "table" then
    local round = response.round
    entry.round = {
      chips = round.chips,
      hands_left = round.hands_left,
      discards_left = round.discards_left,
      last_hand = round.last_hand,
    }
  end

  -- 手牌与小丑的牌面, 用于核对抽牌与持有物.
  --
  -- 只记牌面会在"加了强化或版本"这类操作上丢信息 —— 塔罗改过牌之后牌面不变, 变的是
  -- `modifier`. 所以把版本, 蜡封, 强化按回放 digest 的写法拼上去 (`C_T+m#red~mult`).
  for _, area in ipairs({ "hand", "jokers", "consumables", "shop", "vouchers", "packs", "pack" }) do
    local source = response[area]
    if type(source) == "table" and type(source.cards) == "table" then
      local cards = {}
      for _, card in ipairs(source.cards) do
        local token = card.key or card.label or card.id
        local mod = card.modifier
        if type(mod) == "table" then
          if mod.edition then token = token .. "+" .. string.lower(mod.edition) end
          if mod.seal then token = token .. "#" .. string.lower(mod.seal) end
          if mod.enhancement then token = token .. "~" .. string.lower(mod.enhancement) end
        end
        cards[#cards + 1] = token
      end
      entry[area] = cards
    end
  end

  return entry
end

-- 最近一次请求的方法与参数.
--
-- `response` 事件不带参数, 而参数是复盘的关键 (开局用的哪个牌组, 哪个种子, 买的是第几格).
-- 所以顺手订阅 `call`, 在这里存一份, 等结果回来时一起写进去.
local pending = {}

local function on_call(method, params)
  pending = { method = method, params = params }
end

local function on_response(method, ok, error_message, response)
  -- `BB_ACTIVITY.emit` 用 pcall 包住每个 listener, 所以这里抛出的异常只会变成一条屏幕警告.
  -- 自己再包一层并把错误写进 trace, 否则出了问题完全看不到原因.
  local success, err = pcall(function()
    if state.lines + state.failed < 3 then
      trace("收到 " .. tostring(method) .. " 的返回, 类型 " .. type(response))
    end
    local entry
    if mode == "score" then
      entry = slim(method, ok, error_message, response)
    else
      entry = {
        method = method,
        ok = ok,
        response = response,
      }
      if error_message then entry.error = error_message end
    end
    -- 把这次请求的参数也带上, 否则光有状态无法复盘 (例如开局用的哪个种子).
    if pending.method == method and pending.params ~= nil then
      entry.params = pending.params
    end
    entry.t = love.timer.getTime()
    append(entry)
  end)
  if not success then
    trace("处理 " .. tostring(method) .. " 时出错: " .. tostring(err))
  end
end

--- 所有 mod 加载完之后才订阅: bbcore 的活动追踪在那之前可能还没装好.
local function start()
  trace("after_load 钩子被调用")
  if not enabled then
    sendInfoMessage("BB Dump 未开启 (需要 BBDUMP=1), 本次不写任何文件", LOGGER)
    return
  end

  if not out_dir then
    out_dir = love.filesystem.getSaveDirectory() .. "/dumps"
  end
  ensure_dir(out_dir)

  state.path = out_dir .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".dump.jsonl"
  BB_ACTIVITY.on("call", on_call)
  BB_ACTIVITY.on("response", on_response)
  trace("已订阅 response, 写入 " .. state.path)

  sendInfoMessage("BB Dump 已开启, 写入 " .. state.path .. " (模式 " .. mode .. ")", LOGGER)
end

if BB_CORE and BB_CORE.after_load then
  BB_CORE.after_load[#BB_CORE.after_load + 1] = start
else
  -- 正常情况下 bbcore 一定先加载 (priority -50), 这里只是不让优先级出错时把游戏带崩.
  sendWarnMessage("BB Core 未加载, BB Dump 不工作", LOGGER)
end
