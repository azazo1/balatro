--[[
回放文件的纯逻辑部分, 不依赖游戏, 单测直接加载.

- digest: 每步操作完成后的状态摘要, 回放时比对, 发现跑偏.
- gap / timeout: 两种回放节奏下, 下一步之前要等多久, 以及等响应的上限.
- recorded: 哪些方法写进回放文件.
]]

local M = {}

M.VERSION = 1

-- 不写进回放文件的方法:
-- start/load 是一局的起点, 由文件里的 run 字段表示; save 会写用户指定的路径, 回放时不能重做;
-- 其余是只读查询.
local NOT_RECORDED = {
  ["start"] = true,
  ["load"] = true,
  ["save"] = true,
  ["health"] = true,
  ["gamestate"] = true,
  ["rpc.discover"] = true,
  ["screenshot"] = true,
  ["docs_index"] = true,
  ["docs_read"] = true,
  ["docs_search"] = true,
  ["lookup"] = true,
  ["dynamics"] = true,
}

---@param method string
---@return boolean
function M.recorded(method)
  return type(method) == "string" and not NOT_RECORDED[method]
end

local EDITION = { FOIL = "f", HOLO = "h", POLYCHROME = "p", NEGATIVE = "n" }

---@param card table gamestate 里的一张牌
---@return string
local function card_token(card)
  local token = tostring(card.key or "?")
  local mod = card.modifier or {}
  if mod.edition then
    token = token .. "+" .. (EDITION[mod.edition] or string.lower(mod.edition))
  end
  if mod.seal then
    token = token .. "#" .. string.lower(mod.seal)
  end
  if mod.enhancement then
    token = token .. "~" .. string.lower(mod.enhancement)
  end
  if mod.eternal then
    token = token .. "!e"
  end
  if mod.rental then
    token = token .. "!r"
  end
  return token
end

---@param area table? gamestate 里的一个区域
---@return string
local function area_token(area)
  local list = {}
  for i, card in ipairs(area and area.cards or {}) do
    list[i] = card_token(card)
  end
  return table.concat(list, ",")
end

-- 按顺序比较的区域. 手牌和小丑的顺序影响 agent 用的下标, 必须一致.
local AREAS = { "hand", "jokers", "consumables", "shop", "vouchers", "packs", "pack" }

