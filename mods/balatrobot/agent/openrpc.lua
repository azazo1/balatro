-- 把本仓库新增的接口写进 rpc.discover 返回的 OpenRPC 文档: notify 等方法, 手册查询方法, 以及各方法的可选 reason 参数.

local json = require("json")

local M = {}

local REASON = {
  name = "reason",
  description = "Optional short decision message, shown in game and written to the recording timeline",
  required = false,
  schema = { type = "string", maxLength = 200 },
}

local NOTIFY = {
  name = "notify",
  summary = "Show an agent message in game",
  description = "Shows a short message in the vanilla notification style. Works in any game state. "
    .. "By default returns after the estimated reading time, so consecutive calls show messages one by one.",
  params = {
    {
      name = "message",
      required = true,
      description = "Shown in up to 12 lines: about 180 Chinese characters or 300 ASCII characters, longer text is cut off",
      schema = { type = "string", minLength = 1, maxLength = 300 },
    },
    { name = "title", required = false, schema = { type = "string", maxLength = 40 } },
    {
      name = "duration",
      required = false,
      description = "Reading time in seconds, estimated from the text length when omitted",
      schema = { type = "number", exclusiveMinimum = 0, maximum = 30 },
    },
    {
      name = "wait",
      required = false,
      description = "Return after the reading time, defaults to true",
      schema = { type = "boolean" },
    },
  },
  result = {
    name = "notify",
    schema = {
      type = "object",
      properties = { success = { type = "boolean", const = true } },
      required = { "success" },
    },
  },
  errors = {},
}

local ENDLESS = {
  name = "endless",
  summary = "Continue in endless mode from the win screen",
  description = "After beating the ante 8 boss the win screen opens and other actions are rejected. "
    .. "Closes it like the Endless Mode button, then returns once round evaluation shows cash_out.",
  params = {},
  result = {
    name = "gamestate",
    description = "Game state in ROUND_EVAL, ready for cash_out",
    schema = { ["$ref"] = "#/components/schemas/GameState" },
  },
  errors = { { ["$ref"] = "#/components/errors/InvalidState" } },
}

local CONTINUE = {
  name = "continue",
  summary = "Close the unlock notification",
  description = "Closes the unlock notification like its Continue button. If an earlier request returned early "
    .. "because the notification opened, waits for that request and returns its result; otherwise returns the current state.",
  params = {},
  result = {
    name = "gamestate",
    description = "Result of the interrupted request, or the current game state",
    schema = { ["$ref"] = "#/components/schemas/GameState" },
  },
  errors = { { ["$ref"] = "#/components/errors/InvalidState" } },
}

-- 手册查询: 4 个只读方法, 任何状态与弹窗期间都可调用. 实现见 agent/knowledge/.
local KNOWLEDGE_TAG = { name = "knowledge", description = "游戏手册查询 (docs/game/ 的规则, 机制与卡牌目录), 只读" }
local KNOWLEDGE_ERRORS = {
  { ["$ref"] = "#/components/errors/BadRequest" },
  { ["$ref"] = "#/components/errors/InternalError" },
}
local STRINGS = { type = "array", items = { type = "string" } }

-- 当前局的动态值: 手册是版本快照, 会随局面变化的量在里面只能是占位, 这个方法给出此刻的真实值.
local DYNAMIC_CARD = {
  type = "object",
  properties = {
    index = { type = "integer", description = "在该区域里的下标, 从 0 开始, 与 gamestate 一致" },
    key = { type = "string", description = "卡牌 key, 例如 j_ramen" },
    name = { type = "string", description = "卡牌名 (游戏语言)" },
    effect = { type = "string", description = "当前效果文本 (游戏语言), 成长值与概率已代入" },
  },
  required = { "index", "name" },
}

