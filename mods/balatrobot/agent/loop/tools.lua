--[[
内置 agent 可用的工具 (chat completions 的 tools). 纯逻辑, 不依赖游戏.

没有直接从 openrpc.json 生成: 那份规格缺少 pack 等本仓库用到的方法, 描述是英文且偏长.
这里手写一份精简的中文定义, 参数与端点的 schema 一致; 端点参数有变化时要同步修改.

- 动作工具都带 reason (这一步的解说, 动作等它显示完再生效), 调用时从参数里拆出来交给 dispatcher.
  所以紧跟动作的解说直接写进 reason, notify 只用于不跟动作的观察, 对比与复盘.
- 只读的查询工具分两类: M.KNOWLEDGE 查静态手册 (知识库没打包时不提供), M.QUERIES 是全部只读工具 (结果按 JSON 交给模型).
- 不给模型的方法: gamestate (每次结果里已经带状态摘要), cash_out, continue, endless (loop 自动处理),
  menu, save, load, set, add, screenshot (与游玩无关或会破坏进度).
]]

local M = {}

local INDEX = { type = "integer", minimum = 0 }
local INDICES = { type = "array", items = { type = "integer", minimum = 0 }, minItems = 1 }
local REASON = {
  type = "string",
  maxLength = 200,
  description = "这一步的解说 (30~60 字): 做什么, 为什么, 估分. 先显示给观众, 读完后动作才生效, 不要再另发 notify 重复",
}
-- 出牌与弃牌的自我核对: 声明这几张分别是哪些牌, 组成什么牌型, 系统拿当前局面比对, 不符就不执行.
-- cards 要与 cards 参数同序等长, 写内部键 (C_K 是梅花 K); hand 写牌型内部键 (Two Pair).
local EXPECT = {
  type = "object",
  description = "这一步的自我核对. cards 与 cards 参数同序等长, 每项写内部键 (C_K 是梅花 K, H_9 是红桃 9);"
    .. " hand 写牌型内部键 (Two Pair, Pair, Flush 等). 系统会拿当前手牌核对, 不符则动作不执行并告诉你实际是什么.",
  properties = {
    cards = { type = "array", items = { type = "string" }, description = "按 cards 的顺序, 每张的内部键" },
    hand = { type = "string", description = "这手组成的牌型内部键" },
  },
}

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
    description = "跳过当前盲注 (只能跳过小盲注和大盲注), 拿到跳过奖励标签. 魅力 / 空灵这类标签会打开补充包, 返回时可能已经在卡包里, 接着用 pack 选.",
    parameters = object({ reason = REASON }, { "reason" }),
  },
  {
    name = "reroll_boss",
    description = "花 $10 重掷即将面对的 Boss 盲注. 需要已兑换导演剪辑版 (每个底注限 1 次) 或重构 (不限次数). 只在选择盲注时可用, 与商店的 reroll 不是同一件事. 待处理的开包标签会打开补充包, 返回时可能已经在卡包里.",
    parameters = object({ reason = REASON }, { "reason" }),
  },
  {
    name = "play",
    description = "打出手牌. cards 是手牌下标 (从 0 开始), 1~5 张. 建议带上 expect 声明这几张是什么牌, 组成什么牌型"
      .. " (系统核对, 说错会打回重选).",
    parameters = object({ cards = INDICES, expect = EXPECT, reason = REASON }, { "cards", "reason" }),
  },
  {
    name = "discard",
    description = "弃掉手牌并补牌, 消耗一次弃牌次数. cards 是手牌下标 (从 0 开始), 1~5 张. 可选 expect 同 play.",
    parameters = object({ cards = INDICES, expect = EXPECT, reason = REASON }, { "cards", "reason" }),
  },
  {
    name = "buy",
    description = "在商店购买. card, voucher, pack 三选一, 分别是商店牌, 优惠券, 补充包的下标."
      .. " 商店里的消耗牌可以加 use=true 买下立即使用, 不占消耗牌槽, 槽满时也能买 (星球牌等不用选牌的才行).",
    parameters = object({
      card = INDEX,
      voucher = INDEX,
      pack = INDEX,
      use = { type = "boolean" },
      reason = REASON,
    }, { "reason" }),
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
    description = "在打开的补充包里选一张 (card 为下标, 需要目标的塔罗等用 targets 给手牌下标), 或 skip=true 跳过. 5 选 2 要调用两次; 跳过标签开的包选完后回到选盲注, 不是商店.",
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
    description = "给观众发一条不跟动作的解说 (30~60 字): 观察局面, 逐项对比, 复盘. 立刻返回; 后面的操作会等它退去再生效,"
      .. " 不用自己等. 紧接着要做的那一步的解说写进动作的 reason, 不要在这里先说一遍.",
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
    description = "按 id, 中文名或英文名查卡牌的效果与实际机制, 可一次查多张. 会变的值 (成长值, 本回合认的花色点数)"
      .. " 在这份手册里是占位, 要看当前值用 dynamics.",
    parameters = object({ keys = { type = "array", items = { type = "string" }, minItems = 1 } }, { "keys" }),
  },
  {
    name = "dynamics",
    description = "查当前局的动态值: 本回合认的花色, 点数与牌型 (古老小丑, 偶像, 邮件回扣, 城堡, 待办清单),"
      .. " 盲注公牛要用的最常打出牌型, 以及持有小丑, 消耗牌和手牌里特殊牌的当前效果文本"
      .. " (成长值, 概率这类会变的值). 手册里这些位置是占位, 要当前值就查它, 不要猜."
      .. " 算同花, 顺子这类概率时传 deck 或 discard 要摸牌堆与弃牌堆 (本回合弃掉与打出的牌) 的张数与花色点数统计,"
      .. " 想看具体是哪几张就传 list.",
    parameters = object({
      deck = {
        type = "string",
        enum = { "stats", "list" },
        description = "摸牌堆: stats 给张数与按花色点数的统计, list 再加完整列表. 不传则不给",
      },
      discard = {
        type = "string",
        enum = { "stats", "list" },
        description = "弃牌堆 (本回合弃掉与打出的牌), 取值同上. 不传则不给",
      },
      targets = { type = "boolean", description = "是否要认牌目标, 默认要" },
      cards = { type = "boolean", description = "是否要持有卡与手牌的实时效果, 默认要" },
    }),
  },
}