--- 状态摘要: 空格分隔的 key=value, 便于对比时指出哪一项不同.
--- 牌堆只比张数, 它的顺序在动画中会暂时变化.
---@param state table BB_GAMESTATE.get_gamestate() 的结果
---@return string
function M.digest(state)
  local parts = {
    "state=" .. tostring(state.state),
    "ante=" .. tostring(state.ante_num),
    "round=" .. tostring(state.round_num),
    "money=" .. tostring(state.money),
    "deck=" .. tostring(state.cards and #(state.cards.cards or {}) or 0),
  }
  local todos = {}
  for _, name in ipairs(AREAS) do
    if state[name] then
      parts[#parts + 1] = name .. "=" .. area_token(state[name])
      for _, card in ipairs(state[name].cards or {}) do
        if type(card.to_do) == "string" and card.to_do ~= "" then
          todos[#todos + 1] = card.to_do:gsub("%s+", "_")
        end
      end
    end
  end
  if #todos > 0 then
    parts[#parts + 1] = "todo=" .. table.concat(todos, ",")
  end
  return table.concat(parts, " ")
end

--- 把摘要拆成 字段名 -> 值. 值按顺序拼回去, 因为**值本身可能含空格**.
---
--- 摘要用空格分隔字段, 所以取值时只能按空格切开. 但早先录下的摘要里, 非扑克牌卡的强化位
--- 写的是原型的 `effect` 名, 而那个名字可能带空格 (`suit conversion`, `x1.5 mult`), 于是
--- 一个字段被切成好几块, 后继的牌也跟着掉出字段 —— `shop=c_saturn~hand upgrade,j_zany~type
--- mult!e` 里连 `j_zany` 都不在 `shop` 的值里了.
---
--- 这些碎片有个好认的特征: **没有 `=`**. 字段名与值的分隔必然是 `=`, 所以不带 `=` 的碎片
--- 只可能是上一个值的续段 (值本身不会有空格, 除了这个来源). 按这个把它们并回去, 旧摘要就能
--- 恢复成完整的一串, 后面抹尾巴时才有东西可抹.
---@param digest string
---@return table<string, string>
local function split(digest)
  local fields = {}
  local last = nil
  for part in digest:gmatch("%S+") do
    local key, value = part:match("^([^=]+)=(.*)$")
    if key then
      fields[key] = value
      last = key
    elseif last then
      fields[last] = fields[last] .. " " .. part
    end
  end
  return fields
end

--- 摘要能不能拿来比: 状态未知时 (一局正在拆掉) 取到的是空的.
---@param digest string?
---@return boolean
function M.usable_digest(digest)
  return type(digest) == "string" and digest ~= "state=UNKNOWN" and digest:sub(1, 14) ~= "state=UNKNOWN "
end

-- 商店里的卡包把每一种贴图都做成独立原型 (p_arcana_normal_1 ... p_arcana_normal_4), 尾号只决定贴图.
-- 本局首包的保底小丑包与标签送的包用不种子化的 math.random 抽贴图, 回放时可能落在另一个编号上,
-- 玩法与包内内容都不受影响. 比对摘要时对 packs 字段忽略这个编号, 记录与显示仍用原值,
-- 旧回放文件因此不需要迁移.
---@param value string
---@return string
local function without_booster_art(value)
  return (value:gsub("(p_[%a%d_]+)_%d+", "%1"))
end

-- 八种扑克牌强化. 摘要里 `~` 后面原本还有别的东西 (非扑克牌卡把原型的 `effect` 名当成强化名
-- 写了进去, 例如 `c_sun~suit conversion`, `j_duo~x1.5 mult`), 那些名字由卡牌键唯一决定, 不携带
-- 状态, 还会因为自身带空格把摘要拆坏. bbcore 已改成只对扑克牌填 `enhancement`, 这里为了让
-- **改动之前录下**的回放仍能回放, 比对时把不在这个名单里的 `~` 尾巴一并忽略.
--
-- 名单是精确的, 不是"凡尾巴都放过": 真强化的增减仍然会被判成差异, 引擎把强化搞错跑不掉.
local ENHANCEMENTS = {
  bonus = true, mult = true, wild = true, glass = true,
  steel = true, stone = true, gold = true, lucky = true,
}

--- 把一个尾巴拆成"名字"与末尾那几个贴纸 (`!e` 永恒 / `!r` 租赁).
---
--- 贴纸从末尾一个一个剥, 不用 `(![er])+` 这种写法 —— Lua 的**量词只能跟字符类**, 跟在捕获组
--- 后面的 `+` 不起作用, 模式会静默地匹配不上 (写这条时踩过: 于是贴纸一个都没保住).
---@param tail string
---@return string name
---@return string stickers
local function split_stickers(tail)
  local stickers = ""
  while true do
    local one = tail:match("(%![er])$")
    if not one then
      break
    end
    stickers = one .. stickers
    tail = tail:sub(1, #tail - #one)
  end
  return tail, stickers
end

--- 抹掉字段值里"不是真强化"的 `~` 尾巴. 值形如 `c_sun~suit conversion,j_zany~type mult!e`.
---
--- 尾巴可以带空格 (`suit conversion`), 所以从 `~` 一直吃到下一个逗号为止, 不能按空格切.
--- 尾巴里的 `!e` / `!r` 是状态, 要从吃掉的片段里捡回来.
---@param value string
---@return string
local function without_effect_tails(value)
  return (value:gsub("~([^,]*)", function(tail)
    local name, stickers = split_stickers(tail)
    if ENHANCEMENTS[name] then
      return "~" .. tail
    end
    return stickers
  end))
end

--- 两个摘要字段是否相同. 卡包图案编号与"非真强化"的 `~` 尾巴都不算差异.
---@param key string
---@param a string?
---@param b string?
---@return boolean
local function same_field(key, a, b)
  if a == b then
    return true
  end
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  if key == "packs" then
    return without_booster_art(a) == without_booster_art(b)
  end
  if key ~= "jokers" and key ~= "consumables" and key ~= "shop" and key ~= "pack" then
    return false
  end
  return without_effect_tails(a) == without_effect_tails(b)
end

--- 两个摘要不同的项, 例如 "money: 12 -> 9; hand: ... -> ...". 相同时返回 nil.
---@param expected string
---@param actual string
---@return string?
function M.diff(expected, actual)
  if expected == actual then
    return nil
  end
  local a, b = split(expected), split(actual)
  local keys, seen = {}, {}
  for _, t in ipairs({ a, b }) do
    for key in pairs(t) do
      if not seen[key] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
  end
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    if not same_field(key, a[key], b[key]) then
      local function short(v)
        v = v or "(none)"
        return #v > 80 and (v:sub(1, 77) .. "...") or v
      end
      out[#out + 1] = key .. ": " .. short(a[key]) .. " -> " .. short(b[key])
    end
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out, "; ")
end

local STAKES = { "WHITE", "RED", "GREEN", "BLACK", "BLUE", "PURPLE", "ORANGE", "GOLD" }

--- 牌组 key (b_red) 转成 start 方法用的枚举 (RED). 不是原版牌组时返回 nil.
---@param key string?
---@return string?
function M.deck_enum(key)
  local name = type(key) == "string" and key:match("^b_(%a+)$")
  return name and string.upper(name) or nil
end

--- 开局前看设置: 这一局是不是受教程影响. 教程会强制给出优惠券, 标签和商店里的牌
--- (G.SETTINGS.tutorial_progress 的 forced_*), 跳过正常的随机抽取, 回放时用 start 开局重现不了.
---@param settings table? G.SETTINGS
---@return boolean
function M.tutorial_settings(settings)
  if type(settings) ~= "table" then
    return false
  end
  if settings.tutorial_complete == false then
    return true
  end
  local progress = settings.tutorial_progress
  return type(progress) == "table"
    and (progress.forced_voucher ~= nil or progress.forced_tags ~= nil or progress.forced_shop ~= nil)
end

--- 回放文件里的一局是不是教程局. 旧文件没有 run.tutorial, 用种子判断: 教程固定用 "TUTORIAL",
--- 而人手动输入这个种子时 seeded 为真.
---@param run table
---@return boolean
function M.is_tutorial(run)
  if run.tutorial ~= nil then
    return run.tutorial == true
  end
  return not run.resumed and run.seed == "TUTORIAL" and not run.seeded
end

--- 赌注等级 (1~8) 转成 start 方法用的枚举.
---@param stake integer?
---@return string?
function M.stake_enum(stake)
  return STAKES[stake or 0]
end

--- 这一步的状态要不要比对: 解锁通知和局内其它弹窗与存档积压和时机有关, 回放时不一定出现.
---@param overlay string?
---@return boolean
function M.comparable(overlay)
  return overlay == nil or overlay == "win"
end

--- original 节奏下, 这一步之前要等的秒数: 原局里上一次实际执行的操作完成到这一步开始的间隔.
--- 跳过的步骤 (原局里失败的操作) 不改变参照点, 它们的耗时算进下一步的间隔.
---@param action table 这一步
---@param reference number 原局里上一次实际执行的操作完成的时间
---@return number
function M.original_gap(action, reference)
  local gap = (action.wall or 0) - (reference or 0)
  return gap > 0 and gap or 0
end

--- 回放时要不要执行这一步: 原局里失败的操作 (被拦下, 参数不对) 没有改变游戏, 不重做.
--- ok 为空 (原局里没等到响应) 时仍然执行.
---@param action table
---@return boolean
function M.should_run(action)
  return action.ok ~= false
end

--- 等第 i 步响应的上限: 原局里这一步的耗时加余量, 限制在 [floor, ceil].
---@param action table
---@param floor number
---@param ceil number
---@return number
function M.timeout(action, floor, ceil)
  local took = (action.wall_end and action.wall) and (action.wall_end - action.wall) or 0
  return math.max(floor, math.min(ceil, took * 2 + 15))
end

return M
