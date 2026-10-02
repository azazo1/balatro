--[[
右上角竖排控制按钮 (BB_HUD): 内置 agent 运行时, 以及回放进行时.

- 按钮由各 mod 用 bind 登记, 每帧取一份 spec (按钮列表, 可选最上方的状态文字和占用条).
  同时只有一方会占着游戏 (BB_CONTROL), 先返回非空 spec 的生效. 挡不挡游戏输入不归这里管,
  见 runtime/input/gate.lua 的策略.
- UIBox 挂在 G.ROOM_ATTACH 上 (POPUP 层), 再按 letterbox 推到窗口最右上角, 不贴在内容区边上.
  阶段切换重建 ROOM_ATTACH 时自己重建; loop 一停 spec 变空, 框立刻拆掉.
- 点在本框上的鼠标/触摸由输入门交给这里 (set_hud), 不交给游戏, 不受锁操作或回放锁影响:
  回放把游戏读到的光标停在左上角, 控制器上锁或光标落在 letterbox 外时, 游戏自己点不到这些按钮.
  与原版一样松开时才算点击: 按下与松开落在同一颗按钮上才触发, 按下后拖出去就取消.
- 悬停按真实光标位置算 (不经回放的停放); 触摸时没有手指在屏幕上就不悬停, 免得最后一次点按后一直亮着.
]]

local LOGGER = "BB.HUD"
local MARGIN = 0.2
local BTN_W = 1.7
local BTN_H = 0.52

local M = {}

---@type table bbcore 的 ui/widgets.lua
local W

---@type {id: string, fn: fun(): table?}[]
local binders = {}

local view = {
  box = nil,
  attach = nil,
  source = nil,
  n = 0,
  status = false,
  meter = false,
}

---@type table? bbcore 的 runtime/input/gate.lua, 取真实光标位置
local input

---@type table? 按下时落在的按钮, 松开时落在同一颗上才点
local pressed = nil

---@param dst table
---@param src table
local function copy_colour(dst, src)
  dst[1], dst[2], dst[3], dst[4] = src[1], src[2], src[3], src[4]
end

--- 占用条的填充宽度和颜色每帧刷新, 从左往右长, 不可点.
local function hud_meter(e)
  local ref = e.config.ref_table
  if not ref then
    return
  end
  local ratio = 0
  if type(ref.fill) == "function" then
    ratio = tonumber(ref.fill()) or 0
  elseif type(ref.fill) == "number" then
    ratio = ref.fill
  end
  if ratio < 0 then
    ratio = 0
  elseif ratio > 1 then
    ratio = 1
  end
  local parent = e.parent
  local pad = parent and parent.config and parent.config.padding or 0.05
  local maxw = BTN_W - pad * 2
  local h = BTN_H - pad * 2
  if parent and parent.T then
    if type(parent.T.w) == "number" then
      maxw = math.max(0, parent.T.w - pad * 2)
    end
    if type(parent.T.h) == "number" then
      h = math.max(0, parent.T.h - pad * 2)
    end
  end
  e.T.w = maxw * ratio
  e.T.h = h
  if e.VT then
    e.VT.w = e.T.w
    e.VT.h = e.T.h
  end
  local colour = type(ref.colour) == "function" and ref.colour() or ref.colour
  if type(colour) ~= "table" then
    return
  end
  if type(e.config.colour) ~= "table" then
    e.config.colour = { 1, 1, 1, 1 }
  end
  copy_colour(e.config.colour, colour)
end

--- 状态条的颜色, 文字每帧刷新; pulse 时按正弦闪.
local function hud_status(e)
  local ref = e.config.ref_table
  if not ref then
    return
  end
  if ref.label_fn then
    ref.label = ref.label_fn()
  end
  local colour = type(ref.colour) == "function" and ref.colour() or ref.colour
  if type(colour) ~= "table" then
    return
  end
  if type(e.config.colour) ~= "table" then
    e.config.colour = { 1, 1, 1, 1 }
  end
  copy_colour(e.config.colour, colour)
  if ref.pulse and ref.pulse() then
    local t = love.timer.getTime()
    local hz = type(ref.pulse_hz) == "function" and ref.pulse_hz() or (ref.pulse_hz or 6)
    e.config.colour[4] = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(t * hz * 2 * math.pi))
  end
