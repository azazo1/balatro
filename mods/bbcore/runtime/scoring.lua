--[[
一次出牌的计分过程记录 (bbcore 的运行时之一).

挂在游戏自己的显示函数上, 不另算一套:

- update_hand_text: 牌型, 等级, 基础筹码与倍率, 以及每次加成之后的当前筹码与倍率.
  这一手算完后游戏会把筹码与倍率清成 0 并给出本手总分 (chip_total), 看到它就把记录冻结.
- card_eval_status_text: 屏幕上飘的那一行 (+50 筹码, x1.5 倍率, 被削弱, 版本加成), 每一行记成一步.
- highlight_card: 参与计分的牌会被抬起来, 用来标记哪几张真计入牌型.
- play_area_status_text: 只在盲注封禁这一手时被调用 (Not Allowed!), 用来标记本手不计分.

记录挂在 G.GAME 的自定义字段 (bb_last_hand) 上: 开新局时 G.GAME 重建, 记录自然是新的, 读档一起恢复.
只有 play 端点声明过的那次出牌会被记录 (begin), 送出响应 (close) 或冻结之后, 结算界面与回合结束的
小丑效果都不会记进这一手.

词条固定用中文 (筹码, 倍率), 牌型与卡牌的名字取游戏当前语言, 与 user 屏幕上看到的一致.
记录器与文本拼接不碰全局, 名字与落盘由 deps 注入, 便于单测.
]]

local M = {}

--- G.GAME 上放记录的字段名.
M.FIELD = "bb_last_hand"

-- ==========================================================================
-- 文本
-- ==========================================================================

