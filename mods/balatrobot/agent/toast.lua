--[[
agent 决策消息, 仿原版成就解锁通知 (functions/common_events.lua 的 notify_alert):
黑底灰描边的圆角 UIBox, 外圈 TRANSPARENT_DARK, 从屏幕右侧滑入, 停留后滑出.

- 消息画在游戏自己的 UI 层 (G.I.POPUP, 在覆盖菜单之上), 经过 CRT 等屏幕效果, 录像里也一样.
- 停留时长按墙钟计; 通知仍在屏幕上时录制把这段视为活动期, 不会被剪掉.
- 阶段切换 (回主菜单, 开新局) 会重建 G.ROOM_ATTACH, 已有的通知随之清空.
]]

local M = {
  enabled = true,
}

local MAX_ITEMS = 3
local MAX_CHARS = 200
local MAX_LINES = 4
local LINE_WIDTH = 5.2 -- 游戏单位
local TITLE_SCALE = 0.32
local TEXT_SCALE = 0.36
local GAP = 0.12
local ENTER_DELAY = 0.1 -- 等 UIBox 算出尺寸再滑入, 与原版一致
local LEAVE_TIME = 0.6 -- 滑出后再移除
local MAX_WALL = 30

---@type table[]
local items = {}

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

---@param lang table
---@param text string
---@param scale number
---@return number 游戏单位宽度, 与 engine/ui.lua 的文本节点算法一致
local function text_width(lang, text, scale)
  local font = lang.font
  return font.FONT:getWidth(text) * font.squish * scale * font.FONTSCALE / G.TILESIZE
end

--- 按宽度折行, 优先在空格处断开; 超过 MAX_LINES 行时截断并加省略号.
local function wrap(lang, text, scale)
  local lines, current, last_space = {}, {}, nil
  for _, ch in ipairs(utf8_chars(text)) do
    if ch == "\n" then
      lines[#lines + 1] = table.concat(current)
      current, last_space = {}, nil
    else
      current[#current + 1] = ch
      if ch == " " then
        last_space = #current
      end
      if text_width(lang, table.concat(current), scale) > LINE_WIDTH and #current > 1 then
        local cut = (last_space and last_space > 1) and last_space or (#current - 1)
        lines[#lines + 1] = table.concat(current, "", 1, cut)
        local rest = {}
        for i = cut + 1, #current do
          rest[#rest + 1] = current[i]
        end
        current, last_space = rest, nil
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

local function build_definition(title, text)
  local title_lang = pick_lang(title)
  local text_lang = pick_lang(text)
  local rows = {
    {
      n = G.UIT.R,
      config = { align = "cl", padding = 0.03 },
      nodes = {
        { n = G.UIT.T, config = { text = title, scale = TITLE_SCALE, colour = G.C.FILTER, shadow = true, lang = title_lang } },
      },
    },
  }
  for _, line in ipairs(wrap(text_lang, text, TEXT_SCALE)) do
    rows[#rows + 1] = {
      n = G.UIT.R,
      config = { align = "cl", padding = 0.02 },
      nodes = {
        { n = G.UIT.T, config = { text = line, scale = TEXT_SCALE, colour = G.C.UI.TEXT_LIGHT, shadow = true, lang = text_lang } },
      },
    }
  end
  -- 结构与 create_UIBox_notify_alert 相同: 内层 minw 很宽, 只露出左侧内容, 右侧留在屏幕外.
  return {
    n = G.UIT.ROOT,
    config = { align = "cl", r = 0.1, padding = 0.06, colour = G.C.UI.TRANSPARENT_DARK },
    nodes = {
      {
        n = G.UIT.R,
        config = { align = "cl", padding = 0.2, minw = 20, r = 0.1, colour = G.C.BLACK, outline = 1.5, outline_colour = G.C.GREY },
        nodes = {
          { n = G.UIT.C, config = { align = "cl", padding = 0.02 }, nodes = rows },
        },
      },
    },
  }
end

--- 显示时长: 基础 2.5s, 每字符 0.06s, 限制在 3~8s.
---@param text string
---@param duration number?
---@return number
function M.duration_for(text, duration)
  if type(duration) == "number" and duration > 0 then
    return math.min(duration, MAX_WALL)
  end
  return math.max(3, math.min(8, 2.5 + 0.06 * #utf8_chars(text)))
end

local function content_width(item)
  local inner = item.box.UIRoot.children[1]
  local column = inner and inner.children[1]
  return column and column.T.w or LINE_WIDTH
end

local function remove_item(item)
  if item.box and not item.box.REMOVED then
    item.box:remove()
  end
  item.box = nil
end

--- 显示一条消息.
---@param title string?
---@param text string
---@param duration number?
function M.push(title, text, duration)
  if not M.enabled or not G.ROOM_ATTACH or type(text) ~= "string" or text == "" then
    return
  end
  title = M.truncate(title and title ~= "" and title or "Agent", 40)
  text = M.truncate(text, MAX_CHARS)

  local box = UIBox({
    definition = build_definition(title, text),
    config = {
      align = "cr",
      offset = { x = 20, y = 0 },
      major = G.ROOM_ATTACH,
      bond = "Weak",
      instance_type = "POPUP",
      can_collide = false,
    },
  })
  box.bb_toast = true

  table.insert(items, 1, {
    box = box,
    attach = G.ROOM_ATTACH,
    age = 0,
    life = M.duration_for(text, duration),
    leave_at = nil,
  })
  -- 超出数量时最旧的一条立即滑出.
  for i = MAX_ITEMS + 1, #items do
    local old = items[i]
    old.leave_at = old.leave_at or old.age
  end
end

--- 是否还有通知显示在屏幕上 (含滑出过程), 录制据此判断活动期.
---@return boolean
function M.active()
  return #items > 0
end

--- 每帧调用, 放在游戏 update 之后. dt 为墙钟间隔.
---@param dt number
function M.update(dt)
  if #items == 0 then
    return
  end
  local kept = {}
  local y = 0
  for _, item in ipairs(items) do
    local box = item.box
    local alive = box and not box.REMOVED and item.attach == G.ROOM_ATTACH
    if alive then
      item.age = item.age + dt
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
        offset.x = 20
      elseif item.age >= ENTER_DELAY then
        offset.x = G.ROOM.T.x - content_width(item) - 0.8
      end
      -- 最新的在最上面, 旧的依次往下排. 从屏幕中线往上 2.6 开始, 两三条时也尽量不压到手牌.
      local h = box.T.h
      offset.y = -2.6 + y + h / 2
      y = y + h + GAP
      kept[#kept + 1] = item
    else
      remove_item(item)
    end
  end
  items = kept
end

--- 立即移除全部通知.
function M.clear()
  for _, item in ipairs(items) do
    remove_item(item)
  end
  items = {}
end

return M
