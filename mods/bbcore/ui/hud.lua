--[[
右上角竖排控制按钮 (BB_HUD): 内置 agent 运行时, 以及回放进行时.

- 按钮由各 mod 用 bind 登记, 每帧取一份 spec (按钮列表 + 是否挡住游戏输入, 可选最上方的状态文字).
  同时只有一方会占着游戏 (BB_CONTROL), 先返回非空 spec 的生效.
- UIBox 挂在 G.ROOM_ATTACH 上 (POPUP 层, 可点), 再按 letterbox 推到窗口最右上角, 不贴在内容区边上.
  阶段切换重建 ROOM_ATTACH 时自己重建; loop 一停 spec 变空, 框立刻拆掉.
- 挡住输入时仍放行 Esc / F9; 移动光标不拦, 方便看牌.
  点在本框上的鼠标/触摸由 HUD 自己点按钮 (悬停, 按下, 换文字), 不交给游戏:
  回放把光标停在左上角, 控制器上锁或光标落在 letterbox 外时, 游戏自己点不到这些按钮.
  钩子在 after_load 里装, 包在回放输入锁之外.
]]

local LOGGER = "BB.HUD"
local MARGIN = 0.2

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
}

local input_installed = false

local DROPPED = {
  "mousepressed",
  "mousereleased",
  "wheelmoved",
  "keypressed",
  "keyreleased",
  "textinput",
  "gamepadpressed",
  "gamepadreleased",
  "gamepadaxis",
  "joystickpressed",
  "joystickreleased",
  "joystickaxis",
  "touchpressed",
  "touchreleased",
}

---@param dst table
---@param src table
local function copy_colour(dst, src)
  dst[1], dst[2], dst[3], dst[4] = src[1], src[2], src[3], src[4]
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

---@param options {widgets: table}
function M.init(options)
  W = options.widgets
  if G and G.FUNCS then
    G.FUNCS.bb_hud_status = hud_status
  end
end

--- 登记一份按钮. fn 返回 {buttons, blocking, status}? 没有内容时返回 nil.
--- status: {label, colour, pulse}? 画在按钮上方, 与按钮同宽的文字.
---@param id string
---@param fn fun(): {buttons: table[], blocking: boolean?, status: table?}?
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

---@param name string
---@param a any
---@param b any
---@param c any
---@return number?
---@return number?
local function event_xy(name, a, b, c)
  if name == "touchpressed" or name == "touchreleased" or name == "touchmoved" then
    return b, c
  end
  if name == "mousepressed" or name == "mousereleased" or name == "mousemoved" then
    return a, b
  end
  return nil, nil
end

--- 当前生效的 spec 是否要挡住游戏输入.
---@return boolean
function M.blocking()
  local _, spec = resolve()
  return spec ~= nil and spec.blocking == true
end

--- 这个输入事件要不要交给游戏. 没开阻挡, Esc/F9, 移动光标: 都放行.
--- 点在 HUD 上的按下/松开由 handle_pointer 自己消化, 不走这里.
---@param name string
---@param a any
---@param b any
---@param c any
---@return boolean
function M.should_pass(name, a, b, c)
  if not M.blocking() then
    return true
  end
  if (name == "keypressed" or name == "keyreleased") and (a == "escape" or a == "f9") then
    return true
  end
  if name == "mousemoved" or name == "touchmoved" then
    return true
  end
  local x, y = event_xy(name, a, b, c)
  if x and M.hit(x, y) then
    return true
  end
  return false
end

---@param node table?
---@param fn fun(node: table)
local function each_button(node, fn)
  if type(node) ~= "table" then
    return
  end
  if node.config and node.config.button then
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

local function refresh_hover()
  if not view.box or not love or not love.mouse or not love.mouse.getPosition then
    return
  end
  local x, y = love.mouse.getPosition()
  if type(x) ~= "number" or type(y) ~= "number" then
    return
  end
  local target = M.hit(x, y) and button_at(x, y) or nil
  each_button(view.box, function(node)
    set_hover(node, node == target)
    if node.config and node.config.func == "bb_button_state" and G and G.FUNCS and G.FUNCS.bb_button_state then
      G.FUNCS.bb_button_state(node)
    end
  end)
end

--- HUD 自己点按钮, 不把按下交给游戏 (回放光标停在左上角, letterbox 外控制器也不碰这些节点).
---@param name string
---@param a any
---@param b any
---@param c any
---@return boolean consumed
local function handle_pointer(name, a, b, c)
  local x, y = event_xy(name, a, b, c)
  if not x then
    return false
  end
  if name == "mousemoved" or name == "touchmoved" then
    if M.hit(x, y) then
      refresh_hover()
    end
    return false
  end
  if not M.hit(x, y) then
    return false
  end
  if name == "mousepressed" or name == "touchpressed" then
    -- 鼠标第三个参数是按键, 触摸没有, 只响应左键.
    if name == "mousepressed" and c ~= nil and c ~= 1 then
      return true
    end
    local node = button_at(x, y)
    if node and node.click then
      node:click()
    end
    return true
  end
  if name == "mousereleased" or name == "touchreleased" then
    return true
  end
  return false
end

local function remove_box()
  if view.box and not view.box.REMOVED then
    view.box:remove()
  end
  view.box, view.attach, view.source, view.n, view.status = nil, nil, nil, 0, false
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
          minw = 1.7,
          minh = 0.52,
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

---@param spec table
local function create_box(spec)
  if not W or not G or not G.ROOM_ATTACH then
    return
  end
  local nodes = {}
  if spec.status then
    nodes[#nodes + 1] = status_node(spec.status)
  end
  for _, button in ipairs(spec.buttons) do
    nodes[#nodes + 1] = W.button({
      label = button.label,
      label_fn = button.label_fn,
      on_click = button.on_click,
      colour = button.colour,
      selected = button.selected,
      selected_colour = button.selected_colour,
      minw = 1.7,
      minh = 0.52,
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
  if not view.box or view.source ~= id or view.n ~= #spec.buttons or view.status ~= has_status then
    remove_box()
    create_box(spec)
  end
  apply_offset()
  refresh_hover()
end

--- 包在其它输入钩子之外. 挡住时丢弃游戏操作; HUD 自己的点击不交给游戏.
function M.install_input()
  if input_installed then
    return
  end
  input_installed = true
  for _, name in ipairs(DROPPED) do
    local original = love[name]
    love[name] = function(a, b, c, ...)
      if handle_pointer(name, a, b, c) then
        return
      end
      if M.should_pass(name, a, b, c) then
        return original and original(a, b, c, ...)
      end
    end
  end
end

return M