---@param v number?
---@return string 整数不带小数点, 乘倍率这类小数保留到三位再去掉尾零
local function num(v)
  v = tonumber(v) or 0
  if v == math.floor(v) and math.abs(v) < 1e15 then
    return string.format("%d", v)
  end
  return (string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", ""))
end

---@param chips number?
---@param mult number?
---@return string 例如 "125x81"
local function pair_text(chips, mult)
  return num(chips) .. "x" .. num(mult)
end

---@param amount number
---@return string 带符号的变化量, 例如 "+10"
local function signed(amount)
  return (amount >= 0 and "+" or "") .. num(amount)
end

--- 第二列: 这一步变的是筹码还是倍率.
---@param step table
---@return string
local function factor(step)
  local kind = step.kind
  if kind == "chips" then
    return signed(step.amount) .. " 筹码"
  elseif kind == "mult" then
    return signed(step.amount) .. " 倍率"
  elseif kind == "xmult" then
    return "x" .. num(step.amount) .. " 倍率"
  elseif kind == "xchips" then
    return "x" .. num(step.amount) .. " 筹码"
  elseif kind == "dollars" then
    return (step.amount >= 0 and "+$" or "-$") .. num(math.abs(step.amount))
  elseif kind == "blocked" then
    return "本手不计分"
  elseif kind == "debuff" then
    return "被削弱"
  end
  -- 版本加成, 重复触发这类: 游戏自己写的那句话就是屏幕上飘的内容
  return step.message or "额外效果"
end

--- 摘要里用的那一行.
---@param record table
---@return string 例如 "上一手: 同花 Lv1 = 10125"
function M.line(record)
  local out = "上一手: " .. tostring(record.name or "?")
  if tonumber(record.level) and record.level > 0 then
    out = out .. " Lv" .. num(record.level)
  end
  out = out .. " = " .. num(record.total)
  if record.blocked then
    out = out .. " (本手被盲注封禁)"
  end
  return out
end

--- 出牌那一步结果里给的整段.
---@param record table
---@return string
function M.text(record)
  local out = { M.line(record) }

  local parts = {}
  for _, card in ipairs(record.cards or {}) do
    parts[#parts + 1] = tostring(card.label or "?") .. (card.scoring and "*" or "")
  end
  out[#out + 1] = "出牌: " .. (#parts > 0 and table.concat(parts, " ") or "?")

  if record.base then
    out[#out + 1] = "基础 " .. pair_text(record.base.chips, record.base.mult)
  end
  for _, step in ipairs(record.steps or {}) do
    out[#out + 1] = string.format(
      "%s | %s | %s",
      tostring(step.name or "?"),
      factor(step),
      pair_text(step.chips, step.mult)
    )
  end
  out[#out + 1] = "= " .. num(record.total)
  return table.concat(out, "\n")
end

-- ==========================================================================
-- 记录器
-- ==========================================================================

-- 屏幕上那一行的类型 (card_eval_status_text 的 eval_type) 到结构化 kind 的对应.
local KIND = {
  chips = "chips",
  h_chips = "chips",
  mult = "mult",
  h_mult = "mult",
  x_mult = "xmult",
  h_x_mult = "xmult",
  x_chips = "xchips",
  h_x_chips = "xchips",
  dollars = "dollars",
  debuff = "debuff",
}

---@class BB.Scoring.Deps
---@field reason fun(card: table, extra: table?): string 变动原因列的名字, 取游戏当前语言
---@field card fun(card: table): table 结构化字段里的一张牌: key / suit / rank / label
---@field store fun(record: table)? 记完一手后落盘 (游戏内写到 G.GAME 上)
---@field log fun(level: string, msg: string)? 记录出错时的日志

---@param deps BB.Scoring.Deps
---@return table
function M.new(deps)
  local self = {
    on = false, -- 出牌期间为真, 冻结或响应送出之后为假
    played = nil, -- {objects = 打出的牌, infos = 结构化信息}
    scoring = {}, -- 参与计分的牌, 以牌对象本身为键
    steps = {},
    pair = { chips = 0, mult = 0 },
    record = nil, -- 冻结后的结果
  }

  local function reset()
    self.name, self.level, self.base = nil, nil, nil
    self.pair = { chips = 0, mult = 0 }
    self.played, self.scoring = nil, {}
    self.blocked, self.steps = false, {}
  end
  reset()

  --- 开始记录这一手 (play 端点在参数校验之后调用).
  function self:begin()
    reset()
    self.on = true
  end

  --- 停止记录. 没冻结 (这一手没打出来) 时丢掉半截记录.
  function self:close()
    self.on = false
  end

  --- 记下这一手打出的牌, 只有开始记录后的第一次有效 (那时牌还在场上).
  ---@param cards table[]? G.play.cards
  function self:played_cards(cards)
    if not self.on or self.played or type(cards) ~= "table" or #cards == 0 then
      return
    end
    local objects, infos = {}, {}
    for i, card in ipairs(cards) do
      objects[i] = card
      infos[i] = deps.card(card)
    end
    self.played = { objects = objects, infos = infos }
  end

  --- 记下参与计分的牌 (游戏把它们抬起来时调用).
  ---@param card table
  function self:scoring_card(card)
    if self.on then
      self.scoring[card] = true
    end
  end

  --- 盲注封禁这一手 (屏幕上出现 Not Allowed!).
  function self:blocked_hand()
    if self.on then
      self.blocked = true
    end
  end

  --- 记一步: 谁, 变的是什么, 多少. 变动后的筹码与倍率取游戏此刻的值.
  ---@param card table
  ---@param kind string chips / mult / xmult / dollars / debuff / extra
  ---@param amount number?
  ---@param extra table?
  function self:step(card, kind, amount, extra)
    if not self.on then
      return
    end
    self.steps[#self.steps + 1] = {
      by = deps.card(card).key,
      name = deps.reason(card, extra),
      kind = kind,
      amount = tonumber(amount),
      chips = self.pair.chips,
      mult = self.pair.mult,
      -- 模组给的消息可能是本地化节点而不是字符串, 拿不准就当没有, 退回自己的词
      message = type(extra and extra.message) == "string" and extra.message or nil,
    }
  end

  --- 按屏幕上那一行 (card_eval_status_text 的 eval_type) 记一步或多步.
  ---@param card table
  ---@param eval_type string
  ---@param amount number?
  ---@param extra table?
  function self:status(card, eval_type, amount, extra)
    if not self.on then
      return
    end
    local kind = KIND[eval_type]
    if kind then
      self:step(card, kind, amount, extra)
      return
    end
    if eval_type ~= "jokers" and eval_type ~= "extra" and eval_type ~= "swap" then
      return
    end
    -- 小丑与版本加成把变化量放在 extra 里, 一次可能要记不止一步
    extra = extra or {}
    local changed = false
    if tonumber(extra.chip_mod) then
      changed = true
      self:step(card, "chips", extra.chip_mod, extra)
    end
    if tonumber(extra.mult_mod) then
      changed = true
      self:step(card, "mult", extra.mult_mod, extra)
    end
    local xmult = extra.x_mult_mod or extra.Xmult_mod
    if tonumber(xmult) then
      changed = true
      self:step(card, "xmult", xmult, extra)
    end
    local xchips = extra.xchip_mod or extra.Xchips_mod
    if tonumber(xchips) then
      changed = true
      self:step(card, "xchips", xchips, extra)
    end
    if not changed then
      -- 重触发 (红封, 悬挂小丑这类) 游戏可能不写提示词, 补一句自己的
      if not extra.message and extra.repetitions then
        extra = { message = "重复触发" }
      end
      self:step(card, "extra", nil, extra)
    end
  end

  --- 牌型与当前筹码倍率的变化 (update_hand_text 的参数).
  --- 第一次带牌型的调用给的是牌型基础, 之后给的是加成后的当前值.
  ---@param vals table
  function self:hand_text(vals)
    if not self.on then
      return
    end
    if type(vals.chip_total) == "number" then
      self:freeze(vals.chip_total)
      return
    end
    if type(vals.handname) == "string" and vals.handname ~= "" then
      self.name = vals.handname
      if type(vals.level) == "number" and vals.level > 0 then
        self.level = vals.level
      end
      if not self.base and type(vals.chips) == "number" and type(vals.mult) == "number" then
        self.base = { chips = vals.chips, mult = vals.mult }
        self.pair = { chips = vals.chips, mult = vals.mult }
      end
    end
    if type(vals.chips) == "number" then
      self.pair.chips = vals.chips
    end
    if type(vals.mult) == "number" then
      self.pair.mult = vals.mult
    end
  end

  --- 冻结这一手: 总分由游戏给出, 最终筹码与倍率取最后一次记到的值.
  ---@param total number
  function self:freeze(total)
    if not self.on then
      return
    end
    self.on = false

    local cards = {}
    for i, info in ipairs(self.played and self.played.infos or {}) do
      -- 游戏会先抬起要计分的牌, 再说这一手被盲注封禁
      info.scoring = (self.scoring[self.played.objects[i]] and not self.blocked) and true or false
      cards[i] = info
    end

    -- 封禁这一手没有数值步骤, 补一行说明, 让明细自己讲清为什么是 0 分
    local steps = self.blocked
        and { { by = "", name = "被盲注封禁", kind = "blocked", chips = 0, mult = 0 } }
      or self.steps

    local record = {
      name = self.name,
      level = self.level,
      base = self.base,
      chips = self.blocked and 0 or self.pair.chips,
      mult = self.blocked and 0 or self.pair.mult,
      total = total,
      blocked = self.blocked or nil,
      cards = cards,
      steps = steps,
    }
    record.line = M.line(record)
    record.text = M.text(record)
    self.record = record
    self.steps = {}
    if deps.store then
      deps.store(record)
    end
  end

  ---@return table? 冻结后的结果, 还没打过牌时为 nil
  function self:value()
    return self.record
  end

  return self
end

-- ==========================================================================
-- 游戏内: 装钩子
-- ==========================================================================

--- 读 G.GAME 上的记录, 形状不对 (例如旧存档) 时当作没有.
---@param game table? G.GAME
---@return table?
function M.read(game)
  local record = type(game) == "table" and game[M.FIELD] or nil
  if type(record) ~= "table" or type(record.text) ~= "string" or type(record.total) ~= "number" then
    return nil
  end
  return record
end

--- 扑克牌的名字用游戏自己的模板拼, 中英文的顺序由模板决定 (中文是 "红桃K", 英文是 "K of Hearts").
---@param value string 点数 (King, 10 ...)
---@param suit string 花色 (Hearts, Spades ...)
---@return string
local function playing_card_name(value, suit)
  local rank = localize(value, "ranks")
  local suit_name = localize(suit, "suits_plural")
  local other = G.localization and G.localization.descriptions and G.localization.descriptions.Other
  local template = other and other.playing_card
  local line = template and template.text and template.text[1]
  if type(line) == "string" then
    local out = ""
    for _, part in ipairs(loc_parse_string(line) or {}) do
      for _, sub in ipairs(part.strings or {}) do
        if type(sub) == "string" then
          out = out .. sub
        else
          -- 模板里 #1# 是点数, #2# 是花色
          out = out .. (tonumber(sub[1]) == 1 and rank or suit_name)
        end
      end
    end
    out = out:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if out ~= "" then
      return out
    end
  end
  return suit_name .. rank
end

---@param key string?
---@return string? 卡牌中心的名字 (版本, 小丑, 消耗牌都用它)
local function center_name(key)
  local center = key and G.P_CENTERS and G.P_CENTERS[key]
  return center and center.name or nil
end

-- 卡牌名带键缓存 (牌被删除后自动回收)
local name_cache = setmetatable({}, { __mode = "k" })

---@param card table 游戏里的卡牌对象
---@return string
local function card_name(card)
  -- 一手牌里同一张牌会被问好几次 (每一步都要写变动原因), 名字缓存下来
  local cached = name_cache[card]
  if cached then
    return cached
  end
  local name
  if card.base and card.base.suit and card.base.value then
    name = playing_card_name(card.base.value, card.base.suit)
  else
    name = card.label or center_name(card.config and card.config.center and card.config.center.key) or "?"
  end
  name_cache[card] = name
  return name
end

--- 游戏内的一套注入: 名字取游戏当前语言, 记录写到 G.GAME 上.
---@param gamestate table BB_GAMESTATE (借它的花色与点数枚举转换)
---@return BB.Scoring.Deps
function M.game_deps(gamestate)
  return {
    --- 变动原因列: 卡牌名, 版本加成时前面带上版本名, 手中牌的效果前面带 "手牌".
    reason = function(card, extra)
      local name = card_name(card)
      if extra and extra.edition then
        local edition = center_name(card.edition and card.edition.key)
        if edition then
          name = edition .. name
        end
      end
      if card.area == G.hand then
        name = "手牌" .. name
      end
      return name
    end,
    --- 结构化字段里的一张牌, 与 gamestate 里的 Card 同名同形.
    card = function(card)
      local key = ""
      if card.config then
        key = card.config.card_key or (card.config.center and card.config.center.key) or ""
      end
      local suit, rank = nil, nil
      if card.base and card.base.suit and card.base.value then
        suit = gamestate.suit_enum and gamestate.suit_enum(card.base.suit)
        rank = gamestate.rank_enum and gamestate.rank_enum(card.base.value)
      end
      return { key = key, suit = suit, rank = rank, label = card_name(card) }
    end,
    --- 记录挂在 G.GAME 上: 开新局自然重建, 读档一起恢复.
    store = function(record)
      if G and G.GAME then
        G.GAME[M.FIELD] = record
      end
    end,
    log = function(level, msg)
      if level == "warn" then
        sendWarnMessage(msg, "BB.SCORING")
      else
        sendInfoMessage(msg, "BB.SCORING")
      end
    end,
  }
end

---@type table? install 之后的当前记录器
M.recorder = nil

---@param fn fun()
---@param log fun(level: string, msg: string)?
local function safe(fn, log)
  local ok, err = pcall(fn)
  if not ok and log then
    log("warn", "scoring record failed: " .. tostring(err))
  end
end

--- 把记录器接到游戏的显示函数上. 只装一次.
---@param deps BB.Scoring.Deps
---@return boolean installed
function M.install(deps)
  if M.recorder then
    return false
  end
  local recorder = M.new(deps)
  local log = deps.log
  M.recorder = recorder

  local orig_hand_text = update_hand_text
  update_hand_text = function(config, vals) ---@diagnostic disable-line: duplicate-set-field
    -- 只有出牌期间才记 (recorder.on), 平时只是一次布尔判断
    if recorder.on then
      safe(function()
        -- 打出哪些牌要趁牌还在场上时取, 也就是这一手第一次更新牌型的时候
        recorder:played_cards(G.play and G.play.cards)
        recorder:hand_text(vals or {})
      end, log)
    end
    return orig_hand_text(config, vals)
  end

  local orig_eval_text = card_eval_status_text
  card_eval_status_text = function(card, eval_type, amt, percent, dir, extra) ---@diagnostic disable-line: duplicate-set-field
    if recorder.on then
      safe(function()
        recorder:status(card, eval_type, amt, extra)
      end, log)
    end
    return orig_eval_text(card, eval_type, amt, percent, dir, extra)
  end

  local orig_highlight = highlight_card
  highlight_card = function(card, percent, dir) ---@diagnostic disable-line: duplicate-set-field
    if recorder.on and dir == "up" then
      safe(function()
        recorder:scoring_card(card)
      end, log)
    end
    return orig_highlight(card, percent, dir)
  end

  local orig_status_text = play_area_status_text
  play_area_status_text = function(text, silent, delay) ---@diagnostic disable-line: duplicate-set-field
    -- 游戏只用这个函数显示过 "Not Allowed!" (盲注封禁这一手)
    if recorder.on and text == "Not Allowed!" then
      safe(function()
        recorder:blocked_hand()
      end, log)
    end
    return orig_status_text(text, silent, delay)
  end

  return true
end

--- 开始记录 (play 端点用).
function M.begin()
  if M.recorder then
    M.recorder:begin()
  end
end

--- 停止记录 (play 端点送响应前用).
function M.close()
  if M.recorder then
    M.recorder:close()
  end
end

return M
