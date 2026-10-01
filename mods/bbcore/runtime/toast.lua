--[[
agent 提示消息, 仿原版成就解锁通知 (functions/common_events.lua 的 notify_alert):
黑底灰描边的圆角 UIBox, 外圈 TRANSPARENT_DARK, 从屏幕侧面滑入, 停留后滑出.

两条车道, 各自排队互不影响:
- 右侧: 决策消息 (模型给的 reason) 与 notify 的解说, 由 M.enabled 控制.
- 左侧: 每次工具调用的记录 (标题是工具中文名, 正文是参数含义, 见 runtime/call_note.lua), 由 M.calls_enabled 控制.

车道用同一套定义表, 只是内容贴着屏幕的一侧摆, 多出来的宽度留在屏幕外:
右侧 align "cr" 且内容靠左, 左侧 align "cli" 且内容靠右.

- 消息画在游戏自己的 UI 层 (G.I.POPUP, 在覆盖菜单之上), 经过 CRT 等屏幕效果, 录像里也一样.
- 停留时长按墙钟计; 通知仍在屏幕上或还排在队里时, 录制把这段视为活动期, 不会被剪掉.
- 一条一条显示: 同一条车道上已有消息正在显示时新来的排队等着, 前一条开始退场时下一条才滑入, 顺序不丢.
  排队不设上限, 一句解说都不丢 (agent 打得太快时文字会落后于画面, 这是取舍).
- 每条通知有阅读时长 (按字数估算) 和额外停留 (LINGER): 阅读时长过后 on_read 回调触发.
  左侧那条的正文短, 阅读时长另有一个更小的上限 (CALL_READ_MAX).
- 讲解 (gate 为 true 的那些, 目前是 notify) 还能被后面的操作等: 见 M.gate_id / M.gate_open,
  改状态的操作要等自己那条讲解退去才执行 (dispatcher 的门槛), 观众先看到文字再看到动作.
  左侧那条不拦操作.
- 阶段切换 (回主菜单, 开新局) 会重建 G.ROOM_ATTACH, 已有的通知与排队的消息随之清空.
]]

local M = {
  -- 右侧: 决策消息与解说.
  enabled = true,
  -- 左侧: 工具调用记录.
  calls_enabled = true,
  -- 讲解是否拦后面的操作 (dispatcher 的门槛). 回放时关掉: 原局里操作是在讲解停留期间就执行的,
  -- 回放照原样重做, 不该再被拦一次 (回放自身用 notify 的 wait 复现原来的节奏).
  gate_enabled = true,
}

local MAX_ITEMS = 3
-- 中文一行约 17 字, 12 行约 200 字; 提示词里写的上限 (180 字) 要留在这以内.
-- 英文一行约 31 字符, 字符数上限先到.
local MAX_CHARS = 300
local MAX_LINES = 12
local LINE_WIDTH = 5.2 -- 游戏单位
local WIDE = 20 -- 定义表里那行的最小宽度: 内容贴屏幕一侧, 多出来的部分留在屏幕外
local MARGIN = 0.8 -- 内容离屏幕边缘的留白
local TITLE_SCALE = 0.32
local TEXT_SCALE = 0.36
local GAP = 0.12
local ENTER_DELAY = 0.1 -- 等 UIBox 算出尺寸再滑入, 与原版一致
local LEAVE_TIME = 0.6 -- 滑出后再移除
local MAX_WALL = 40
local LINGER = 2 -- 读完后再停留的秒数
-- 阅读速度: 中文约每秒 5~6 字, 英文与数字按每秒约 15 字符.
local READ_BASE = 1.2
local READ_WIDE = 0.18
local READ_NARROW = 0.06
local READ_MIN = 2.5
-- 180 字的中文约 34 秒读完; 加上 LINGER 不超过 MAX_WALL.
local READ_MAX = 36
-- 左侧那条的阅读时长上限: 正文只有一句参数说明.
local CALL_READ_MAX = 8
-- 叠起来的通知底边离屏幕下沿至少留这么多, 再往下的旧通知提前滑出.
local BOTTOM_MARGIN = 0.3

---@class BB.Toast.Lane
---@field side "right"|"left"
---@field items table[] 屏幕上这一侧的通知 (正在显示或正在退场)
---@field pending table[] 这一侧排队等待显示的消息, 先进先出, 不设上限也不丢

---@type table<string, BB.Toast.Lane>
local lanes = {
  right = { side = "right", items = {}, pending = {} },
  left = { side = "left", items = {}, pending = {} },
}
--- 消息的编号, 自增. 讲解的 id 用来让后面的操作等它退去.
local next_id = 0
---@type table<integer, boolean> 还在队里或屏幕上的讲解
local gated_inflight = {}