local DYNAMICS = {
  name = "dynamics",
  summary = "当前局的动态值 (本回合认的牌, 成长值, 摸牌堆与弃牌堆)",
  description = "手册 (docs_read 与 lookup) 是版本快照, 里面会变的量只能写成占位, 例如古老小丑的 [本回合目标花色], "
    .. "城堡的 (当前为+[当前筹码]筹码). 这个方法返回此刻的真实值: targets 是每回合重抽的认牌目标 (古老小丑的花色, "
    .. "偶像的花色与点数, 邮件回扣的点数, 城堡的花色, 待办清单的牌型), most_played_poker_hand 是盲注公牛要用的牌型, "
    .. "jokers, consumables 与 hand 是持有卡与手牌里特殊牌的效果文本, 取游戏自己生成的那一份, 成长值与概率都已代入. "
    .. "传 deck 或 discard 还能拿到摸牌堆与弃牌堆 (弃牌堆里是本回合弃掉与打出的牌) 的张数, 按花色点数的统计与完整列表, "
    .. "算同花与顺子的概率要用它; 这两项默认不给. 只读, 任何阶段都能调用, 不算 agent 活动, 也不写进回放文件.",
  params = {
    {
      name = "targets",
      required = false,
      description = "给认牌目标, 默认 true; 传 false 时结果里没有 targets 与 most_played_poker_hand",
      schema = { type = "boolean" },
    },
    {
      name = "cards",
      required = false,
      description = "给持有卡与手牌特殊牌的实时效果, 默认 true; 传 false 时结果里没有 jokers, consumables 与 hand",
      schema = { type = "boolean" },
    },
    {
      name = "deck",
      required = false,
      description = "摸牌堆的详细程度, 不传时结果里没有 deck",
      schema = { type = "string", enum = { "stats", "list" } },
    },
    {
      name = "discard",
      required = false,
      description = "弃牌堆 (本回合弃掉与打出的牌) 的详细程度, 不传时结果里没有 discard",
      schema = { type = "string", enum = { "stats", "list" } },
    },
  },
  result = {
    name = "dynamics",
    schema = {
      type = "object",
      properties = {
        targets = {
          type = "array",
          description = "每回合重抽的认牌目标, 没有的项不出现",
          items = {
            type = "object",
            properties = {
              key = { type = "string", description = "认牌的牌, 例如 j_ancient" },
              name = { type = "string", description = "该牌的名字 (游戏语言)" },
              suit = { type = "string", description = "花色枚举 H/D/C/S" },
              suit_name = { type = "string", description = "花色名 (游戏语言)" },
              rank = { type = "string", description = "点数枚举, 例如 Q" },
              rank_name = { type = "string", description = "点数名 (游戏语言)" },
              poker_hand = { type = "string", description = "牌型英文名, 例如 Two Pair" },
              poker_hand_name = { type = "string", description = "牌型名 (游戏语言)" },
            },
            required = { "key" },
          },
        },
        most_played_poker_hand = {
          type = "object",
          description = "本局最常打出的牌型, 盲注公牛用它 (还没打过牌时不出现)",
          properties = {
            poker_hand = { type = "string" },
            poker_hand_name = { type = "string" },
          },
        },
        jokers = { type = "array", items = DYNAMIC_CARD },
        consumables = { type = "array", items = DYNAMIC_CARD },
        hand = {
          type = "array",
          description = "手牌里带增强, 版本或蜡封的牌",
          items = DYNAMIC_CARD,
        },
        deck = { ["$ref"] = "#/components/schemas/DynamicPile" },
        discard = {
          allOf = { { ["$ref"] = "#/components/schemas/DynamicPile" } },
          description = "弃牌堆: 本回合弃掉与打出的牌",
        },
      },
    },
  },
  errors = { { ["$ref"] = "#/components/errors/BadRequest" } },
}

-- 摸牌堆或弃牌堆的一份快照.
local DYNAMIC_PILE = {
  type = "object",
  properties = {
    count = { type = "integer", description = "这一堆的张数" },
    by_suit = {
      type = "object",
      description = "按花色的张数, 键是游戏语言的花色名",
      additionalProperties = { type = "integer" },
    },
    by_rank = {
      type = "object",
      description = "按点数的张数, 键是游戏语言的点数名",
      additionalProperties = { type = "integer" },
    },
    cards = {
      type = "array",
      description = "完整列表 (只在 detail 为 list 时给, 超过 60 张时截断)",
      items = {
        type = "object",
        properties = {
          key = { type = "string", description = "例如 H_K" },
          suit = { type = "string", description = "花色枚举 H/D/C/S" },
          suit_name = { type = "string" },
          rank = { type = "string", description = "点数枚举, 例如 Q" },
          rank_name = { type = "string" },
        },
      },
    },
    truncated = { type = "boolean", description = "列表被截断时为 true" },
  },
  required = { "count", "by_suit", "by_rank" },
}

