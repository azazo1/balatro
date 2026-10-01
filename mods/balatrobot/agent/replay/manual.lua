--[[
把人手动的操作换算成回放步骤.

人点的按钮和 agent 的接口走同一批游戏函数 (G.FUNCS.play_cards_from_highlighted 等), 这里给这些函数
套一层: 此刻没有 agent 请求在处理 (activity.inflight 为空) 时, 这次调用就是人点的, 按调用时的
选中状态换算成接口参数 (0 起的下标), 交给 log 记成一步. 回放时播放器照常调用对应接口.

拖动排序不经过任何按钮函数: 每帧在没有拖动时记下手牌, 小丑, 消耗牌的顺序, 拖动结束后顺序变了
就记一步 reorder. 它不走接口 (rearrange 只在少数状态可用, 而人在选盲注时也能拖小丑), 回放时由
apply_local 直接重排.

纯逻辑部分 (下标换算, 顺序比较) 不碰 G, 单测直接加载.
]]

local M = {}

-- 回放时在本地重做, 不走接口的方法: press (照人点按钮的方式调用按钮函数), reorder (拖动排序).
M.LOCAL = { press = true, reorder = true }

-- press 能调用的按钮函数. 回放文件是外部输入, 不在名单里的不调用.
local PRESS_FUNCS = {
  buy_from_shop = true,
  use_card = true,
  sell_card = true,
  skip_booster = true,
  reroll_boss = true,
  sort_hand_suit = true,
  sort_hand_value = true,
}

-- press 能指向的区域 (G 上的字段).
local PRESS_AREAS = { shop_jokers = true, pack_cards = true, consumeables = true, jokers = true }

-- 拖动排序检测的区域: 回放步骤里的名字 -> G 上的字段.
M.AREAS = { hand = "hand", jokers = "jokers", consumables = "consumeables" }

--- card 在 cards 里的 0 起下标, 不在时返回 nil.
---@param cards table[]
---@param card table
---@return integer?
function M.index_of(cards, card)
  for i, c in ipairs(cards or {}) do
    if c == card then
      return i - 1
    end
  end
  return nil
end