---@param text string
---@return string[] 按 UTF-8 拆分的字符
local function utf8_chars(text)
  local chars = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = ch
  end
  return chars
end

---@param text string
---@param limit integer
---@return string
function M.truncate(text, limit)
  local chars = utf8_chars(text)
  if #chars <= limit then
    return text
  end
  return table.concat(chars, "", 1, limit - 3) .. "..."
end

--- 选字体: 当前语言字体只含拉丁字母 (m6x11) 而文本含非 ASCII 时, 改用带中日韩字形的字体.
---@param text string
local function pick_lang(text)
  local lang = G.LANG
  if not text:find("[\128-\255]") then
    return lang
  end
  local file = lang.font and lang.font.file or ""
  if file:find("m6x11") and G.LANGUAGES and G.LANGUAGES.all2 then
    return G.LANGUAGES.all2
  end
  return lang
end
M.pick_lang = pick_lang

---@param lang table
---@param text string
---@param scale number
---@return number 游戏单位宽度, 与 engine/ui.lua 的文本节点算法一致
local function text_width(lang, text, scale)
  local font = lang.font
  return font.FONT:getWidth(text) * font.squish * scale * font.FONTSCALE / G.TILESIZE
end
M.text_width = text_width

-- 其后的空格是好的断行点
local BREAK_AFTER = { [","] = true, ["."] = true, [":"] = true, [";"] = true, ["!"] = true, ["?"] = true }

