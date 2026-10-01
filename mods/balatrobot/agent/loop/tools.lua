--[[
内置 agent 可用的工具 (chat completions 的 tools). 纯逻辑, 不依赖游戏.

没有直接从 openrpc.json 生成: 那份规格缺少 pack 等本仓库用到的方法, 描述是英文且偏长.
这里手写一份精简的中文定义, 参数与端点的 schema 一致; 端点参数有变化时要同步修改.

- 动作工具都带 reason (简短理由, 作为决策消息显示), 调用时从参数里拆出来交给 dispatcher.
- 不给模型的方法: gamestate (每次结果里已经带状态摘要), cash_out, continue, endless (loop 自动处理),
  menu, save, load, set, add, screenshot (与游玩无关或会破坏进度).
]]

local M = {}

local INDEX = { type = "integer", minimum = 0 }
local INDICES = { type = "array", items = { type = "integer", minimum = 0 }, minItems = 1 }
local REASON = { type = "string", description = "给观众看的简短理由, 30 字以内" }

---@param props table
---@param required string[]?
---@return table
local function object(props, required)
  local schema = { type = "object" }
  -- 空表会被 json 编码成 [], 部分服务端拒绝 "properties": [], 没有参数时干脆不写.
  if next(props) ~= nil then
    schema.properties = props
  end
  if required and #required > 0 then
    schema.required = required
  end
  return schema
end

local DEFS = {
  {
    name = "start",
    description = "在主菜单开一局新游戏. deck 用牌组英文代号, 如 RED, BLUE; stake 用 WHITE 等.",
    parameters = object({
      deck = { type = "string", enum = { "RED", "BLUE", "YELLOW", "GREEN", "BLACK", "MAGIC", "NEBULA", "GHOST", "ABANDONED", "CHECKERED", "ZODIAC", "PAINTED", "ANAGLYPH", "PLASMA", "ERRATIC" } },
      stake = { type = "string", enum = { "WHITE", "RED", "GREEN", "BLACK", "BLUE", "PURPLE", "ORANGE", "GOLD" } },
      seed = { type = "string" },
      reason = REASON,
    }, { "deck", "stake" }),
  },
  {
    name = "select",
    description = "选择当前盲注, 开始这一回合.",
    parameters = object({ reason = REASON }, { "reason" }),
  },
  {
    name = "skip",
    description = "跳过当前盲注 (只能跳过小盲注和大盲注), 拿到跳过奖励标签.",
    parameters = object({ reason = REASON }, { "reason" }),
  },
  {
    name = "play",
    description = "打出手牌. cards 是手牌下标 (从 0 开始), 1~5 张.",
    parameters = object({ cards = INDICES, reason = REASON }, { "cards", "reason" }),
  },
  {
    name = "discard",
    description = "弃掉手牌并补牌, 消耗一次弃牌次数. cards 是手牌下标 (从 0 开始), 1~5 张.",
    parameters = object({ cards = INDICES, reason = REASON }, { "cards", "reason" }),
  },
  {
    name = "buy",
    description = "在商店购买. card, voucher, pack 三选一, 分别是商店牌, 优惠券, 补充包的下标.",
    parameters = object({ card = INDEX, voucher = INDEX, pack = INDEX, reason = REASON }, { "reason" }),
  },
  {
    name = "sell",
    description = "卖出. joker 与 consumable 二选一, 是小丑或消耗牌的下标.",
    parameters = object({ joker = INDEX, consumable = INDEX, reason = REASON }, { "reason" }),
  },
  {
    name = "reroll",
    description = "花钱刷新商店.",
    parameters = object({ reason = REASON }, { "reason" }),
  },
  {
    name = "next_round",
    description = "离开商店, 进入下一次选择盲注.",
    parameters = object({ reason = REASON }, { "reason" }),
  },
  {
    name = "pack",
    description = "在打开的补充包里选一张 (card 为下标, 需要目标的塔罗等用 targets 给手牌下标), 或 skip=true 跳过.",
    parameters = object({
      card = INDEX,
      targets = { type = "array", items = { type = "integer", minimum = 0 } },
      skip = { type = "boolean" },
      reason = REASON,
    }, { "reason" }),
  },
  {
    name = "use",
    description = "使用消耗牌槽里的牌, 出牌, 商店和开着补充包时都能用. consumable 为下标, 需要选牌的用 cards 给手牌下标"
      .. " (只在出牌或发了手牌的卡包里).",
    parameters = object({
      consumable = INDEX,
      cards = { type = "array", items = { type = "integer", minimum = 0 } },
      reason = REASON,
    }, { "consumable", "reason" }),
  },
  {
    name = "rearrange",
    description = "调整顺序. hand, jokers, consumables 三选一, 给出所有下标的新排列. 小丑顺序影响计分.",
    parameters = object({
      hand = { type = "array", items = { type = "integer", minimum = 0 } },
      jokers = { type = "array", items = { type = "integer", minimum = 0 } },
      consumables = { type = "array", items = { type = "integer", minimum = 0 } },
      reason = REASON,
    }, { "reason" }),
  },
  {
    name = "notify",
    description = "给观众发一条解说消息 (30~60 字), 讲观察, 对比和估分. 立刻返回; 后面的操作会等它退去再生效,"
      .. " 不用自己等. 操作前先用它讲.",
    parameters = object({
      message = { type = "string", maxLength = 200 },
      title = { type = "string", maxLength = 12, description = "2~4 字的标题" },
    }, { "message" }),
  },
  {
    name = "docs_index",
    description = "列出游戏规则手册的目录和按决策查阅表.",
    parameters = object({}),
  },
  {
    name = "docs_read",
    description = "读手册. 大文件不带 section 时只返回大纲, 再按 section (标题或锚点) 或 offset/limit 读.",
    parameters = object({
      path = { type = "string" },
      section = { type = "string" },
      offset = { type = "integer", minimum = 1 },
      limit = { type = "integer", minimum = 1 },
    }, { "path" }),
  },
  {
    name = "docs_search",
    description = "在手册里搜索子串, 可用 path 限定文件.",
    parameters = object({
      query = { type = "string" },
      path = { type = "string" },
      limit = { type = "integer", minimum = 1 },
    }, { "query" }),
  },
  {
    name = "lookup",
    description = "按 id, 中文名或英文名查卡牌的效果与实际机制, 可一次查多张.",
    parameters = object({ keys = { type = "array", items = { type = "string" }, minItems = 1 } }, { "keys" }),
  },
}