--- 选中的牌在 cards 里的 0 起下标, 升序. 有选中的牌不在 cards 里时返回 nil.
---@param cards table[]
---@param highlighted table[]
---@return integer[]?
function M.highlighted_indices(cards, highlighted)
  local out = {}
  for _, card in ipairs(highlighted or {}) do
    local index = M.index_of(cards, card)
    if not index then
      return nil
    end
    out[#out + 1] = index
  end
  table.sort(out)
  return out
end

--- before 与 after 是同一批牌的两种顺序时, 返回 rearrange 接口的参数: 第 i 个元素是新位置 i 上的牌
--- 原来的 0 起下标. 牌不同 (有增减) 或顺序没变时返回 nil.
---@param before table[]
---@param after table[]
---@return integer[]?
function M.permutation(before, after)
  if #before ~= #after then
    return nil
  end
  local changed = false
  local order = {}
  for i, card in ipairs(after) do
    local old = M.index_of(before, card)
    if not old then
      return nil
    end
    order[i] = old
    changed = changed or old ~= i - 1
  end
  return changed and order or nil
end

--- 按 order (permutation 的结果) 重排 cards, 返回新数组. order 不是 cards 的排列时返回 nil.
---@param cards table[]
---@param order integer[]
---@return table[]?
function M.apply_order(cards, order)
  if type(order) ~= "table" or #order ~= #cards then
    return nil
  end
  local seen, out = {}, {}
  for i, old in ipairs(order) do
    if type(old) ~= "number" or seen[old] or not cards[old + 1] then
      return nil
    end
    seen[old] = true
    out[i] = cards[old + 1]
  end
  return out
end

--- 拖动排序的检测. 每帧调用 tick: 没有拖动时记下各区域的顺序, 拖动结束的那一帧比较.
--- 只看本区域里的牌换了位置; 拖到别的区域 (例如卖掉) 时牌数变了, 不算排序.
---@param areas table<string, table[]?> 区域名 -> 当前的牌 (取不到时为 nil)
---@param dragging boolean 此刻有没有牌被拖着
---@param state table tracker 自己的状态, 首次传 {}
---@return {area: string, order: integer[]}[] changes 这一帧结束的拖动带来的顺序变化
function M.track(areas, dragging, state)
  local changes = {}
  if dragging then
    state.dragging = true
    return changes
  end
  local was_dragging = state.dragging
  state.dragging = false
  state.orders = state.orders or {}
  for name, cards in pairs(areas) do
    local before = state.orders[name]
    if was_dragging and before and cards then
      local order = M.permutation(before, cards)
      if order then
        changes[#changes + 1] = { area = name, order = order }
      end
    end
    local copy = {}
    for i, card in ipairs(cards or {}) do
      copy[i] = card
    end
    state.orders[name] = copy
  end
  table.sort(changes, function(a, b)
    return a.area < b.area
  end)
  return changes
end

-- 以下与游戏相关, 由 install 装上.

local deps = nil -- record
local drag_state = {}
local clicking = 0 -- 正在执行的 UIElement:click 层数
local depth = 0 -- 正在执行的按钮函数层数: 按钮函数里再调别的按钮函数只记最外层

--- 这次按钮函数调用是不是人点的: 在 UIElement:click 里面, 且不在另一个按钮函数里面.
---
--- 鼠标, 触摸和手柄的按钮都经过 UIElement:click (game/engine/ui.lua). 接口传的是假按钮, 直接调用
--- G.FUNCS; 游戏自己的调用 (标签开包, The Hook 弃牌, 读档重开卡包, 买了直接用里的 use_card) 发生在
--- 事件里, 都不经过它. 只看 "agent 没在处理请求" 不够: 弹窗出现时请求会先返回, 它的后续事件还会调用
--- 这些函数.
---@return boolean
local function by_hand()
  return deps ~= nil and clicking > 0 and depth == 0
end

local function record(method, params)
  local ok, err = pcall(deps.record, { method = method, params = params })
  if not ok then
    sendWarnMessage("记录手动操作失败: " .. tostring(err), "BB.AGENT.REPLAY")
  end
end

--- 给 G.FUNCS[name] 套一层: 人点时先按调用前的状态换算出步骤 (换算返回 nil 时不记), 再照常执行.
---@param name string
---@param translate fun(e: table?, ...): (string?, table?) 返回 method 与 params, 参数与按钮函数相同
local function hook(name, translate)
  local original = G.FUNCS[name]
  if type(original) ~= "function" then
    sendWarnMessage("没有按钮函数 " .. name .. ", 这类手动操作不会记进回放", "BB.AGENT.REPLAY")
    return
  end
  G.FUNCS[name] = function(e, ...)
    if by_hand() then
      local ok, method, params = pcall(translate, e, ...)
      if ok and method then
        record(method, params)
      elseif not ok then
        sendWarnMessage(string.format("换算手动操作 %s 失败: %s", name, tostring(method)), "BB.AGENT.REPLAY")
      end
    end
    -- 不包 pcall: 按钮函数出错时游戏照常崩溃并带完整的调用栈, 那时层数错了也无所谓.
    depth = depth + 1
    local a, b, c = original(e, ...)
    depth = depth - 1
    return a, b, c
  end
end

--- 出牌与弃牌: 选中的牌在手里的位置.
local function hand_cards(method)
  return function()
    local indices = M.highlighted_indices(G.hand and G.hand.cards, G.hand and G.hand.highlighted)
    if not indices or #indices == 0 then
      return nil
    end
    return method, { cards = indices }
  end
end

local function plain(method)
  return function()
    return method, nil
  end
end

--- 手里选中的牌 (消耗牌与卡包里选牌的目标), 没有选中时为 nil.
---@return integer[]?
local function targets()
  local indices = M.highlighted_indices(G.hand and G.hand.cards, G.hand and G.hand.highlighted)
  return indices and #indices > 0 and indices or nil
end

--- 卡在区域里的下标, 区域不存在或卡不在里面时为 nil.
---@param field string G 上的区域字段
---@param card table
---@return integer?
local function index_in(field, card)
  local area = G[field]
  return area and card and card.area == area and M.index_of(area.cards, card) or nil
end

--- 本地步骤 press: 回放时与人点按钮一样调用 fn, 按钮指向 area 的第 index 张牌.
---
--- 这些操作有接口, 但接口比人的操作限制多, 照接口回放会在原局成功的地方失败:
--- - use, sell 只允许在出牌和商店时用, 人在选盲注, 结算, 开卡包时也能用和卖.
--- - buy 的槽位检查不算负片多出的一格; "买了直接用" 没有接口.
--- - pack 选完等的是回到商店, 标签送的卡包关上后回到选盲注, 等不到.
--- - use 对 Aura 忽略传入的目标, 用的是当时已经选中的牌.
---@param fn string G.FUNCS 里的函数名
---@param field string? G 上的区域字段, 没有牌时为 nil
---@param card table? 被操作的牌
---@param extra table? 其它字段 (id, targets, smods_use)
---@return string? method
---@return table? params
local function press(fn, field, card, extra)
  local params = extra or {}
  params.fn = fn
  if field then
    local index = index_in(field, card)
    if not index then
      return nil
    end
    params.area = field
    params.index = index
  end
  return "press", params
end

--- buy_from_shop: 商店里的小丑, 消耗牌, 扑克牌, 以及 "买了直接用".
local function translate_buy(e)
  local card = e and e.config and e.config.ref_table
  return press("buy_from_shop", "shop_jokers", card, { id = e.config.id == "buy_and_use" and "buy_and_use" or nil })
end

--- use_card: 按卡所在的区域区分. 优惠券和卡包的按钮每帧被换成 use_card (button_callbacks.lua 的
--- can_redeem, can_open), 它们照 buy 接口回放: 接口在这两种情况下与人点等价, 而且会等到完成.
--- 卡包里的牌与消耗牌记成 press, 带上手里选中的牌. 不认识的区域不记.
local function translate_use(e)
  local card = e and e.config and e.config.ref_table
  if not card then
    return nil
  end
  local index = index_in("shop_vouchers", card)
  if index then
    return "buy", { voucher = index }
  end
  index = index_in("shop_booster", card)
  if index then
    return "buy", { pack = index }
  end
  local extra = { targets = targets(), smods_use = e.config.SMODS_use_card and true or nil }
  if index_in("pack_cards", card) then
    return press("use_card", "pack_cards", card, extra)
  end
  return press("use_card", "consumeables", card, extra)
end

--- sell_card: 卖小丑或消耗牌.
local function translate_sell(e)
  local card = e and e.config and e.config.ref_table
  if index_in("jokers", card) then
    return press("sell_card", "jokers", card)
  end
  return press("sell_card", "consumeables", card)
end

--- 记成 press, 但不指向牌的按钮函数.
local function plain_press(fn)
  return function()
    return press(fn)
  end
end

---@param options {record: fun(fields: table)}
function M.install(options)
  deps = options
  local click = UIElement.click
  function UIElement:click(...) ---@diagnostic disable-line: duplicate-set-field
    clicking = clicking + 1
    local a, b = click(self, ...)
    clicking = clicking - 1
    return a, b
  end

  hook("play_cards_from_highlighted", hand_cards("play"))
  hook("discard_cards_from_highlighted", hand_cards("discard"))
  hook("select_blind", plain("select"))
  -- skip_blind 要从按钮所在的界面取标签, 只能照接口回放.
  hook("skip_blind", plain("skip"))
  hook("reroll_shop", plain("reroll"))
  hook("cash_out", plain("cash_out"))
  hook("toggle_shop", plain("next_round"))
  hook("buy_from_shop", translate_buy)
  hook("use_card", translate_use)
  hook("sell_card", translate_sell)
  hook("skip_booster", plain_press("skip_booster"))
  -- 花 $10 换 Boss, 没有接口.
  hook("reroll_boss", plain_press("reroll_boss"))
  -- 排序按钮改的是 G.hand.config.sort, 之后发的牌也按它排, 只记一次重排的结果不够.
  hook("sort_hand_suit", plain_press("sort_hand_suit"))
  hook("sort_hand_value", plain_press("sort_hand_value"))
end

--- 每帧调用: 拖动排序的检测.
function M.update()
  if not deps then
    return
  end
  local areas = {}
  for name, field in pairs(M.AREAS) do
    areas[name] = G[field] and G[field].cards or nil
  end
  local dragging = G.CONTROLLER and G.CONTROLLER.dragging and G.CONTROLLER.dragging.target ~= nil
  for _, change in ipairs(M.track(areas, dragging, drag_state)) do
    record("reorder", { area = change.area, order = change.order })
  end
end

--- 让手里选中的牌与 targets 一致. Cerulean Bell 强制选中的牌 unhighlight_all 不会取消, 原局里它也在.
---@param targets integer[]?
---@return boolean ok
local function set_targets(targets)
  if not G.hand then
    return targets == nil
  end
  G.hand:unhighlight_all()
  for _, index in ipairs(targets or {}) do
    local card = G.hand.cards[index + 1]
    if not card then
      return false
    end
    G.hand:add_to_highlighted(card, true)
  end
  return true
end

---@param params table
---@return boolean? ok nil 表示还没准备好 (例如标签送的卡包还没打开), 下一帧再试
---@return string? reason
local function apply_press(params)
  local fn = PRESS_FUNCS[params.fn] and G.FUNCS[params.fn]
  if not fn then
    return false, "不能重做的按钮 " .. tostring(params.fn)
  end
  local e = { config = { id = params.id, SMODS_use_card = params.smods_use } }
  if params.area then
    if not PRESS_AREAS[params.area] or type(params.index) ~= "number" then
      return false, "不认识的区域 " .. tostring(params.area)
    end
    local area = G[params.area]
    local card = area and area.cards and area.cards[params.index + 1]
    if not card then
      return nil, string.format("%s 里没有第 %d 张牌", params.area, params.index)
    end
    e.config.ref_table = card
  end
  if params.fn == "use_card" and not set_targets(params.targets) then
    return false, "手里没有要选的牌"
  end
  if fn(e) == false then
    return false, params.fn .. " 没有执行 (原局里成功了)"
  end
  return true
end

--- 回放时重做本地步骤. 返回 true; nil 与原因表示还没准备好, 下一帧再试; false 与原因表示做不了.
---
--- reorder 只换数组顺序, 与人拖动时游戏做的一样 (CardArea:align_cards 按横坐标排序数组, 不改
--- ability.order 之类的字段); 之后 align_cards 按新顺序摆位置, 不会再排回去.
---@param method string
---@param params table?
---@return boolean? ok
---@return string? reason
function M.apply_local(method, params)
  params = params or {}
  if method == "press" then
    return apply_press(params)
  end
  if method ~= "reorder" then
    return false, "未知的本地步骤 " .. tostring(method)
  end
  local field = M.AREAS[params.area]
  local area = field and G[field]
  if not area or type(area.cards) ~= "table" then
    return false, "没有区域 " .. tostring(params.area)
  end
  local cards = M.apply_order(area.cards, params.order)
  if not cards then
    return false, string.format("%s 的顺序对不上: 现在 %d 张", params.area, #area.cards)
  end
  area.cards = cards
  return true
end

return M
