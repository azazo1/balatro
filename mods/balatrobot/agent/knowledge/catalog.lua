--[[
结构化目录 (手册的 data/catalog.json) 的查询, 纯逻辑, 不依赖 G/SMODS, 单测直接加载.

第一次查询时解析 catalog.json, 建立 id, 中文名, 英文名 (不区分大小写) 的索引, 之后常驻内存.
lookup 返回每张卡的精简记录, 并从 mechanics/ 的文档里带出提到这个 id 的行,
一次调用就能同时拿到卡面效果和实际机制. 找不到的 key 给出几个名称相近的候选.

json 解码与文件读取由调用方注入; docs 为 knowledge/docs.lua 的手册对象, 用于带出机制行和目录位置.
]]

local M = {}

M.CATALOG_PATH = "data/catalog.json"
-- 每张卡最多带出的机制行
M.MECHANICS_MAX = 5
-- 同名的卡最多返回几张 (例如 4 个外观不同的 "秘术包")
M.SAME_NAME_MAX = 8
-- 找不到时给出的候选数
M.CANDIDATES_MAX = 5
-- 一次最多查询的 key 数
M.KEYS_MAX = 30

local RARITY = { "普通", "罕见", "稀有", "传奇" }
-- 没有逐项锚点的类别, 指向整个目录文件
local CATEGORY_DOC = {
  Challenge = "cards/challenges.md",
  Other = "cards/modifiers.md",
}

---@param s string
---@return string
local function squash(s)
  return (s:lower():gsub("[%s%p]", ""))
end

---@class Knowledge.Catalog
local Catalog = {}
Catalog.__index = Catalog

---@param opts {read: fun(rel: string): string?, decode: fun(text: string): table, docs: Knowledge.Docs?}
---@return Knowledge.Catalog
function M.new(opts)
  return setmetatable({ _read = opts.read, _decode = opts.decode, _docs = opts.docs }, Catalog)
end