--- 按宽度折行; 超过 MAX_LINES 行时截断并加省略号.
--- 断行点优先取标点后的空格. 中文里的空格是数字与汉字间的间隔, 在那里断会把 "9 张" 拆开,
--- 所以含中文的行没有标点可断时按字断, 纯英文行才在空格处断.
local function wrap(lang, text, scale)
  local lines, current, last_space, last_punct, wide = {}, {}, nil, nil, false
  for _, ch in ipairs(utf8_chars(text)) do
    if ch == "\n" then
      lines[#lines + 1] = table.concat(current)
      current, last_space, last_punct, wide = {}, nil, nil, false
    else
      current[#current + 1] = ch
      if #ch > 1 then
        wide = true
      end
      if ch == " " then
        last_space = #current
        if BREAK_AFTER[current[#current - 1] or ""] then
          last_punct = #current
        end
      end
      if text_width(lang, table.concat(current), scale) > LINE_WIDTH and #current > 1 then
        local cut
        -- 标点离行首太近时不用, 免得留下很短的一行.
        if last_punct and last_punct >= #current * 0.4 then
          cut = last_punct
        elseif not wide and last_space and last_space > 1 then
          cut = last_space
        else
          cut = #current - 1
        end
        lines[#lines + 1] = table.concat(current, "", 1, cut)
        local rest = {}
        for i = cut + 1, #current do
          rest[#rest + 1] = current[i]
        end
        current, last_space, last_punct = rest, nil, nil
        wide = false
        for _, rest_ch in ipairs(rest) do
          if #rest_ch > 1 then
            wide = true
          end
        end
      end
    end
  end
  if #current > 0 then
    lines[#lines + 1] = table.concat(current)
  end
  if #lines > MAX_LINES then
    local kept = {}
    for i = 1, MAX_LINES do
      kept[i] = lines[i]
    end
    kept[MAX_LINES] = kept[MAX_LINES]:gsub("%s+$", "") .. "..."
    lines = kept
  end
  for i = 1, #lines do
    lines[i] = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
  end
  return lines
end

local function build_definition(title, text, side)
  local title_lang = pick_lang(title)
  local text_lang = pick_lang(text)
  -- 内容贴屏幕的一侧: 左侧那条靠右摆, 多出来的宽度留在屏幕外 (见文件头的说明).
  local inner = side == "left" and "cr" or "cl"
  local rows = {
    {
      n = G.UIT.R,
      config = { align = inner, padding = 0.03 },
      nodes = {
        { n = G.UIT.T, config = { text = title, scale = TITLE_SCALE, colour = G.C.FILTER, shadow = true, lang = title_lang } },
      },
    },
  }
  for _, line in ipairs(wrap(text_lang, text, TEXT_SCALE)) do
    rows[#rows + 1] = {
      n = G.UIT.R,
      config = { align = inner, padding = 0.02 },
      nodes = {
        { n = G.UIT.T, config = { text = line, scale = TEXT_SCALE, colour = G.C.UI.TEXT_LIGHT, shadow = true, lang = text_lang } },
      },
    }
  end
  -- 结构与 create_UIBox_notify_alert 相同: 内层 minw 很宽, 只露出内容那一侧, 其余留在屏幕外.
  return {
    n = G.UIT.ROOT,
    config = { align = inner, r = 0.1, padding = 0.06, colour = G.C.UI.TRANSPARENT_DARK },
    nodes = {
      {
        n = G.UIT.R,
        config = { align = inner, padding = 0.2, minw = WIDE, r = 0.1, colour = G.C.BLACK, outline = 1.5, outline_colour = G.C.GREY },
        nodes = {
          { n = G.UIT.C, config = { align = inner, padding = 0.02 }, nodes = rows },
        },
      },
    },
  }
end

--- 阅读时长: 中日韩等多字节字符按 READ_WIDE 计, ASCII 按 READ_NARROW 计, 限制在 READ_MIN~cap.
--- 显式给出 duration 时以它为准.
---@param text string
---@param duration number?
---@param cap number? 上限, 按字数算时默认 READ_MAX, 显式给了 duration 时默认 MAX_WALL
---@return number
function M.duration_for(text, duration, cap)
  if type(duration) == "number" and duration > 0 then
    return math.min(duration, cap or MAX_WALL)
  end
  local seconds = READ_BASE
  for _, ch in ipairs(utf8_chars(text)) do
    seconds = seconds + (#ch > 1 and READ_WIDE or READ_NARROW)
  end
  return math.max(READ_MIN, math.min(cap or READ_MAX, seconds))
end

---@param item table
local function fire_read(item)
  local callback = item.on_read
  if callback then
    item.on_read = nil
    callback()
  end
end

local function content_width(item)
  local inner = item.box.UIRoot.children[1]
  local column = inner and inner.children[1]
  return column and column.T.w or LINE_WIDTH
end

local function remove_item(item)
  fire_read(item)
  if item.box and not item.box.REMOVED then
    item.box:remove()
  end
  item.box = nil
  if item.gated then
    gated_inflight[item.id] = nil
  end
end

--- 让一条消息开始显示: 建 UIBox 并放进它那条车道.
---@param entry table
local function show(entry)
  local lane = entry.lane
  local title = M.truncate(entry.title and entry.title ~= "" and entry.title or "Agent", 40)
  local text = M.truncate(entry.text, MAX_CHARS)

  local box = UIBox({
    definition = build_definition(title, text, lane.side),
    -- 先摆在屏幕外, update 里等尺寸算出来再滑入. 左侧用 "cli": offset.x 就是框的左边缘.
    config = {
      align = lane.side == "left" and "cli" or "cr",
      offset = { x = lane.side == "left" and -WIDE or WIDE, y = 0 },
      major = G.ROOM_ATTACH,
      bond = "Weak",
      instance_type = "POPUP",
      can_collide = false,
    },
  })
  box.bb_toast = true

  entry.box = box
  entry.attach = G.ROOM_ATTACH
  entry.age = 0
  entry.read = M.duration_for(text, entry.duration, entry.max_read)
  entry.life = math.min(entry.read + LINGER, MAX_WALL)
  entry.leave_at = nil
  table.insert(lane.items, 1, entry)
end

--- 显示一条消息. 同一条车道上已有消息时排队等着 (前一条开始退场时下一条才滑入), 调用方立刻返回.
--- on_read 在阅读时长过后 (或通知提前被移除时) 调用一次.
--- 这条车道被关掉 (或不在游戏界面) 时返回 false, on_read 不会被调用.
---@param title string?
---@param text string
---@param duration number?
---@param on_read fun()?
---@param opts {gated: boolean?, side: "right"|"left"?}? gated 为 true 时这条是讲解, 可供 dispatcher 的门槛等待
---@return boolean shown
function M.push(title, text, duration, on_read, opts)
  local side = (opts and opts.side) == "left" and "left" or "right"
  local enabled = side == "left" and M.calls_enabled or (side == "right" and M.enabled)
  if not enabled or not G.ROOM_ATTACH or type(text) ~= "string" or text == "" then
    return false
  end
  next_id = next_id + 1
  local lane = lanes[side]
  local entry = {
    id = next_id,
    lane = lane,
    title = title,
    text = text,
    duration = duration,
    on_read = on_read,
    gated = (opts and opts.gated) == true,
    -- 左侧那条只有一句参数说明, 阅读时长收到 CALL_READ_MAX
    max_read = side == "left" and CALL_READ_MAX or READ_MAX,
  }
  if entry.gated then
    gated_inflight[entry.id] = true
  end
  if #lane.items > 0 or #lane.pending > 0 then
    lane.pending[#lane.pending + 1] = entry
  else
    show(entry)
  end
  -- 超出数量时这条车道上最旧的一条立即滑出.
  -- 排队之后同时显示的多是退场中的前一条, 一般到不了这里.
  for i = MAX_ITEMS + 1, #lane.items do
    local old = lane.items[i]
    old.leave_at = old.leave_at or old.age
    fire_read(old)
  end
  return true
end

--- 还在队里或屏幕上的最新一条讲解的 id, 没有时返回 nil.
--- 后面的操作等的是自己那条讲解, 也就是它前面最后发出的一条 (队列先进先出, 等它等于等前面的都退去).
---@return integer?
function M.gate_id()
  if not M.gate_enabled then
    return nil
  end
  local newest
  for id in pairs(gated_inflight) do
    if not newest or id > newest then
      newest = id
    end
  end
  return newest
end

--- 这条讲解是否已经退去 (屏幕上与队里都没有了). id 为 nil 时视为无需等待.
---@param id integer?
---@return boolean
function M.gate_open(id)
  return id == nil or gated_inflight[id] == nil
end

--- 是否还有通知显示在屏幕上 (含滑出过程), 录制据此判断活动期.
---@return boolean
function M.active()
  for _, lane in pairs(lanes) do
    if #lane.items > 0 or #lane.pending > 0 then
      return true
    end
  end
  return false
end

--- 一条通知在屏幕上的横坐标: 内容贴着屏幕的一侧, 多出来的宽度留在屏幕外.
---@param item table
---@param leaving boolean
---@return number
local function offset_x(item, leaving)
  local lane = item.lane
  if lane.side == "left" then
    -- "cli": offset.x 就是框的左边缘; 内容靠右摆, 所以先退到内容宽度那么多
    if leaving then
      return -(item.box.T.w + 1)
    end
    return G.ROOM.T.x + MARGIN - math.max(0, WIDE - content_width(item))
  end
  if leaving then
    return WIDE
  end
  return G.ROOM.T.x - MARGIN - content_width(item)
end

--- 这条车道上是否有还在显示 (没开始退场) 的消息.
---@param lane BB.Toast.Lane
---@return boolean
local function lane_showing(lane)
  for _, item in ipairs(lane.items) do
    if not item.leave_at then
      return true
    end
  end
  return false
end

--- 推进这条车道上已显示的消息: 计时, 摆放, 到期移除. 返回留下来的那些.
---@param lane BB.Toast.Lane
---@param dt number
---@return table[]
local function advance_lane(lane, dt)
  local kept = {}
  local y = 0
  for _, item in ipairs(lane.items) do
    local box = item.box
    local alive = box and not box.REMOVED and item.attach == G.ROOM_ATTACH
    if alive then
      item.age = item.age + dt
      if item.on_read and item.age >= item.read + ENTER_DELAY then
        fire_read(item)
      end
      if not item.leave_at and (item.age >= item.life + ENTER_DELAY or item.age >= MAX_WALL) then
        item.leave_at = item.age
      end
      if item.leave_at and item.age >= item.leave_at + LEAVE_TIME then
        alive = false
      end
    end
    if alive then
      local offset = box.alignment.offset
      if item.leave_at then
        offset.x = offset_x(item, true)
      elseif item.age >= ENTER_DELAY then
        offset.x = offset_x(item, false)
      end
      -- 最新的在最上面, 旧的依次往下排. 从屏幕中线往上 2.6 开始, 两三条时也尽量不压到手牌.
      local h = box.T.h
      -- 长消息叠在一起会超出屏幕下沿: 最新一条总留着, 放不下的旧通知提前滑出.
      local bottom = G.ROOM.T.h / 2 - BOTTOM_MARGIN
      if #kept > 0 and not item.leave_at and -2.6 + y + h > bottom then
        item.leave_at = item.age
        fire_read(item)
        offset.x = offset_x(item, true)
      end
      offset.y = -2.6 + y + h / 2
      y = y + h + GAP
      kept[#kept + 1] = item
    else
      remove_item(item)
    end
  end
  return kept
end

--- 每帧调用, 放在游戏 update 之后. dt 为墙钟间隔.
---@param dt number
function M.update(dt)
  for _, lane in pairs(lanes) do
    -- 一条一条来: 这条车道上没有还在显示的消息 (前一条已开始退场) 时, 把队首放出来.
    if #lane.pending > 0 and not lane_showing(lane) then
      show(table.remove(lane.pending, 1))
    end
    if #lane.items > 0 then
      lane.items = advance_lane(lane, dt)
    end
  end
end

--- 立即移除通知, 排队里的也一起丢掉 (它们的 on_read 会触发, 等着的调用方不会一直等).
--- 给 side 时只清那一条车道 (设置页关掉某一个开关时用), 不给则两侧都清.
---@param side "right"|"left"?
function M.clear(side)
  local targets = side and { lanes[side] } or lanes
  for _, lane in pairs(targets) do
    for _, item in ipairs(lane.pending) do
      fire_read(item)
      if item.gated then
        gated_inflight[item.id] = nil
      end
    end
    lane.pending = {}
    for _, item in ipairs(lane.items) do
      remove_item(item)
    end
    lane.items = {}
  end
end

return M