local DOCS_INDEX = {
  name = "docs_index",
  summary = "列出游戏手册的文件与按决策查阅表",
  description = "游戏手册是本版本 (1.0.1o) 的规则, 机制与卡牌目录, 以源码为准. 查规则前先调用 docs_index 看目录: "
    .. "返回每个文件的路径, 标题和行数, 以及 README 的 \"按决策查阅\" 表 (guide), 按当前要做的决策挑文件读. "
    .. "手册不存在 (未经打包直接运行 game/) 时返回 InternalError.",
  tags = { KNOWLEDGE_TAG },
  params = {},
  result = {
    name = "docs_index",
    schema = {
      type = "object",
      properties = {
        files = {
          type = "array",
          items = {
            type = "object",
            properties = {
              path = { type = "string", description = "相对手册根目录的路径, 例如 rules/scoring.md" },
              title = { type = "string", description = "一级标题" },
              lines = { type = "integer" },
            },
            required = { "path", "title", "lines" },
          },
        },
        guide = { type = "string", description = "README 的 \"按决策查阅\" 表 (markdown)" },
        hint = { type = "string", description = "用法提示" },
      },
      required = { "files" },
    },
  },
  errors = { { ["$ref"] = "#/components/errors/InternalError" } },
}

local DOCS_READ = {
  name = "docs_read",
  summary = "读取手册文件, 带行号, 按章节或分页",
  description = "读取一个手册文件, 内容每行形如 \"行号: 文本\". 超过 300 行的大文件不带 section 或 offset 时只返回大纲 "
    .. "(outline, 每行 \"行号: # 标题 {#锚点}\"), 先看大纲再按 section 读需要的一节. section 可以写标题文字 (全文或唯一的子串), "
    .. "也可以写锚点 id, 例如 cards/jokers.md 的 j-blueprint; path 也可以直接写成 \"cards/jokers.md#j-blueprint\". "
    .. "单次最多 200 行或约 8KB, 没读完时返回 next_offset, 带同样的 path/section 和 offset=next_offset 接着读. "
    .. "内容里的 [文字](<路径#锚点>) 是手册内的链接, 路径可直接传给 docs_read; \"文字 (路径)\" 形式的是手册以外的源码位置, 读不到. "
    .. "按卡牌 id 或名称查询时优先用 lookup.",
  tags = { KNOWLEDGE_TAG },
  params = {
    {
      name = "path",
      required = true,
      description = "相对手册根目录的路径 (来自 docs_index 或文中链接), 可带 #锚点. 不接受 .. 与绝对路径",
      schema = { type = "string", minLength = 1 },
    },
    {
      name = "section",
      required = false,
      description = "标题文字或锚点 id. 子串匹配到多个标题时报错并列出候选",
      schema = { type = "string", minLength = 1 },
    },
    {
      name = "offset",
      required = false,
      description = "起始行号, 从 1 开始; 带 section 时须在该节范围内",
      schema = { type = "integer", minimum = 1 },
    },
    {
      name = "limit",
      required = false,
      description = "最多读取的行数, 默认且最多 200",
      schema = { type = "integer", minimum = 1, maximum = 200 },
    },
  },
  result = {
    name = "docs_read",
    schema = {
      type = "object",
      properties = {
        path = { type = "string" },
        title = { type = "string" },
        total_lines = { type = "integer" },
        section = {
          type = "object",
          description = "命中的章节 (带 section 时)",
          properties = {
            title = { type = "string" },
            line = { type = "integer" },
            end_line = { type = "integer" },
          },
        },
        outline = { type = "string", description = "只返回大纲时出现, 此时没有 content" },
        hint = { type = "string" },
        start_line = { type = "integer" },
        end_line = { type = "integer" },
        content = { type = "string", description = "带行号的内容" },
        next_offset = { type = "integer", description = "没读完时下一次的 offset" },
      },
      required = { "path", "title", "total_lines" },
    },
  },
  errors = KNOWLEDGE_ERRORS,
}

local DOCS_SEARCH = {
  name = "docs_search",
  summary = "在手册里搜索子串",
  description = "纯子串搜索, 不区分英文大小写 (不是正则, 不分词). 结果每条形如 \"路径:行号: 内容\", 过长的行只保留命中附近. "
    .. "找到位置后用 docs_read 的 offset 读上下文. 可用 path 限定文件或目录 (例如 mechanics). "
    .. "truncated 为 true 表示还有更多命中, 缩小 path 或换更具体的词.",
  tags = { KNOWLEDGE_TAG },
  params = {
    { name = "query", required = true, schema = { type = "string", minLength = 1 } },
    {
      name = "path",
      required = false,
      description = "限定文件或目录, 相对手册根目录",
      schema = { type = "string", minLength = 1 },
    },
    {
      name = "limit",
      required = false,
      description = "最多返回的条数, 默认 20, 最多 100",
      schema = { type = "integer", minimum = 1, maximum = 100 },
    },
  },
  result = {
    name = "docs_search",
    schema = {
      type = "object",
      properties = {
        query = { type = "string" },
        matches = STRINGS,
        total = { type = "integer", description = "命中总数" },
        truncated = { type = "boolean" },
      },
      required = { "query", "matches", "total", "truncated" },
    },
  },
  errors = KNOWLEDGE_ERRORS,
}

