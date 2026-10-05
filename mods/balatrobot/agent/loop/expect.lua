--[[
出牌与弃牌的 expect 校验: 模型声明"这几张是哪些牌, 组成什么牌型", 这里拿当前局面核对.

纯逻辑, 不依赖游戏, 单测直接加载. 为什么要有它:
模型只发下标 (cards) 和一段给观众的解说 (reason), 两者互相独立. 下标由游戏裁判, 一定准;
reason 不会被验证. 于是"嘴上说打两对 J+5, 手上选中 J,J,9,5 (只有一个对子)"这类错位
没有任何环节会发现, 而且它自己估分 60, 实际也得 60, 对上了就以为没错, 直到下一轮复盘才察觉.
expect 把"模型以为的结果"变成可校验的结构化字段, 由这里当场比对, 不一致就拒绝执行.

两类断言 (都可选, 都不给就跳过):
- cards: 与 cards 下标同序等长, 正面牌写内部键 (C_K 是梅花 K, H_9 是红桃 9), 背面牌必须写小写 unknown.
- hand:  牌型内部键 (Two Pair, Pair, Flush ...), 与 gs.hands 的键一致.

背面牌只核对是否声明 unknown, 不读取或反馈隐藏身份, 猜测具体牌值即使猜中也拒绝.
选牌含背面或非标准牌, 或张数不合法时 preview 给不出牌型, 跳过牌型断言.
]]

local M = {}

-- 花色与牌型的中文名, 只用于反馈文案 (与 summary.lua 的写法保持一致).
local SUIT = { H = "红桃", D = "方片", C = "梅花", S = "黑桃" }
local RANK = { T = "10", J = "J", Q = "Q", K = "K", A = "A" }
local HAND = {
  ["High Card"] = "高牌", Pair = "对子", ["Two Pair"] = "两对", ["Three of a Kind"] = "三条",
  Straight = "顺子", Flush = "同花", ["Full House"] = "葫芦", ["Four of a Kind"] = "四条",
  ["Straight Flush"] = "同花顺", ["Five of a Kind"] = "五条", ["Flush House"] = "同花葫芦",
  ["Flush Five"] = "同花五条",
}

--- 内部键转中文读法 (C_K -> 梅花K); 认不出来就原样返回.
---@param key any
---@return string
function M.readable(key)
  local text = tostring(key)
  local suit, rank = text:match("^([HDCS])_(.+)$")
  if not suit then
    return text
  end
  return (SUIT[suit] or suit) .. (RANK[rank] or rank)
end

--- 牌型内部键转中文 (Two Pair -> 两对); 认不出来就原样返回.
---@param name any
---@return string
function M.hand_zh(name)
  local text = tostring(name)
  return (HAND[text] or text)
end

--- 取手牌里某下标的内部键. 下标越界或卡牌缺失时返回 nil.
---@param gs table
---@param index any
---@return string?
---@return boolean hidden 是否为背面牌 (身份未知, 不参与比对)
function M.card_key(gs, index)
  if type(index) ~= "number" then
    return nil, false
  end
  local cards = gs and gs.hand and gs.hand.cards
  if type(cards) ~= "table" then
    return nil, false
  end
  local card = cards[index + 1]
  if type(card) ~= "table" then
    return nil, false
  end
  local hidden = card.state and card.state.hidden == true
  if hidden then return nil, true end
  if type(card.key) == "string" then
    return card.key, hidden
  end
  -- 退路: 没有 key 时按花色点数拼, 与游戏内部键的写法一致.
  local value = card.value
  if type(value) == "table" and type(value.suit) == "string" and value.rank ~= nil then
    return tostring(value.suit) .. "_" .. tostring(value.rank), hidden
  end
  return nil, hidden
end

--- 校验 expect. 返回 nil 表示通过, 否则返回给模型的拒绝说明.
---
--- expect 形如 { cards = { "C_J", "D_J" }, hand = "Two Pair" }, 两项都可缺省.
---@param gs table 当前 gamestate
---@param indices integer[] 实际要操作的下标
---@param expect table? 模型声明的预期
---@param preview fun(gs: table, indices: integer[]): table? 牌型推算 (hand_options.preview)
---@return string? reason 拒绝说明, 通过时为 nil
function M.check(gs, indices, expect, preview)
  if type(expect) ~= "table" then
    return nil
  end
  local declared = expect.cards
  if declared ~= nil then
    if type(declared) ~= "table" then
      return "未执行: expect.cards 必须是数组, 正面牌写内部键 (例如 C_K 是梅花 K), 背面牌写 unknown."
    end
    if #declared ~= #indices then
      return string.format(
        "未执行: expect.cards 有 %d 项, 但 cards 有 %d 个下标, 两者必须同序等长.",
        #declared, #indices
      )
    end
    local wrong = {}
    for i, key in ipairs(declared) do
      local actual, hidden = M.card_key(gs, indices[i])
      if hidden then
        if key ~= "unknown" then
          wrong[#wrong + 1] = string.format("下标 %d 是背面牌, expect.cards 对应项必须写 unknown, 不得猜测花色点数", indices[i])
        end
      elseif actual == nil then
        wrong[#wrong + 1] = string.format("下标 %d 取不到牌", indices[i])
      elseif type(key) ~= "string" or key ~= actual then
        wrong[#wrong + 1] = string.format(
          "下标 %d 实际是 %s (%s), 声明的是 %s (%s)",
          indices[i], actual, M.readable(actual), tostring(key), M.readable(key)
        )
      end
    end
    if #wrong > 0 then
      return "未执行: 选中的牌与 expect.cards 不符.\n" .. table.concat(wrong, "\n")
        .. "\n请按摘要里的下标重新核对, 改正 cards 或 expect 后重试."
    end
  end

  local want_hand = expect.hand
  if want_hand ~= nil then
    if type(want_hand) ~= "string" then
      return "未执行: expect.hand 要写牌型的内部键字符串 (例如 Two Pair)."
    end
    if not preview then
      return nil -- 没有推算能力时不拦, 不把不可判定当成错.
    end
    local got = preview(gs, indices)
    if type(got) == "table" and got.known == false then
      return nil -- 含背面或非标准牌, 张数不合法等, 算不出来就放行.
    end
    local actual = type(got) == "table" and got.hand or nil
    if actual ~= nil and actual ~= want_hand then
      return string.format(
        "未执行: 这手实际是 %s (%s), 不是声明中的 %s (%s).\n%s",
        M.hand_zh(actual), actual, M.hand_zh(want_hand), want_hand,
        "请按实际牌型改正 expect, 或改选能组成该牌型的牌."
      )
    end
  end
  return nil
end

M.SUIT = SUIT
M.HAND = HAND

return M