--- 会改变游戏状态的工具, 结果里要附上新的状态摘要.
M.ACTIONS = {
  start = true,
  select = true,
  skip = true,
  reroll_boss = true,
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

--- 只读的查询工具: 结果按 JSON 交给模型.
M.QUERIES = {
  docs_index = true,
  docs_read = true,
  docs_search = true,
  lookup = true,
  dynamics = true,
}

--- 查手册的查询工具: 手册不可用时 (知识库没打包) 不提供给模型, dynamics 不依赖手册所以不在其中.
M.KNOWLEDGE = {
  docs_index = true,
  docs_read = true,
  docs_search = true,
  lookup = true,
}

local BY_NAME = {}
for _, def in ipairs(DEFS) do
  BY_NAME[def.name] = def
end

---@param opts {knowledge: boolean?}? knowledge=false 时不提供手册工具 (dynamics 与手册无关, 照常提供)
---@return table[] chat completions 的 tools 数组
function M.proposal_definition()
  local variants = {}
  for _, def in ipairs(DEFS) do
    if M.ACTIONS[def.name] then
      local props = {}
      for key, value in pairs(def.parameters.properties or {}) do if key ~= "reason" then props[key] = value end end
      local required = {}
      for _, key in ipairs(def.parameters.required or {}) do if key ~= "reason" then required[#required + 1] = key end end
      local params = object(props, required)
      params.additionalProperties = false
      local schema = object({
        method = { type = "string", enum = { def.name }, description = def.description },
        params = params, reason = REASON,
      }, { "method", "params", "reason" })
      schema.additionalProperties = false
      variants[#variants + 1] = schema
    end
  end
  return { type = "function", ["function"] = {
    name = "propose_actions",
    description = "提出 1 至 4 个互斥候选动作, 每项只做一步. Decision 选择或批准后才执行, 查询工具仍可直接调用.",
    parameters = object({ candidates = { type = "array", minItems = 1, maxItems = 4, items = { anyOf = variants } } }, { "candidates" }),
  } }
end

function M.definitions(opts)
  opts = opts or {}
  local out = {}
  for _, def in ipairs(DEFS) do
    if (not opts.hybrid or not M.ACTIONS[def.name]) and (opts.knowledge ~= false or not M.KNOWLEDGE[def.name]) then
      out[#out + 1] = {
        type = "function",
        ["function"] = { name = def.name, description = def.description, parameters = def.parameters },
      }
    end
  end
  if opts.hybrid then out[#out + 1] = M.proposal_definition() end
  return out
end

--- 把模型给出的工具调用转成 dispatcher 请求.
--- reason 与 expect 都是 agent 侧的元数据, 端点不认识它们, 所以在这里就拆出来:
--- reason 交给调用方显示, expect 交给调用方核对 (端点只该收到游戏认识的字段).
---@param name string
---@param args table? 已解码的 arguments
---@return string? method, table? params, string? reason_or_error, table? expect
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
  local expect = params.expect
  params.expect = nil
  if type(expect) ~= "table" then
    expect = nil
  end
  -- 空对象编码成 JSON 时要是 {}, 由调用方处理; 这里保证是表.
  return name, params, reason, expect
end

return M