local LOOKUP = {
  name = "lookup",
  summary = "按 id 或名称查卡牌与对象",
  description = "按内部 id (例如 j_blueprint, c_fool, v_overstock_norm), 中文名或英文名 (不区分大小写) 查小丑, 消耗牌, 优惠券, "
    .. "牌组, 标签, 补充包, 盲注, 增强, 版本, 蜡封, 赌注, 贴纸和挑战. 每个 key 返回精简记录: 名称, 类别, 稀有度 (小丑), 基价, "
    .. "中文卡面效果, 能否被蓝图复制 (小丑), 目录位置 doc (可传给 docs_read), 以及 mechanics/ 文档中提到这个 id 的行. "
    .. "卡面效果不一定完整反映实现, 以 mechanics 行为准; 方括号是需要从当前局读取的动态值. "
    .. "同名对象 (例如 4 个外观不同的秘术包) 都会返回; 找不到时 cards 为空并给出候选. 一次最多 30 个 key.",
  tags = { KNOWLEDGE_TAG },
  params = {
    {
      name = "keys",
      required = true,
      description = "id, 中文名或英文名的数组",
      schema = { type = "array", items = { type = "string" }, minItems = 1, maxItems = 30 },
    },
  },
  result = {
    name = "lookup",
    schema = {
      type = "object",
      properties = {
        results = {
          type = "array",
          description = "与 keys 一一对应",
          items = {
            type = "object",
            properties = {
              key = { type = "string" },
              cards = {
                type = "array",
                items = {
                  type = "object",
                  properties = {
                    id = { type = "string" },
                    name_zh = { type = "string" },
                    name_en = { type = "string" },
                    category = { type = "string", description = "Joker, Tarot, Planet, Spectral, Voucher, Back, Tag, Booster, Blind, Enhanced, Edition, Seal, Stake, Other, Challenge" },
                    rarity = { type = "string", enum = { "普通", "罕见", "稀有", "传奇" }, description = "只有小丑有" },
                    base_cost = { type = "integer", description = "原型基价, 不是实际售价" },
                    effect_zh = { type = "string", description = "中文卡面效果, 连成一行" },
                    blueprint_compat = { type = "boolean", description = "只有小丑有" },
                    doc = { type = "string", description = "目录中的位置, 例如 cards/jokers.md#j-blueprint" },
                    mechanics = STRINGS,
                  },
                  required = { "id", "category" },
                },
              },
              candidates = { type = "array", items = { type = "string" }, description = "找不到时名称相近的候选" },
            },
            required = { "key", "cards" },
          },
        },
      },
      required = { "results" },
    },
  },
  errors = KNOWLEDGE_ERRORS,
}

-- 没有弹窗时字段不出现 (Lua 的 nil 不会被编码).
local OVERLAY = {
  type = "string",
  enum = { "unlock", "win", "other" },
  description = "Overlay menu that is open, absent when none. 'unlock': unlock notification, call continue. "
    .. "'win': win screen, call endless or menu. 'other': a menu opened in game. "
    .. "Most actions are rejected while it is set, and a waiting request returns early when one opens",
}

---@param spec_text string
---@param passive table<string, boolean>
---@return string
function M.extend(spec_text, passive)
  local ok, spec = pcall(json.decode, spec_text)
  if not ok or type(spec) ~= "table" or type(spec.methods) ~= "table" then
    return spec_text
  end
  for _, method in ipairs(spec.methods) do
    if not passive[method.name] and type(method.params) == "table" then
      table.insert(method.params, REASON)
    end
  end
  table.insert(spec.methods, NOTIFY)
  table.insert(spec.methods, ENDLESS)
  table.insert(spec.methods, CONTINUE)
  table.insert(spec.methods, DOCS_INDEX)
  table.insert(spec.methods, DOCS_READ)
  table.insert(spec.methods, DOCS_SEARCH)
  table.insert(spec.methods, LOOKUP)
  table.insert(spec.methods, DYNAMICS)
  local schemas = spec.components and spec.components.schemas
  if schemas and schemas.GameState and schemas.GameState.properties then
    schemas.GameState.properties.overlay = OVERLAY
  end
  if schemas then
    schemas.DynamicPile = DYNAMIC_PILE
  end
  local encoded_ok, encoded = pcall(json.encode, spec)
  return encoded_ok and encoded or spec_text
end

return M
