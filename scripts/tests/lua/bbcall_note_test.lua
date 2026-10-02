-- 工具调用左侧弹窗文案 (bbcore/runtime/call_note.lua) 的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local CallNote = dofile("mods/bbcore/runtime/call_note.lua")
local Tools = dofile("mods/balatrobot/agent/loop/tools.lua")

-- balatrobot 的手册查询文案由它自己登记 (与游戏里的加载顺序一致)
CallNote.register_all(dofile("mods/balatrobot/agent/knowledge/notes.lua"))

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

---@param method string
---@param params table?
---@return string
local function text(method, params)
  local note = CallNote.note(method, params)
  return note and note.text or "(不显示)"
end

do -- 标题: 工具中文名, 没有模板的也有中文名, 都没有时退回方法名
  check("有模板的方法", CallNote.title("play") == "出牌" and CallNote.title("dynamics") == "查动态值")
  check("手册方法", CallNote.title("lookup") == "查卡牌" and CallNote.title("docs_read") == "读手册")
  check("只有标题的方法", CallNote.title("cash_out") == "结算" and CallNote.title("notify") == "解说")
  check("没有登记时用方法名", CallNote.title("bogus_method") == "bogus_method")
end

do -- 没有参数时给工具功能的一句话
  check("选择盲注", text("select", {}) == "进入当前盲注, 开始这一回合")
  check("刷新商店", text("reroll") == "花钱刷新商店")
  check("离开商店", text("next_round") == "离开商店, 回到选择盲注")
  check("手册目录", text("docs_index", {}) == "看手册目录与按决策查阅表")
  check("查动态值", text("dynamics", {}) == "查当前局会变的值: 认牌目标与成长值")
  check("购买没给下标", text("buy", {}) == "在商店买一件")
end

do -- 有参数时把参数翻成人话
  check("出牌下标", text("play", { cards = { 0, 1 } }) == "手牌下标 0, 1")
  check("弃牌下标", text("discard", { cards = { 3 } }) == "手牌下标 3")
  check("开局三项", text("start", { deck = "RED", stake = "WHITE", seed = "ABC123" }) == "牌组 RED, 赌注 WHITE, 种子 ABC123")
  check("开局没有种子", text("start", { deck = "BLUE", stake = "GOLD" }) == "牌组 BLUE, 赌注 GOLD")
  check("购买商店牌 (下标转序数)", text("buy", { card = 1 }) == "商店第 2 张")
  check("购买优惠券", text("buy", { voucher = 0 }) == "优惠券第 1 张")
  check("购买补充包", text("buy", { pack = 2 }) == "补充包第 3 个")
  check("买下立即使用", text("buy", { card = 0, use = true }) == "商店第 1 张, 买下立即使用")
  check("出售小丑", text("sell", { joker = 1 }) == "小丑第 2 张")
  check("出售消耗牌", text("sell", { consumable = 0 }) == "消耗牌第 1 张")
  check("卡包选牌带目标", text("pack", { card = 0, targets = { 1, 2 } }) == "卡包第 1 张, 目标手牌 1, 2")
  check("跳过卡包", text("pack", { skip = true }) == "跳过卡包")
  check("使用消耗牌", text("use", { consumable = 1, cards = { 0 } }) == "消耗牌第 2 张, 目标手牌 0")
  check("调整小丑顺序", text("rearrange", { jokers = { 1, 0, 2 } }) == "小丑新顺序 1, 0, 2")
  check("调整手牌顺序", text("rearrange", { hand = { 4, 3, 2, 1, 0 } }) == "手牌新顺序 4, 3, 2, 1, 0")
end

do -- dynamics 的参数: 只说这次多要了什么
  check("摸牌堆统计", text("dynamics", { deck = "stats" }) == "摸牌堆统计")
  check("两个列表", text("dynamics", { deck = "list", discard = "list" }) == "摸牌堆列表, 弃牌堆列表")
  check("关掉卡牌效果", text("dynamics", { cards = false }) == "不含卡牌效果")
  check("关掉认牌目标", text("dynamics", { targets = false }) == "不含认牌目标")
  check("组合", text("dynamics", { deck = "stats", cards = false }) == "摸牌堆统计, 不含卡牌效果")
end

do -- 手册查询的参数
  check("读手册带章节", text("docs_read", { path = "cards/jokers.md", section = "j-blueprint" }) == "读 cards/jokers.md 的 j-blueprint 节")
  check("读手册只有路径", text("docs_read", { path = "rules/scoring.md" }) == "读 rules/scoring.md")
  check("读手册带行号", text("docs_read", { path = "rules/scoring.md", offset = 40 }) == "读 rules/scoring.md, 从第 40 行")
  check("搜手册", text("docs_search", { query = "同花" }) == "搜 同花")
  check("搜手册限定路径", text("docs_search", { query = "xmult", path = "mechanics" }) == "搜 xmult (限 mechanics)")
  check("查卡牌", text("lookup", { keys = { "蓝色小丑", "j_blueprint" } }) == "查 蓝色小丑, j_blueprint")
end

do -- 不上左侧的方法 (只读轮询, 自动步骤, notify) 一律不显示
  for _, method in ipairs({ "notify", "health", "gamestate", "rpc.discover", "screenshot", "save", "load", "set", "add", "menu", "cash_out", "continue", "endless" }) do
    check("不显示: " .. method, CallNote.note(method, {}) == nil)
  end
end

do -- 正文超长时截断 (左侧弹窗是辅助信息)
  local keys = {}
  for i = 1, 12 do
    keys[i] = "很长的卡牌名字" .. i
  end
  local note = CallNote.note("lookup", { keys = keys })
  local chars = 0
  for _ in note.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars = chars + 1
  end
  check("超长正文截断", chars <= CallNote.MAX_TEXT and note.text:sub(-3) == "...", tostring(chars))
end

do -- 一致性: agent 的每个工具都要有文案 (新增工具时这条会提醒补文案)
  local missing = {}
  for method in pairs(Tools.ACTIONS) do
    if not CallNote.note(method, {}) then
      missing[#missing + 1] = method
    end
  end
  for method in pairs(Tools.QUERIES) do
    if not CallNote.note(method, {}) then
      missing[#missing + 1] = method
    end
  end
  check("工具都有左侧文案", #missing == 0, table.concat(missing, ", "))
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("all passed")