---@param index table<string, table[]>
---@param key string
---@param entry table
local function add(index, key, entry)
  if key == "" then
    return
  end
  local list = index[key]
  if not list then
    list = {}
    index[key] = list
  end
  for _, e in ipairs(list) do
    if e == entry then
      return
    end
  end
  list[#list + 1] = entry
end

--- 解析并建索引, 失败时抛出错误.
function Catalog:load()
  if self._entries then
    return
  end
  local text = self._read(M.CATALOG_PATH)
  if not text then
    error("Failed to read " .. M.CATALOG_PATH)
  end
  local ok, data = pcall(self._decode, text)
  if not ok or type(data) ~= "table" or type(data.records) ~= "table" then
    error("Failed to parse " .. M.CATALOG_PATH .. ": " .. tostring(ok and "unexpected structure" or data))
  end
  local entries = {}
  for _, r in ipairs(data.records) do
    entries[#entries + 1] = r
  end
  for _, r in ipairs(data.modifiers or {}) do
    entries[#entries + 1] = r
  end
  for _, c in ipairs(data.challenges or {}) do
    entries[#entries + 1] = {
      id = c.id,
      name_zh = c.name_zh,
      name_en = c.name_en or c.name,
      category = "Challenge",
    }
  end
  local by_id, by_name, by_squash = {}, {}, {}
  for _, e in ipairs(entries) do
    if type(e.id) == "string" then
      by_id[e.id] = by_id[e.id] or e
      add(by_name, e.id:lower(), e)
      add(by_squash, squash(e.id), e)
    end
    for _, name in ipairs({ e.name_zh, e.name_en }) do
      if type(name) == "string" then
        add(by_name, name:lower(), e)
        add(by_squash, squash(name), e)
      end
    end
  end
  self._entries, self._by_id, self._by_name, self._by_squash = entries, by_id, by_name, by_squash
end

--- 目录文档里的位置, 例如 cards/jokers.md#j-blueprint.
---@param entry table
---@return string?
function Catalog:doc_ref(entry)
  if not self._docs then
    return nil
  end
  if not self._anchors then
    self._anchors = self._docs:anchor_paths("cards")
  end
  for _, id in ipairs({ entry.id:gsub("_", "-"), entry.id }) do
    local rel = self._anchors[id]
    if rel then
      return rel .. "#" .. id
    end
  end
  return CATEGORY_DOC[entry.category]
end

---@param entry table
---@return table
function Catalog:compact(entry)
  local effect = entry.effect_zh
  local card = {
    id = entry.id,
    name_zh = entry.name_zh,
    name_en = entry.name_en,
    category = entry.category,
    rarity = entry.rarity and (RARITY[entry.rarity] or tostring(entry.rarity)) or nil,
    base_cost = entry.base_cost,
    -- 描述行按卡面换行拆开, 用空格连成一行, 避免数字与相邻文字粘连
    effect_zh = type(effect) == "table" and table.concat(effect, " ") or effect,
    blueprint_compat = entry.blueprint_compat,
    doc = self:doc_ref(entry),
  }
  if self._docs then
    -- 蜡封等 id 是普通单词 (Gold, Red), 只匹配代码格式的写法, 否则会带出大量无关行
    local token = entry.id:find("_", 1, true) and entry.id or ("`" .. entry.id .. "`")
    card.mechanics = self._docs:grep_token(token, "mechanics", M.MECHANICS_MAX)
  end
  return card
end

--- 按 id, 中文名, 英文名精确匹配 (名称不区分大小写, 再忽略空格与标点).
---@param key string
---@return table[]
function Catalog:find(key)
  self:load()
  local exact = self._by_id[key]
  if exact then
    return { exact }
  end
  local trimmed = key:gsub("^%s+", ""):gsub("%s+$", "")
  return self._by_name[trimmed:lower()] or self._by_squash[squash(trimmed)] or {}
end

--- 名称相近的候选: 名称或 id 包含 key, 或 key 包含名称. 按长度差排序.
---@param key string
---@return string[] "id 中文名 / 英文名"
function Catalog:candidates(key)
  self:load()
  local needle = squash(key)
  if needle == "" then
    return {}
  end
  local scored = {}
  for _, e in ipairs(self._entries) do
    local best
    for _, name in ipairs({ e.id, e.name_zh, e.name_en }) do
      if type(name) == "string" then
        local s = squash(name)
        if s ~= "" and (s:find(needle, 1, true) or needle:find(s, 1, true)) then
          local d = math.abs(#s - #needle)
          best = best and math.min(best, d) or d
        end
      end
    end
    if best then
      scored[#scored + 1] = { entry = e, score = best }
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score < b.score
    end
    return a.entry.id < b.entry.id
  end)
  local out = {}
  for i = 1, math.min(#scored, M.CANDIDATES_MAX) do
    local e = scored[i].entry
    out[i] = e.id .. " " .. tostring(e.name_zh) .. " / " .. tostring(e.name_en)
  end
  return out
end

--- 批量查询. 参数错误时返回 nil 与原因.
---@param keys string[]
---@return table? result
---@return string? err
function Catalog:lookup(keys)
  if type(keys) ~= "table" or #keys == 0 then
    return nil, "Field 'keys' must be a non-empty array of strings"
  end
  if #keys > M.KEYS_MAX then
    return nil, "At most " .. M.KEYS_MAX .. " keys per call"
  end
  self:load()
  local results = {}
  for i, key in ipairs(keys) do
    if type(key) ~= "string" then
      return nil, "Field 'keys' must be a non-empty array of strings"
    end
    local found = self:find(key)
    local item = { key = key, cards = {} }
    for j = 1, math.min(#found, M.SAME_NAME_MAX) do
      item.cards[j] = self:compact(found[j])
    end
    if #found == 0 then
      item.candidates = self:candidates(key)
    end
    results[i] = item
  end
  return { results = results }
end

return M
