--[[
工具调用的左侧弹窗文案 (bbcore 的运行时之一). 纯逻辑, 不依赖游戏, 有单测.

agent 每次调工具 (无论内置 loop 还是外部 just agent-call) 都在屏幕左边弹一条:
- 标题: 工具的中文名 (写死).
- 正文: 这次参数的含义 (写死模板 + 参数值), 例如出牌写 "手牌下标 0, 1", 购买写 "商店第 3 张".
- 没有参数 (或只带了 reason) 时: 正文改成该工具功能的一句话 (写死).

模板按方法名注册, 每个 mod 描述自己的端点: bbcore 这套在这里, balatrobot 的手册查询由它用 register 补上.
没有登记的方法不弹左侧 (只读的 health/gamestate 轮询会刷屏, 自动步骤与 notify 也各有各的显示).
标题也用它: 右侧 reason 通知的标题取自这里, 没登记模板但有标题的方法 (cash_out, menu 等) 也能对上中文名.
]]

local M = {}

-- 正文上限: 左侧弹窗是辅助信息, 太长会顶到屏幕下沿
local MAX_TEXT = 80

---@class BB.CallNote
---@field title string 工具的中文名 (左侧弹窗的标题, 右侧 reason 通知的标题也用它)
---@field hint string? 没有参数时说的那句话 (该工具做什么)
---@field format fun(params: table): string? 有参数时的正文; 返回 nil 时退回 hint

-- ==========================================================================
-- 取值小工具
-- ==========================================================================

