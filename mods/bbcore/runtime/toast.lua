--[[
agent 提示消息, 仿原版成就解锁通知 (functions/common_events.lua 的 notify_alert):
黑底灰描边的圆角 UIBox, 外圈 TRANSPARENT_DARK, 从屏幕侧面滑入, 停留后滑出.

两条车道, 各自排队互不影响:
- 右侧: 决策消息 (模型给的 reason) 与 notify 的解说, 由 M.enabled 控制.
- 左侧: 每次工具调用的记录 (标题是工具中文名, 正文是参数含义, 见 runtime/call_note.lua), 由 M.calls_enabled 控制.

车道用同一套定义表, 只是内容贴着屏幕的一侧摆, 多出来的宽度留在屏幕外:
- 右侧 align "cr" 且内容靠左: 内层 minw 很宽, 多出来的宽度留在屏幕右边外, 只露出内容 (原版做法).
- 左侧 align "cli" 且内容靠右: 同样用很宽的 minw, 多出来的宽度留在屏幕左边外.
  左侧的换行宽度 (CALL_LINE_WIDTH) 比右侧窄, 露出来的那截就不会拉得太长.

- 消息画在游戏自己的 UI 层 (G.I.POPUP, 在覆盖菜单之上), 经过 CRT 等屏幕效果, 录像里也一样.
- 停留时长按墙钟计.
- 一条一条显示: 同一条车道上已有消息正在显示时新来的排队等着, 前一条开始退场时下一条才滑入, 顺序不丢.
  排队不设上限, 一句解说都不丢 (agent 打得太快时文字会落后于画面, 这是取舍).
- 每条通知有阅读时长 (按字数估算) 和额外停留: 阅读时长过后 on_read 回调触发.
  左侧那条的正文短, 始终用更短的阅读上限和停留, 不跟右侧走.
  右侧按 M.pace 选时长: 回放紧凑节奏用更短的阅读与停留; 快进时阅读时长几乎为零 (等着的调用方随即放行),
  框仍停留一小会儿, 且不排队, 新来的直接叠在最上面 (见 M.set_pace).
  push 时带 fixed 的消息 (回放自己的提示) 不跟 pace 走, 始终按正常时长.
- 讲解 (gate 为 true 的那些: notify, 以及操作参数带的 reason) 还能被后面的操作等: 见 M.gate_id / M.gate_open,
  改状态的操作要等自己那条讲解退去才执行 (dispatcher 的门槛), 观众先看到文字再看到动作.
  带 reason 的操作等的就是它自己那条 reason.
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
  -- 右侧的时长档位: normal / compact (回放紧凑节奏) / fast (回放快进, 几乎不等).
  -- 左侧工具调用始终用短时长, 不看这个档位. 回放中途切换用 M.set_pace.
  pace = "normal",
}

local MAX_ITEMS = 3
-- 中文一行约 17 字, 12 行约 200 字; 提示词里写的上限 (180 字) 要留在这以内.
-- 英文一行约 31 字符, 字符数上限先到.
local MAX_CHARS = 300
local MAX_LINES = 12
local LINE_WIDTH = 5.2 -- 右侧的换行宽度 (游戏单位)
-- 左侧那条只有一句参数说明, 用更窄的换行宽度, 弹窗在水平方向就不会拉长.
local CALL_LINE_WIDTH = 4.4
local WIDE = 20 -- 内层那行的最小宽度: 内容贴屏幕一侧, 多出来的部分留在屏幕外
local MARGIN = 0.8 -- 内容离屏幕边缘的留白
local TITLE_SCALE = 0.32
local TEXT_SCALE = 0.36
local GAP = 0.12
local ENTER_DELAY = 0.1 -- 等 UIBox 算出尺寸再滑入, 与原版一致
local LEAVE_TIME = 0.6 -- 滑出后再移除
local MAX_WALL = 40
-- 右侧默认: 中文约每秒 5~6 字, 英文与数字按每秒约 15 字符.
-- 180 字的中文约 34 秒读完; 加上 linger 不超过 MAX_WALL.
local NORMAL_TIMING = {
  linger = 2,
  read_min = 2.5,
  read_max = 36,
  read_base = 1.2,
  read_wide = 0.18,
  read_narrow = 0.06,
}
-- 右侧紧凑节奏: 仍按字数估, 但下限, 上限和读完后再停都更短.
local COMPACT_TIMING = {
  linger = 0.5,
  read_min = 1.0,
  read_max = 5,
  read_base = 0.7,
  read_wide = 0.10,
  read_narrow = 0.04,
}
-- 右侧快进: 读完的回调几乎立刻触发 (等着的回放随即做下一步), 但框仍停留 linger 秒.
-- 滑入要 0.3~0.4 秒 (原版的弹簧移动), 停留太短时框还没进屏幕就开始退场, 等于看不到.
-- 快进时这一侧不排队, 新来的直接叠在最上面 (见 stacking), 文字不会落后于画面.
local FAST_TIMING = {
  linger = 1.4,
  read_min = 0.05,
  read_max = 0.05,
  read_base = 0.05,
  read_wide = 0,
  read_narrow = 0,
}
-- 左侧工具调用: 正文只有一句参数说明, 始终比右侧短, 不跟紧凑开关走.
local CALL_TIMING = {
  linger = 0.4,
  read_min = 0.7,
  read_max = 2.2,
  read_base = 0.5,
  read_wide = 0.08,
  read_narrow = 0.03,
}
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
---@param lang table
---@param text string
---@param scale number
---@param width number 这一条车道允许的宽度 (游戏单位)
local function wrap(lang, text, scale, width)
  width = width or LINE_WIDTH
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
      if text_width(lang, table.concat(current), scale) > width and #current > 1 then
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

--- 左侧那条的标题也按更窄的宽度截断 (标题不折行, 太长会把弹窗撑宽).
---@param title string
---@return string
local function left_title(title)
  return M.truncate(title, 12)
end

local function build_definition(title, text, side)
  local left = side == "left"
  local title_lang = pick_lang(title)
  local text_lang = pick_lang(text)
  local width = left and CALL_LINE_WIDTH or LINE_WIDTH
  -- 内容贴屏幕的一侧: 左侧靠右摆, 右侧靠左摆, 多出来的宽度留在屏幕外 (见文件头的说明).
  local inner = left and "cr" or "cl"
  local rows = {
    {
      n = G.UIT.R,
      config = { align = inner, padding = 0.03 },
      nodes = {
        {
          n = G.UIT.T,
          config = {
            text = left and left_title(title) or title,
            scale = TITLE_SCALE,
            colour = G.C.FILTER,
            shadow = true,
            lang = title_lang,
          },
        },
      },
    },
  }
  for _, line in ipairs(wrap(text_lang, text, TEXT_SCALE, width)) do
    rows[#rows + 1] = {
      n = G.UIT.R,
      config = { align = inner, padding = 0.02 },
      nodes = {
        { n = G.UIT.T, config = { text = line, scale = TEXT_SCALE, colour = G.C.UI.TEXT_LIGHT, shadow = true, lang = text_lang } },
      },
    }
  end
  return {
    n = G.UIT.ROOT,
    config = { align = inner, r = 0.1, padding = 0.06, colour = G.C.UI.TRANSPARENT_DARK },
    nodes = {
      {
        n = G.UIT.R,
        config = {
          align = inner,
          padding = 0.2,
          minw = WIDE,
          r = 0.1,
          colour = G.C.BLACK,
          outline = 1.5,
          outline_colour = G.C.GREY,
        },
        nodes = {
          { n = G.UIT.C, config = { align = inner, padding = 0.02 }, nodes = rows },
        },
      },
    },
  }
end

---@param side "left"|"right"?
---@param fixed boolean? 不跟 pace 走, 始终按正常时长
---@return table
local function timing_for(side, fixed)
  if side == "left" then
    return CALL_TIMING
  end
  if fixed then
    return NORMAL_TIMING
  end
  if M.pace == "fast" then
    return FAST_TIMING
  end
  if M.pace == "compact" then
    return COMPACT_TIMING
  end
  return NORMAL_TIMING
end

--- 阅读时长: 中日韩等多字节字符按 wide 计, ASCII 按 narrow 计, 限制在 min~cap.
--- 显式给出 duration 时以它为准, 只有快进例外 (原局讲解带的时长也不等). 左侧与紧凑节奏用各自更短的一套数.
---@param text string
---@param duration number?
---@param cap number? 上限, 按字数算时默认该侧 read_max, 显式给了 duration 时默认 MAX_WALL
---@param opts {side: "left"|"right"?, fixed: boolean?}?
---@return number
function M.duration_for(text, duration, cap, opts)
  local timing = timing_for(opts and opts.side, opts and opts.fixed)
  if timing == FAST_TIMING then
    return timing.read_min
  end
  if type(duration) == "number" and duration > 0 then
    return math.min(duration, cap or MAX_WALL)
  end
  local seconds = timing.read_base
  for _, ch in ipairs(utf8_chars(text)) do
    seconds = seconds + (#ch > 1 and timing.read_wide or timing.read_narrow)
  end
  return math.max(timing.read_min, math.min(cap or timing.read_max, seconds))
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

--- 完全藏到屏幕外的横坐标.
--- 右侧 "cr": offset 相对 ROOM 右边, +WIDE 整框在屏幕右边外 (内容靠左, 跟着出屏).
--- 左侧 "cli": offset 是框的左边缘. 内容靠右, 只推 -WIDE 时文字还贴在窗口左边;
---   要再减去 letterbox 和留白, 必要时按框实际宽度, 把右缘也推出屏幕.
---@param side "left"|"right"
---@param box table?
---@return number
local function hide_x(side, box)
  if side == "left" then
    local room_x = G.ROOM and G.ROOM.T and G.ROOM.T.x or 0
    local w = WIDE
    if box and box.T and type(box.T.w) == "number" and box.T.w > w then
      w = box.T.w
    end
    return -MARGIN - room_x - w
  end
  return WIDE
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

--- 按当前档位算一条消息的阅读时长与总停留. 显示时算一次, 切换档位时对屏幕上的再算一次.
---@param entry table
local function retime(entry)
  local side = entry.lane.side
  local timing = timing_for(side, entry.fixed)
  entry.read = M.duration_for(entry.shown_text, entry.duration, nil, { side = side, fixed = entry.fixed })
  entry.life = math.min(entry.read + timing.linger, MAX_WALL)
end

--- 让一条消息开始显示: 建 UIBox 并放进它那条车道.
---@param entry table
local function show(entry)
  local lane = entry.lane
  local title = M.truncate(entry.title and entry.title ~= "" and entry.title or "Agent", 40)
  local text = M.truncate(entry.text, MAX_CHARS)

  local box = UIBox({
    definition = build_definition(title, text, lane.side),
    -- 先摆在屏幕外, update 里等尺寸算出来再滑入.
    -- 左侧用 "cli": offset.x 是框的左边缘; 右侧用 "cr": offset.x 相对 ROOM_ATTACH 右边缘.
    config = {
      align = lane.side == "left" and "cli" or "cr",
      offset = { x = hide_x(lane.side), y = 0 },
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
  entry.shown_text = text
  entry.leave_at = nil
  retime(entry)
  table.insert(lane.items, 1, entry)
end

--- 这条车道是否不排队, 新来的直接叠在最上面: 右侧快进时. 排队会让文字一条条落后于画面.
---@param lane BB.Toast.Lane
---@return boolean
local function stacking(lane)
  return lane.side == "right" and M.pace == "fast"
end

--- 超出数量时这条车道上最旧的那些立即滑出.
--- 排队时同时显示的多是退场中的前一条, 一般到不了这里; 快进叠放时靠它限住条数.
---@param lane BB.Toast.Lane
local function trim(lane)
  for i = MAX_ITEMS + 1, #lane.items do
    local old = lane.items[i]
    old.leave_at = old.leave_at or old.age
    fire_read(old)
  end
end

--- 显示一条消息. 同一条车道上已有消息时排队等着 (前一条开始退场时下一条才滑入), 调用方立刻返回.
--- on_read 在阅读时长过后 (或通知提前被移除时) 调用一次.
--- 这条车道被关掉 (或不在游戏界面) 时返回 false, on_read 不会被调用.
---@param title string?
---@param text string
---@param duration number?
---@param on_read fun()?
---@param opts {gated: boolean?, side: "right"|"left"?, fixed: boolean?}? gated 为 true 时这条是讲解, 可供 dispatcher 的门槛等待;
--- fixed 为 true 时不跟 pace 走 (回放自己的提示, 快进时也要读得到)
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
    fixed = (opts and opts.fixed) == true,
  }
  if entry.gated then
    gated_inflight[entry.id] = true
  end
  -- 切到快进前排的队还没放完时仍排在后面, 保持顺序; update 里每帧放一条.
  if #lane.pending > 0 or (#lane.items > 0 and not stacking(lane)) then
    lane.pending[#lane.pending + 1] = entry
  else
    show(entry)
  end
  trim(lane)
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

--- 一条通知在屏幕上的横坐标.
--- 左侧: "cli" 下 offset.x 是框的左边缘; 内容靠右摆, 先退 (WIDE - 内容宽) 让多出来的部分留在屏幕左边外.
---   offset 再减去 G.ROOM.T.x: 绘制时 container 还会加一次 letterbox, 加两次会把框推进游戏区.
--- 右侧: "cr" 下 offset.x 相对 ROOM_ATTACH 右边, 靠内容宽度把框推到只露出内容 (原版做法).
---@param item table
---@param leaving boolean
---@return number
local function offset_x(item, leaving)
  local lane = item.lane
  if leaving then
    return hide_x(lane.side, item.box)
  end
  if lane.side == "left" then
    return MARGIN - G.ROOM.T.x - math.max(0, WIDE - content_width(item))
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
      if item.leave_at or item.age < ENTER_DELAY then
        offset.x = offset_x(item, true)
      else
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
    -- 叠放时 (快进) 不等前一条退场, 每帧放一条.
    if #lane.pending > 0 and (stacking(lane) or not lane_showing(lane)) then
      show(table.remove(lane.pending, 1))
      trim(lane)
    end
    if #lane.items > 0 then
      lane.items = advance_lane(lane, dt)
    end
  end
end

--- 切换右侧的时长档位 (回放开始, 结束, 或回放中途切换节奏时用).
--- 屏幕上还没退场的那些按新档位重算, 已经停留够的随即退场; 排队的显示时自然按新档位算.
---@param pace "normal"|"compact"|"fast"
function M.set_pace(pace)
  if pace ~= "compact" and pace ~= "fast" then
    pace = "normal"
  end
  if M.pace == pace then
    return
  end
  M.pace = pace
  for _, item in ipairs(lanes.right.items) do
    if not item.leave_at and not item.fixed then
      retime(item)
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
