-- 出牌计分记录 (bbcore/runtime/scoring.lua) 的纯逻辑单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Scoring = dofile("mods/bbcore/runtime/scoring.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function card(name, label, suit, rank)
  return { name = name, label = label or name, suit = suit, rank = rank }
end

local RED_K = card("H_K", "红桃K", "H", "K")
local RED_Q = card("H_Q", "红桃Q", "H", "Q")
local BLACK_2 = card("S_2", "黑桃2", "S", "2")
local SLY = card("j_sly", "狡诈小丑")
local HOLO = card("j_holo", "全息小丑")

--- 假命名: 名字直接用 label 前缀, 版本加成加 "闪箔" 前缀.
local function harness()
  local stored = nil
  local rec = Scoring.new({
    reason = function(c, extra)
      local name = c.label
      if extra and extra.edition then
        name = "闪箔" .. name
      end
      return name
    end,
    card = function(c)
      return { key = c.name, suit = c.suit, rank = c.rank, label = c.label }
    end,
    store = function(record)
      stored = record
    end,
  })
  return rec, function()
    return stored
  end
end

do -- 一手同花: 基础, 两张牌的加成, 小丑的加法与乘积, 最后冻结出总分
  local rec, stored = harness()
  local cards = { RED_K, RED_Q, BLACK_2 }
  rec:begin()
  rec:played_cards(cards)
  rec:scoring_card(RED_K)
  rec:scoring_card(RED_Q)
  -- 游戏总是先更新当前数值再飘字, 所以每一步的第三列是加了这一步之后的值
  rec:hand_text({ handname = "同花", level = 1, chips = 35, mult = 4 })
  rec:hand_text({ chips = 45 })
  rec:status(RED_K, "chips", 10)
  rec:hand_text({ mult = 8 })
  rec:status(RED_Q, "mult", 4)
  rec:hand_text({ mult = 58 })
  rec:status(SLY, "jokers", nil, { mult_mod = 50 })
  rec:hand_text({ mult = 87 })
  rec:status(HOLO, "jokers", nil, { Xmult_mod = 1.5 })
  rec:hand_text({ mult = 0, chips = 0, chip_total = 3915, level = "", handname = "" })

  local record = rec:value()
  check("冻结后拿到记录", record ~= nil and stored() == record)
  check(
    "摘要那一行",
    record.line == "上一手: 同花 Lv1 = 3915",
    tostring(record.line)
  )
  check("最终筹码与倍率", record.chips == 45 and record.mult == 87, record.chips .. "x" .. record.mult)
  check("总数由游戏给出", record.total == 3915)
  check(
    "整段文本",
    record.text
      == table.concat({
        "上一手: 同花 Lv1 = 3915",
        "出牌: 红桃K* 红桃Q* 黑桃2",
        "基础 35x4",
        "红桃K | +10 筹码 | 45x4",
        "红桃Q | +4 倍率 | 45x8",
        "狡诈小丑 | +50 倍率 | 45x58",
        "全息小丑 | x1.5 倍率 | 45x87",
        "= 3915",
      }, "\n"),
    tostring(record.text)
  )
  check("计分牌标记", record.cards[1].scoring == true and record.cards[2].scoring == true and record.cards[3].scoring == false)
  check(
    "结构化步骤",
    #record.steps == 4
      and record.steps[1].by == "H_K"
      and record.steps[1].kind == "chips"
      and record.steps[1].amount == 10
      and record.steps[4].kind == "xmult"
      and record.steps[4].amount == 1.5,
    tostring(#record.steps)
  )

  -- 冻结 (这一手算完了): 结算界面与回合结束的小丑效果都不该记进这一手
  rec:status(HOLO, "jokers", nil, { mult_mod = 999 })
  rec:hand_text({ chips = 999 })
  check("冻结之后不再记", #record.steps == 4 and record.chips == 45)
end

do -- 打出的牌只取第一次, 那时牌还在场上
  local rec = harness()
  rec:begin()
  rec:played_cards({ RED_K, BLACK_2 })
  rec:played_cards({ RED_Q })
  local record
  rec:hand_text({ handname = "高牌", chips = 5, mult = 1 })
  rec:hand_text({ chip_total = 5 })
  record = rec:value()
  check("第二次给的牌不算", #record.cards == 2 and record.cards[1].key == "H_K")
  check("没有计分牌时不出星号", not record.text:find("*", 1, true))
  check("牌型没有等级时不写 Lv", record.line == "上一手: 高牌 = 5", tostring(record.line))
end

do -- 盲注封禁这一手: 0 分, 明细给一行说明, 计分牌标记全部清掉
  local rec = harness()
  rec:begin()
  rec:played_cards({ RED_K, RED_Q })
  rec:scoring_card(RED_K)
  rec:hand_text({ handname = "同花", level = 1, chips = 35, mult = 4 })
  rec:blocked_hand()
  rec:hand_text({ mult = 0, chips = 0, chip_total = 0, level = "", handname = "" })
  local record = rec:value()
  check("封禁的摘要行", record.line == "上一手: 同花 Lv1 = 0 (本手被盲注封禁)", tostring(record.line))
  check(
    "封禁的明细",
    record.text:find("被盲注封禁 | 本手不计分 | 0x0", 1, true) ~= nil and record.text:find("基础 35x4", 1, true) ~= nil,
    tostring(record.text)
  )
  check("封禁时不算计分牌", record.cards[1].scoring == false)
end

do -- 不改变数值的步骤: 游戏自己写的那句话当变动原因, 没有就用 "重复触发"
  local rec = harness()
  rec:begin()
  rec:played_cards({ RED_K })
  rec:scoring_card(RED_K)
  rec:hand_text({ handname = "高牌", level = 1, chips = 5, mult = 1 })
  rec:status(RED_K, "debuff")
  rec:status(RED_K, "jokers", nil, { repetitions = 2 })
  rec:status(RED_K, "extra", nil, { message = "再次触发", edition = true })
  rec:hand_text({ chip_total = 0 })
  local record = rec:value()
  check(
    "削弱与重复触发写成原因",
    record.text:find("红桃K | 被削弱 | 5x1", 1, true) ~= nil
      and record.text:find("红桃K | 重复触发 | 5x1", 1, true) ~= nil
      and record.text:find("闪箔红桃K | 再次触发 | 5x1", 1, true) ~= nil,
    tostring(record.text)
  )
end

do -- Steamodded 的乘筹码与模组自定义的额外效果: 分别记成乘筹码与额外效果
  local rec = harness()
  rec:begin()
  rec:played_cards({ RED_K })
  rec:scoring_card(RED_K)
  rec:hand_text({ handname = "高牌", level = 1, chips = 5, mult = 1 })
  rec:hand_text({ chips = 25 })
  rec:status(RED_K, "x_chips", 5)
  rec:status(RED_K, "jokers", nil, { Xchips_mod = 2 })
  rec:status(RED_K, "extra", nil, {})
  rec:hand_text({ chip_total = 125 })
  local record = rec:value()
  check(
    "乘筹码与额外效果",
    record.text:find("红桃K | x5 筹码 | 25x1", 1, true) ~= nil
      and record.text:find("红桃K | x2 筹码 | 25x1", 1, true) ~= nil
      and record.text:find("红桃K | 额外效果 | 25x1", 1, true) ~= nil,
    tostring(record.text)
  )
end

do -- 响应送出后就不该再记: close 之后 begin 之前
  local rec = harness()
  rec:begin()
  rec:status(RED_K, "chips", 100)
  rec:close()
  rec:status(RED_K, "chips", 100)
  rec:hand_text({ chip_total = 5 })
  check("close 之后不冻结合半截记录", rec:value() == nil)

  rec:begin()
  rec:played_cards({ RED_K })
  rec:scoring_card(RED_K)
  rec:hand_text({ handname = "高牌", level = 1, chips = 5, mult = 1 })
  rec:hand_text({ chip_total = 5 })
  local record = rec:value()
  check("下一次 begin 重新开始", record ~= nil and #record.steps == 0 and record.total == 5)
end

do -- 从 G.GAME 上读记录: 形状不对 (旧存档) 时当作没有
  check("形状正确时读出", Scoring.read({ bb_last_hand = { text = "x", total = 1 } }) ~= nil)
  check("缺 text 时为 nil", Scoring.read({ bb_last_hand = { total = 1 } }) == nil)
  check("没有字段时为 nil", Scoring.read({}) == nil)
  check("没有游戏对象时为 nil", Scoring.read(nil) == nil)
end

do -- 装钩子: 搭一个最小假游戏, 走一遍游戏侧的包装与命名
  G = {
    GAME = {},
    P_CENTERS = { j_sly = { name = "狡诈小丑" } },
    localization = { descriptions = { Other = { playing_card = { text = { "{V:1}#2#{C:light_black}#1#" } } } } },
    hand = {},
    play = {},
  }
  local RANK = { King = "K", Ace = "A" }
  local SUIT = { Hearts = "红桃", Spades = "黑桃" }
  local MISC = { ranks = RANK, suits_plural = SUIT }
  function localize(args, misc_cat)
    if type(args) == "string" then
      return (MISC[misc_cat] or {})[args] or "ERROR"
    end
    return "ERROR"
  end
  -- 假解析: 只认 #1# 与 #2# 两种占位, 顺序照模板, 够测拼接 (字面文本与颜色控制码由游戏自己处理)
  function loc_parse_string(line)
    local strings = {}
    for ref in line:gmatch("#(%d)#") do
      strings[#strings + 1] = { ref }
    end
    return { { strings = strings } }
  end
  -- 游戏侧的四个显示函数 (装钩子前先有, 装完之后会换成包装版)
  local calls = {}
  function update_hand_text(_, vals)
    calls[#calls + 1] = "hand_text"
    G.GAME.current_round = { current_hand = vals }
  end
  function card_eval_status_text()
    calls[#calls + 1] = "eval_text"
  end
  function highlight_card()
    calls[#calls + 1] = "highlight"
  end
  function play_area_status_text()
    calls[#calls + 1] = "status_text"
  end

  local enums = {
    suit_enum = function(name)
      return ({ Hearts = "H", Spades = "S" })[name]
    end,
    rank_enum = function(name)
      return ({ King = "K", Ace = "A" })[name]
    end,
  }
  check("装钩子只成功一次", Scoring.install(Scoring.game_deps(enums)) and not Scoring.install(Scoring.game_deps(enums)))

  local king = { base = { suit = "Hearts", value = "King" }, config = { card_key = "H_K" }, area = G.play }
  local ace = { base = { suit = "Spades", value = "Ace" }, config = { card_key = "S_A" }, area = G.play }
  local sly = { base = {}, config = { center = { key = "j_sly" } }, label = "狡诈小丑", area = {} }
  G.play.cards = { king, ace }

  Scoring.begin()
  highlight_card(king, 0.1, "up")
  update_hand_text(nil, { handname = "同花", level = 2, chips = 35, mult = 4 })
  update_hand_text(nil, { chips = 45 })
  card_eval_status_text(king, "chips", 10, 0.1)
  update_hand_text(nil, { mult = 54 })
  card_eval_status_text(sly, "jokers", nil, 0.1, nil, { mult_mod = 50 })
  update_hand_text(nil, { mult = 0, chips = 0, chip_total = 2430, level = "", handname = "" })
  Scoring.close()

  local record = G.GAME.bb_last_hand
  check("记录写进 G.GAME", type(record) == "table" and record.total == 2430)
  check(
    "钩子记下的明细",
    record.text
      == table.concat({
        "上一手: 同花 Lv2 = 2430",
        "出牌: 红桃K* 黑桃A",
        "基础 35x4",
        "红桃K | +10 筹码 | 45x4",
        "狡诈小丑 | +50 倍率 | 45x54",
        "= 2430",
      }, "\n"),
    tostring(record.text)
  )
  check("扑克牌名按游戏模板拼", record.cards[1].label == "红桃K" and record.cards[1].suit == "H" and record.cards[1].rank == "K")
  check("参与计分的标记", record.cards[1].scoring == true and record.cards[2].scoring == false)
  check("原显示函数照常被调用", #calls == 7, tostring(#calls))
  check("读得回这份记录", Scoring.read(G.GAME) == record)
end

do -- 逐张点选时, 基础要跟着**最终**牌型走, 不能被第一张的"高牌"定死
  -- 出牌是逐张 click 的 (play 端点), 而每点一张都会重算当前牌型: 点第一张必然是高牌.
  -- 只在第一次取基础就会把它定在高牌的 5x1, 之后真正的牌型只覆盖了名字, 基础那一栏
  -- 就永远对不上 (真游戏里观察到的就是"牌型写两对/同花, 基础却写 5x1").
  local rec = harness()
  local cards = { RED_K, RED_Q, BLACK_2 }
  rec:begin()
  rec:played_cards(cards)
  rec:hand_text({ handname = "高牌", level = 1, chips = 5, mult = 1 })
  rec:hand_text({ handname = "同花", level = 1, chips = 35, mult = 4 })
  -- 真算分时游戏会再报一次同名牌型, 这时不该再改基础
  rec:hand_text({ handname = "同花", level = 1, chips = 35, mult = 4 })
  rec:hand_text({ chips = 45 })
  rec:status(RED_K, "chips", 10)
  rec:hand_text({ mult = 0, chips = 0, chip_total = 450, level = "", handname = "" })

  local record = rec:value()
  check(
    "基础取最终牌型而不是第一张的高牌",
    record.base.chips == 35 and record.base.mult == 4,
    tostring(record.base.chips) .. "x" .. tostring(record.base.mult)
  )
  check("基础那一行也跟着对", record.text:find("基础 35x4", 1, true) ~= nil, tostring(record.text))
end

do -- 同名牌型再报一次时不重取基础, 但等级要跟上
  local rec = harness()
  rec:begin()
  rec:played_cards({ RED_K })
  rec:hand_text({ handname = "同花", level = 1, chips = 35, mult = 4 })
  -- 游戏升级牌型时也会这样报 (同名, 但数值已经是升级后的)
  rec:hand_text({ handname = "同花", level = 2, chips = 85, mult = 7 })
  rec:hand_text({ mult = 0, chips = 0, chip_total = 85, level = "", handname = "" })
  local record = rec:value()
  check(
    "同名牌型不重取基础",
    record.base.chips == 35 and record.base.mult == 4,
    tostring(record.base.chips) .. "x" .. tostring(record.base.mult)
  )
  check("但等级要跟着更新", record.level == 2, tostring(record.level))
end

do -- 背面朝上的牌报的是 '?' 而不是数字, 不该污染基础
  local rec = harness()
  rec:begin()
  rec:played_cards({ RED_K })
  rec:hand_text({ handname = "????", level = "?", chips = "?", mult = "?" })
  -- 要冻结才拿得到记录 (没有总数时 `value()` 是 nil)
  rec:hand_text({ mult = 0, chips = 0, chip_total = 0, level = "", handname = "" })
  local record = rec:value()
  check("非数字的基础不记", record.base == nil, record.base and tostring(record.base.chips))
end

do -- 背面留手和小丑的来源身份不能从计分记录或旧名字缓存泄露
  local deps = Scoring.game_deps({ suit_enum = function(suit) return suit end, rank_enum = function(rank) return rank end })
  local c = { base = { suit = "Hearts", value = "King" }, config = { card_key = "H_K" }, area = G.hand }
  local visible = deps.card(c)
  c.facing = "back"
  local hidden = deps.card(c)
  check("隐藏计分来源不含身份字段", hidden.key == "" and hidden.suit == nil and hidden.rank == nil)
  check("隐藏来源不用正面名字缓存", hidden.label ~= visible.label)
  local reason = deps.reason(c, { edition = true })
  c.base = { suit = "Spades", value = "Ace" }
  c.config.card_key = "S_A"
  c.edition = { key = "e_holo" }
  check("改变隐藏身份和版本不改变来源描述", deps.reason(c, { edition = true }) == reason and deps.card(c).label == hidden.label)
  c.facing = "front"
  check("重新揭示后恢复结构化身份", deps.card(c).key == "S_A" and deps.card(c).suit == "Spades")
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("all passed")