--- 会改变游戏状态的工具, 结果里要附上新的状态摘要.
M.ACTIONS = {
  start = true,
  select = true,
  skip = true,
  play = true,
  discard = true,
  buy = true,
  sell = true,
  reroll = true,
  next_round = true,
  pack = true,
  use = true,
  rearrange = true,
}

--- 只读的查询工具.
M.QUERIES = {
  docs_index = true,
  docs_read = true,
  docs_search = true,
  lookup = true,
}

local BY_NAME = {}
for _, def in ipairs(DEFS) do
  BY_NAME[def.name] = def
end

---@param opts {knowledge: boolean?}? knowledge=false 时不提供手册工具
---@return table[] chat completions 的 tools 数组
function M.definitions(opts)
  opts = opts or {}
  local out = {}
  for _, def in ipairs(DEFS) do
    if opts.knowledge ~= false or not M.QUERIES[def.name] then
      out[#out + 1] = {
        type = "function",
        ["function"] = { name = def.name, description = def.description, parameters = def.parameters },
      }
    end
  end
  return out
end

--- 把模型给出的工具调用转成 dispatcher 请求.
---@param name string
---@param args table? 已解码的 arguments
---@return string? method, table? params, string? reason_or_error
function M.to_request(name, args)
  if not BY_NAME[name] then
    return nil, nil, "没有这个工具: " .. tostring(name)
  end
  if args ~= nil and type(args) ~= "table" then
    return nil, nil, "参数必须是 JSON 对象"
  end
  local params = {}
  for k, v in pairs(args or {}) do
    params[k] = v
  end
  local reason = params.reason
  params.reason = nil
  if type(reason) ~= "string" or reason == "" then
    reason = nil
  end
  -- 空对象编码成 JSON 时要是 {}, 由调用方处理; 这里保证是表.
  return name, params, reason
end

return M