end

---@param options {widgets: table, input: table?}
function M.init(options)
  W = options.widgets
  input = options.input
  if G and G.FUNCS then
    G.FUNCS.bb_hud_status = hud_status
    G.FUNCS.bb_hud_meter = hud_meter
  end
  if input then
    input.set_hud({ hit = M.hit, press = M.press, release = M.release })
  end
end

--- 登记一份按钮. fn 返回 {buttons, status, meter}? 没有内容时返回 nil.
--- status: {label, colour, pulse}? 画在最上方, 与按钮同宽的文字.
--- meter: {fill, colour}? 占用条, 画在状态和按钮之间, 与按钮同宽, 不可点. fill 为 0~1.
---@param id string
---@param fn fun(): {buttons: table[], status: table?, meter: table?}?
function M.bind(id, fn)
  for _, entry in ipairs(binders) do
    if entry.id == id then
      entry.fn = fn
      return
    end
  end
  binders[#binders + 1] = { id = id, fn = fn }
end

---@return string? id
---@return table? spec
local function resolve()
  for _, entry in ipairs(binders) do
    local ok, spec = pcall(entry.fn)
    if not ok then
      sendErrorMessage("HUD binder " .. entry.id .. " failed: " .. tostring(spec), LOGGER)
    elseif spec and spec.buttons and #spec.buttons > 0 then
      return entry.id, spec
    end
  end
  return nil, nil
end

--- 像素点是否落在矩形内 (含边).
---@param x number
---@param y number
---@param rect {x: number, y: number, w: number, h: number}
---@return boolean
function M.point_in_rect(x, y, rect)
  return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h
end

---@return number
local function tile_scale()
  return (G and G.TILESCALE or 1) * (G and G.TILESIZE or 1)
end

--- 房间坐标换成窗口像素. 绘制时 container 会再加 letterbox, 命中检测也要加上.
---@param t {x: number, y: number, w: number, h: number}
---@param room {x: number, y: number}?
---@return {x: number, y: number, w: number, h: number}?
function M.screen_rect(t, room)
  if type(t) ~= "table" then
    return nil
  end
  local scale = tile_scale()
  if scale <= 0 then
    return nil
  end
  room = room or (G and G.ROOM and G.ROOM.T)
  local ox = room and room.x or 0
  local oy = room and room.y or 0
  return { x = (ox + t.x) * scale, y = (oy + t.y) * scale, w = t.w * scale, h = t.h * scale }
end

--- 贴窗口最右上: ROOM_ATTACH 的 tri 是内容区右上, 再按 letterbox 推进黑边.
---@return {x: number, y: number}
function M.window_offset()
  local room = G and G.ROOM and G.ROOM.T
  if not room then
    return { x = -MARGIN, y = MARGIN }
  end
  return { x = (room.x or 0) - MARGIN, y = MARGIN - (room.y or 0) }
end

---@return {x: number, y: number, w: number, h: number}?
local function box_rect()
  local box = view.box
  if not box or box.REMOVED or not box.T then
    return nil
  end
  return M.screen_rect(box.T)
end

--- 像素坐标是否点在 HUD 框上.
---@param x number?
---@param y number?
---@return boolean
function M.hit(x, y)
  if type(x) ~= "number" or type(y) ~= "number" then
    return false
  end
  local rect = box_rect()
  return rect ~= nil and M.point_in_rect(x, y, rect)
end

--- 是不是 widgets.button 建的按钮. 认 func 而不认 config.button: 禁用或选中时 bb_button_state 会把
--- config.button 清空, 认它的话按钮会从命中与悬停里消失.
---@param node table
---@return boolean
function M.is_button(node)
  return type(node) == "table" and type(node.config) == "table" and node.config.func == "bb_button_state"
end

---@param node table?
---@param fn fun(node: table)
local function each_button(node, fn)
  if type(node) ~= "table" then
    return
  end
  if M.is_button(node) then
    fn(node)
  end
  if node.UIRoot then
    each_button(node.UIRoot, fn)
  end
  if type(node.children) == "table" then
    for _, child in pairs(node.children) do
      each_button(child, fn)
    end
  end
end

---@param x number
---@param y number
---@return table?
local function button_at(x, y)
  local found
  each_button(view.box, function(node)
    if found or not node.T then
      return
    end
    local rect = M.screen_rect(node.T)
    if rect and M.point_in_rect(x, y, rect) then
      found = node
    end
  end)
  return found
end

---@param node table
---@param hover boolean
local function set_hover(node, hover)
  if not node.states or not node.states.hover then
    return
  end
  if hover and not node.states.hover.is then
    node.states.hover.is = true
    if node.hover then
      node:hover()
    end
  elseif not hover and node.states.hover.is then
    node.states.hover.is = false
    if node.stop_hover then
      node:stop_hover()
    end
  end
end

--- 悬停用的指针位置: 真实光标 (不经回放的停放). 触摸时屏幕上没有手指就没有指针,
--- 否则 SDL 的鼠标位置停在最后一次触点, 按钮会一直亮着.
---@return number? x
---@return number? y
local function pointer()
  local hid = G and G.CONTROLLER and G.CONTROLLER.HID
  if hid and hid.touch then
    local touch = love and love.touch
    if not (touch and touch.getTouches and next(touch.getTouches()) ~= nil) then
      return nil, nil
    end
  end
  if input then
    return input.real_position()
  end
  if love and love.mouse and love.mouse.getPosition then
    return love.mouse.getPosition()
  end
  return nil, nil
end

local function refresh_hover()
  if not view.box then
    return
  end
  local x, y = pointer()
  local target = nil
  if type(x) == "number" and type(y) == "number" and M.hit(x, y) then
    target = button_at(x, y)
  end
  each_button(view.box, function(node)
    set_hover(node, node == target)
    if G and G.FUNCS and G.FUNCS.bb_button_state then
      G.FUNCS.bb_button_state(node)
    end
  end)
end

--- 输入门交来的按下 (已确认落在框上): 记下落在哪颗按钮上, 松开时再点. 只认左键 (触摸也是 1).
---@param ev table runtime/input/events.lua 的事件
function M.press(ev)
  pressed = nil
  if ev.button ~= nil and ev.button ~= 1 then
    return
  end
  pressed = button_at(ev.x, ev.y)
end

--- 只给测试用: 直接换掉当前的框.
---@param box table?
function M._set_box(box)
  view.box = box
  pressed = nil
end

--- 输入门交来的松开 (它的按下落在框上): 与按下落在同一颗按钮上才点, 与原版一样.
--- 禁用的按钮 config.button 为空, UIElement:click 什么也不做.
---@param ev table
function M.release(ev)
  local node = pressed
  pressed = nil
  if not node or node.REMOVED or not node.click then
    return
  end
  if type(ev.x) == "number" and type(ev.y) == "number" and button_at(ev.x, ev.y) == node then
    node:click()
  end
end

local function remove_box()
  pressed = nil
  if view.box and not view.box.REMOVED then
    view.box:remove()
  end
  view.box, view.attach, view.source, view.n, view.status, view.meter = nil, nil, nil, 0, false, false
end

---@param status table
---@return table
local function status_node(status)
  local fill = { 1, 1, 1, 1 }
  local initial = type(status.colour) == "function" and status.colour() or status.colour or G.C.GREEN
  copy_colour(fill, initial)
  local ref = {
    label = type(status.label) == "function" and status.label() or (status.label or ""),
    label_fn = type(status.label) == "function" and status.label or nil,
    colour = status.colour,
    pulse = status.pulse,
    pulse_hz = status.pulse_hz,
  }
  local text_colour = { G.C.UI.TEXT_LIGHT[1], G.C.UI.TEXT_LIGHT[2], G.C.UI.TEXT_LIGHT[3], G.C.UI.TEXT_LIGHT[4] }
  return {
    n = G.UIT.R,
    config = { align = "cm", padding = 0.03 },
    nodes = {
      {
        n = G.UIT.C,
        config = {
          align = "cm",
          padding = 0.05,
          r = 0.1,
          colour = fill,
          minw = BTN_W,
          minh = BTN_H,
          emboss = 0.05,
          func = "bb_hud_status",
          ref_table = ref,
        },
        nodes = {
          {
            n = G.UIT.T,
            config = {
              ref_table = ref,
              ref_value = "label",
              scale = 0.34,
              colour = text_colour,
              shadow = true,
              lang = W.cjk_lang(),
            },
          },
        },
      },
    },
  }
end

--- 占用条: 和按钮同宽同高, 深底, 从左往右填色. 没有 button, 点上去不会触发.
---@param meter table
---@return table
local function meter_node(meter)
  local fill = { 1, 1, 1, 1 }
  local initial = type(meter.colour) == "function" and meter.colour() or meter.colour or G.C.BLUE
  if type(initial) == "table" then
    copy_colour(fill, initial)
  end
  local track = { 0.2, 0.2, 0.2, 1 }
  local dark = G.C and G.C.L_BLACK
  if type(dark) == "table" then
    copy_colour(track, dark)
  end
  local ref = {
    fill = meter.fill,
    colour = meter.colour,
  }
  return {
    n = G.UIT.R,
    config = { align = "cm", padding = 0.03 },
    nodes = {
      {
        n = G.UIT.C,
        config = {
          -- 不能带 "c" (垂直居中): 布局时填充块高度为 0, 居中会把它的上沿放到轨道中线附近,
          -- 之后 hud_meter 再把高度设满, 填充块就整体往下错出轨道. 靠左上, 上沿留 padding.
          align = "tl",
          padding = 0.05,
          r = 0.1,
          colour = track,
          minw = BTN_W,
          minh = BTN_H,
          emboss = 0.05,
        },
        nodes = {
          {
            n = G.UIT.C,
            config = {
              align = "cm",
              r = 0.1,
              colour = fill,
              minw = 0,
              minh = 0,
              func = "bb_hud_meter",
              ref_table = ref,
            },
            nodes = {},
          },
        },
      },
    },
  }
end

---@param spec table
local function create_box(spec)
  if not W or not G or not G.ROOM_ATTACH then
    return
  end
  local nodes = {}
  if spec.status then
    nodes[#nodes + 1] = status_node(spec.status)
  end
  if spec.meter then
    nodes[#nodes + 1] = meter_node(spec.meter)
  end
  for _, button in ipairs(spec.buttons) do
    nodes[#nodes + 1] = W.button({
      label = button.label,
      label_fn = button.label_fn,
      on_click = button.on_click,
      colour = button.colour,
      selected = button.selected,
      selected_colour = button.selected_colour,
      minw = BTN_W,
      minh = BTN_H,
      scale = 0.34,
      padding = 0.05,
      outer_padding = 0.03,
    })
  end
  local offset = M.window_offset()
  view.box = UIBox({
    definition = {
      n = G.UIT.ROOT,
      config = { align = "cm", colour = G.C.CLEAR, padding = 0 },
      nodes = nodes,
    },
    config = {
      align = "tri",
      offset = offset,
      major = G.ROOM_ATTACH,
      bond = "Weak",
      instance_type = "POPUP",
    },
  })
  view.box.bb_hud = true
  view.attach = G.ROOM_ATTACH
  view.source = spec.id
  view.n = #spec.buttons
  view.status = spec.status ~= nil
  view.meter = spec.meter ~= nil
end

local function apply_offset()
  local box = view.box
  if not box or box.REMOVED or not box.alignment or not box.alignment.offset then
    return
  end
  local offset = M.window_offset()
  box.alignment.offset.x = offset.x
  box.alignment.offset.y = offset.y
end

--- 每帧调用, 放在游戏 update 之后.
function M.update()
  if view.box and (view.box.REMOVED or view.attach ~= G.ROOM_ATTACH) then
    if view.box and not view.box.REMOVED then
      view.box:remove()
    end
    view.box, view.attach = nil, nil
  end
  local id, spec = resolve()
  if not spec then
    remove_box()
    return
  end
  spec.id = id
  local has_status = spec.status ~= nil
  local has_meter = spec.meter ~= nil
  if not view.box or view.source ~= id or view.n ~= #spec.buttons or view.status ~= has_status or view.meter ~= has_meter then
    remove_box()
    create_box(spec)
  end
  apply_offset()
  refresh_hover()
end

return M
