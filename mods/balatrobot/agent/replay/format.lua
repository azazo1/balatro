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
  for _, name in ipairs(AREAS) do
    if state[name] then
      parts[#parts + 1] = name .. "=" .. area_token(state[name])
    end
  end
  return table.concat(parts, " ")
end

---@param digest string
---@return table<string, string>
local function split(digest)
  local fields = {}
  for part in digest:gmatch("%S+") do
    local key, value = part:match("^([^=]+)=(.*)$")
    if key then
      fields[key] = value
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
    if a[key] ~= b[key] then
      local function short(v)
        v = v or "(none)"
        return #v > 80 and (v:sub(1, 77) .. "...") or v
      end
      out[#out + 1] = key .. ": " .. short(a[key]) .. " -> " .. short(b[key])
    end
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