---@param text string
---@param limit integer
---@return string UTF-8 安全截断
local function clip(text, limit)
  if #text <= limit then
    return text
  end
  local chars, count = {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    count = count + 1
    if count > limit - 3 then
      break
    end
    chars[#chars + 1] = ch
  end
  return table.concat(chars) .. "..."
end

---@param value any
---@return string 0 基下标写成 1 基的序数, 与游戏画面上的一致
local function ordinal(value)
  return tostring((tonumber(value) or 0) + 1)
end

---@param values integer[]?
---@return string 例如 "0, 1"
local function indices(values)
  local out = {}
  for _, v in ipairs(values or {}) do
    out[#out + 1] = tostring(v)
  end
  return table.concat(out, ", ")
end

---@param parts string[]
---@return string
local function join(parts)
  return table.concat(parts, ", ")
end

---@param params table
---@param key string
---@return boolean 参数里真的有这个键 (false 与 nil 不算, 它们是 "不要这项" 的意思)
local function given(params, key)
  return params[key] ~= nil and params[key] ~= false
end

-- ==========================================================================
-- bbcore 自己的端点
-- ==========================================================================

local NOTES = {
  start = {
    title = "开局",
    hint = "在主菜单开一局新游戏",
    format = function(params)
      local parts = {}
      if params.deck then
        parts[#parts + 1] = "牌组 " .. tostring(params.deck)
      end
      if params.stake then
        parts[#parts + 1] = "赌注 " .. tostring(params.stake)
      end
      if params.seed then
        parts[#parts + 1] = "种子 " .. tostring(params.seed)
      end
      return #parts > 0 and join(parts) or nil
    end,
  },
  select = {
    title = "选择盲注",
    hint = "进入当前盲注, 开始这一回合",
  },
  skip = {
    title = "跳过盲注",
    hint = "跳过当前盲注, 拿跳过奖励标签",
  },
  play = {
    title = "出牌",
    hint = "打出手牌",
    format = function(params)
      return given(params, "cards") and ("手牌下标 " .. indices(params.cards)) or nil
    end,
  },
  discard = {
    title = "弃牌",
    hint = "弃掉手牌并补牌",
    format = function(params)
      return given(params, "cards") and ("手牌下标 " .. indices(params.cards)) or nil
    end,
  },
  buy = {
    title = "购买",
    hint = "在商店买一件",
    format = function(params)
      local parts = {}
      if given(params, "card") then
        parts[#parts + 1] = "商店第 " .. ordinal(params.card) .. " 张"
      end
      if given(params, "voucher") then
        parts[#parts + 1] = "优惠券第 " .. ordinal(params.voucher) .. " 张"
      end
      if given(params, "pack") then
        parts[#parts + 1] = "补充包第 " .. ordinal(params.pack) .. " 个"
      end
      if #parts > 0 and params.use == true then
        parts[#parts + 1] = "买下立即使用"
      end
      return #parts > 0 and join(parts) or nil
    end,
  },
  sell = {
    title = "出售",
    hint = "卖掉小丑或消耗牌",
    format = function(params)
      local parts = {}
      if given(params, "joker") then
        parts[#parts + 1] = "小丑第 " .. ordinal(params.joker) .. " 张"
      end
      if given(params, "consumable") then
        parts[#parts + 1] = "消耗牌第 " .. ordinal(params.consumable) .. " 张"
      end
      return #parts > 0 and join(parts) or nil
    end,
  },
  reroll = {
    title = "刷新商店",
    hint = "花钱刷新商店",
  },
  next_round = {
    title = "离开商店",
    hint = "离开商店, 回到选择盲注",
  },
  pack = {
    title = "补充包",
    hint = "在打开的补充包里选牌或跳过",
    format = function(params)
      if params.skip == true then
        return "跳过卡包"
      end
      local parts = {}
      if given(params, "card") then
        parts[#parts + 1] = "卡包第 " .. ordinal(params.card) .. " 张"
      end
      if given(params, "targets") then
        parts[#parts + 1] = "目标手牌 " .. indices(params.targets)
      end
      return #parts > 0 and join(parts) or nil
    end,
  },
  use = {
    title = "使用消耗牌",
    hint = "使用消耗牌",
    format = function(params)
      local parts = {}
      if given(params, "consumable") then
        parts[#parts + 1] = "消耗牌第 " .. ordinal(params.consumable) .. " 张"
      end
      if given(params, "cards") then
        parts[#parts + 1] = "目标手牌 " .. indices(params.cards)
      end
      return #parts > 0 and join(parts) or nil
    end,
  },
  rearrange = {
    title = "调整顺序",
    hint = "调整顺序",
    format = function(params)
      local parts = {}
      if given(params, "hand") then
        parts[#parts + 1] = "手牌新顺序 " .. indices(params.hand)
      end
      if given(params, "jokers") then
        parts[#parts + 1] = "小丑新顺序 " .. indices(params.jokers)
      end
      if given(params, "consumables") then
        parts[#parts + 1] = "消耗牌新顺序 " .. indices(params.consumables)
      end
      return #parts > 0 and join(parts) or nil
    end,
  },
  dynamics = {
    title = "查动态值",
    hint = "查当前局会变的值: 认牌目标与成长值",
    format = function(params)
      local parts = {}
      if params.deck == "list" then
        parts[#parts + 1] = "摸牌堆列表"
      elseif params.deck == "stats" then
        parts[#parts + 1] = "摸牌堆统计"
      end
      if params.discard == "list" then
        parts[#parts + 1] = "弃牌堆列表"
      elseif params.discard == "stats" then
        parts[#parts + 1] = "弃牌堆统计"
      end
      if params.targets == false then
        parts[#parts + 1] = "不含认牌目标"
      end
      if params.cards == false then
        parts[#parts + 1] = "不含卡牌效果"
      end
      return #parts > 0 and join(parts) or nil
    end,
  },
}

-- 只有标题没有模板的方法: 它们不上左侧, 但右侧 reason 通知的标题要中文.
local TITLES = {
  cash_out = "结算",
  menu = "回主菜单",
  endless = "无尽模式",
  continue = "继续",
  notify = "解说",
}

-- ==========================================================================
-- 对外
-- ==========================================================================

--- 登记一个方法的文案 (别的 mod 描述自己的端点).
---@param method string
---@param note BB.CallNote
function M.register(method, note)
  NOTES[method] = note
end

--- 一次登记多个, 供 mod 加载时用.
---@param notes table<string, BB.CallNote>
function M.register_all(notes)
  for method, note in pairs(notes or {}) do
    NOTES[method] = note
  end
end

--- 工具的中文名: 没有模板的方法退回标题表, 都没有时用方法名本身.
---@param method string
---@return string
function M.title(method)
  local note = NOTES[method]
  return (note and note.title) or TITLES[method] or method
end

--- 一次调用的左侧弹窗内容. 没有登记的方法 (只读轮询, 自动步骤等) 返回 nil, 不弹.
---@param method string
---@param params table?
---@return {title: string, text: string}?
function M.note(method, params)
  local note = NOTES[method]
  if not note then
    return nil
  end
  local text
  if note.format then
    text = note.format(params or {})
  end
  text = text or note.hint
  if type(text) ~= "string" or text == "" then
    return nil
  end
  return { title = note.title, text = clip(text, MAX_TEXT) }
end

M.MAX_TEXT = MAX_TEXT
M.NOTES = NOTES

return M
