--[[
右上角竖排控制按钮 (BB_HUD): 内置 agent 运行时, 以及回放进行时.

- 按钮由各 mod 用 bind 登记, 每帧取一份 spec (按钮列表 + 是否挡住游戏输入).
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

---@param options {widgets: table}
function M.init(options)
  W = options.widgets
end

--- 登记一份按钮. fn 返回 {buttons, blocking}? 没有内容时返回 nil.
---@param id string
---@param fn fun(): {buttons: table[], blocking: boolean?}?
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
  view.box, view.attach, view.source, view.n = nil, nil, nil, 0
end

---@param spec table
local function create_box(spec)
  if not W or not G or not G.ROOM_ATTACH then
    return
  end
  local nodes = {}
  for i, button in ipairs(spec.buttons) do
    nodes[i] = W.button({
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
  if not view.box or view.source ~= id or view.n ~= #spec.buttons then
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
