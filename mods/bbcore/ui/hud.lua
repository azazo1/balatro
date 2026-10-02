--[[
右上角竖排控制按钮 (BB_HUD): 内置 agent 运行时, 以及回放进行时.

- 按钮由各 mod 用 bind 登记, 每帧取一份 spec (按钮列表 + 是否挡住游戏输入, 可选最上方的状态图标).
  同时只有一方会占着游戏 (BB_CONTROL), 先返回非空 spec 的生效.
- UIBox 挂在 G.ROOM_ATTACH 右上角 (POPUP 层, 可点), 阶段切换重建 ROOM_ATTACH 时自己重建.
- 挡住输入时仍放行点在本框上的鼠标/触摸, 以及 Esc / F9; 移动光标不拦, 方便看牌.
  钩子在 after_load 里装, 包在回放输入锁之外.
]]

local LOGGER = "BB.HUD"

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
  status = "",
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

--- 状态图标的颜色每帧刷新; pulse 时按正弦闪.
local function hud_status(e)
  local ref = e.config.ref_table
  if not ref then
    return
  end
  local colour = type(ref.colour) == "function" and ref.colour() or ref.colour
  if type(colour) ~= "table" then
    return
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
--- status: {kind = "dot"|"pause", colour, pulse}? 画在按钮上方, 不含文字.
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

---@return {x: number, y: number, w: number, h: number}?
local function box_rect()
  local box = view.box
  if not box or box.REMOVED or not box.T then
    return nil
  end
  local scale = (G.TILESCALE or 1) * (G.TILESIZE or 1)
  if scale <= 0 then
    return nil
  end
  return { x = box.T.x * scale, y = box.T.y * scale, w = box.T.w * scale, h = box.T.h * scale }
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

--- 这个输入事件要不要交给游戏. 点在 HUD 上, 没开阻挡, Esc/F9, 移动光标: 都放行.
---@param name string
---@param a any
---@param b any
---@param c any
---@return boolean
function M.should_pass(name, a, b, c)
  local x, y = event_xy(name, a, b, c)
  if x and M.hit(x, y) then
    return true
  end
  if not M.blocking() then
    return true
  end
  if (name == "keypressed" or name == "keyreleased") and (a == "escape" or a == "f9") then
    return true
  end
  if name == "mousemoved" or name == "touchmoved" then
    return true
  end
  return false
end

local function remove_box()
  if view.box and not view.box.REMOVED then
    view.box:remove()
  end
  view.box, view.attach, view.source, view.n, view.status = nil, nil, nil, 0, ""
end

---@param status table
---@return table
local function status_node(status)
  local fill = { 1, 1, 1, 1 }
  local initial = type(status.colour) == "function" and status.colour() or status.colour or G.C.GREEN
  copy_colour(fill, initial)
  local ref = {
    colour = status.colour,
    pulse = status.pulse,
    pulse_hz = status.pulse_hz,
  }
  local mark
  if status.kind == "pause" then
    local fill2 = { fill[1], fill[2], fill[3], fill[4] }
    local bar = function(colour)
      return {
        n = G.UIT.C,
        config = {
          minw = 0.12,
          minh = 0.4,
          r = 0.04,
          colour = colour,
          emboss = 0.04,
          func = "bb_hud_status",
          ref_table = ref,
        },
      }
    end
    mark = {
      bar(fill),
      { n = G.UIT.C, config = { minw = 0.1, minh = 0.4, colour = G.C.CLEAR } },
      bar(fill2),
    }
  else
    mark = {
      {
        n = G.UIT.C,
        config = {
          minw = 0.48,
          minh = 0.48,
          r = 0.24,
          colour = fill,
          emboss = 0.05,
          func = "bb_hud_status",
          ref_table = ref,
        },
      },
    }
  end
  return {
    n = G.UIT.R,
    config = { align = "cm", minw = 1.7, minh = 0.56, padding = 0.04 },
    nodes = mark,
  }
end

---@param spec table
---@return string
local function status_kind(spec)
  return spec.status and (spec.status.kind or "dot") or ""
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
  view.box = UIBox({
    definition = {
      n = G.UIT.ROOT,
      config = { align = "cm", colour = G.C.CLEAR, padding = 0 },
      nodes = nodes,
    },
    config = {
      align = "tri",
      offset = { x = -0.12, y = 0.12 },
      major = G.ROOM_ATTACH,
      bond = "Weak",
      instance_type = "POPUP",
    },
  })
  view.box.bb_hud = true
  view.attach = G.ROOM_ATTACH
  view.source = spec.id
  view.n = #spec.buttons
  view.status = status_kind(spec)
end

--- 每帧调用, 放在游戏 update 之后.
function M.update()
  if view.box and (view.box.REMOVED or view.attach ~= G.ROOM_ATTACH) then
    view.box, view.attach = nil, nil
  end
  local id, spec = resolve()
  if not spec then
    remove_box()
    return
  end
  spec.id = id
  if not view.box or view.source ~= id or view.n ~= #spec.buttons or view.status ~= status_kind(spec) then
    remove_box()
    create_box(spec)
  end
end

--- 包在其它输入钩子之外. 挡住时丢弃游戏操作, HUD 自己的点击仍交给游戏.
function M.install_input()
  if input_installed then
    return
  end
  input_installed = true
  for _, name in ipairs(DROPPED) do
    local original = love[name]
    love[name] = function(a, b, c, ...)
      if M.should_pass(name, a, b, c) then
        return original and original(a, b, c, ...)
      end
    end
  end
end

return M
