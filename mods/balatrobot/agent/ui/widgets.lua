--[[
设置页与 Agent 面板共用的 UI 小部件, 按原版 UI 定义表的写法生成节点.

- 中文文字要用带中日韩字形的字体: 文本节点都经 toast.pick_lang 选 lang; 原版部件 (create_toggle 等)
  生成的定义用 localize_tree 补上.
- 按钮的颜色, 可点与否, 标签文字每帧由 G.FUNCS.bb_button_state 按 ref 表里的函数刷新,
  与原版 can_play 这类 func 的做法一致, 菜单不用重建就能跟着状态变.
]]

local M = {}

---@type table toast 模块, 提供 pick_lang
local toast

---@param options {toast: table}
function M.init(options)
  toast = options.toast
end

---@return table 带中日韩字形的 lang
function M.cjk_lang()
  return toast.pick_lang("中")
end

--- 给定义树里含非 ASCII 字符的文本节点补上 lang.
---@param node table?
---@return table?
function M.localize_tree(node)
  if type(node) ~= "table" then
    return node
  end
  local config = node.config
  if node.n == G.UIT.T and config and type(config.text) == "string" and not config.lang then
    config.lang = toast.pick_lang(config.text)
  end
  if type(node.nodes) == "table" then
    for _, child in pairs(node.nodes) do
      M.localize_tree(child)
    end
  end
  return node
end

---@param text string
---@param scale number?
---@param colour table?
---@return table
function M.text(text, scale, colour)
  return {
    n = G.UIT.T,
    config = { text = text, scale = scale or 0.32, colour = colour or G.C.UI.TEXT_LIGHT, lang = toast.pick_lang(text) },
  }
end

--- 跟随 ref_table[ref_value] 变化的文字. 内容可能变成中文, 固定用中日韩字体.
---@param ref_table table
---@param ref_value string
---@param scale number?
---@param colour table?
---@return table
function M.live(ref_table, ref_value, scale, colour)
  return {
    n = G.UIT.T,
    config = {
      ref_table = ref_table,
      ref_value = ref_value,
      scale = scale or 0.32,
      colour = colour or G.C.UI.TEXT_LIGHT,
      lang = M.cjk_lang(),
    },
  }
end

---@param nodes table[]
---@param config table?
---@return table
function M.row(nodes, config)
  config = config or {}
  config.align = config.align or "cl"
  config.padding = config.padding or 0.03
  return { n = G.UIT.R, config = config, nodes = nodes }
end

---@param nodes table[]
---@param config table?
---@return table
function M.col(nodes, config)
  config = config or {}
  config.align = config.align or "cl"
  config.padding = config.padding or 0
  return { n = G.UIT.C, config = config, nodes = nodes }
end

---@param text string
---@return table
function M.title(text)
  return M.row({ M.text(text, 0.4, G.C.FILTER) }, { padding = 0.05 })
end

---@class BBButtonArgs
---@field label string 初始标签
---@field label_fn (fun(): string)? 每帧刷新标签
---@field on_click fun(e: table)
---@field enabled (fun(): boolean)? 不可点时变灰
---@field selected (fun(): boolean)? 单选按钮的选中态, 选中时用 selected_colour 且不可点
---@field colour (table|fun(): table)? 默认 G.C.L_BLACK
---@field selected_colour table? 默认 G.C.RED
---@field minw number?
---@field minh number?
---@field scale number?
---@field col boolean? 作为列排列 (横排按钮)
---@field padding number? 按钮内边距, 默认 0.06
---@field outer_padding number? 按钮外边距, 默认 0.04

--- 按钮, 外观与 UIBox_button 一致 (圆角, 阴影, 悬停).
---@param args BBButtonArgs
---@return table
function M.button(args)
  local ref = {
    label = args.label,
    label_fn = args.label_fn,
    on_click = args.on_click,
    enabled = args.enabled,
    selected = args.selected,
    colour = args.colour or G.C.L_BLACK,
    selected_colour = args.selected_colour or G.C.RED,
    text_colour = { G.C.UI.TEXT_LIGHT[1], G.C.UI.TEXT_LIGHT[2], G.C.UI.TEXT_LIGHT[3], G.C.UI.TEXT_LIGHT[4] },
  }
  local initial = type(ref.colour) == "function" and ref.colour() or ref.colour
  local scale = args.scale or 0.32
  return {
    n = args.col and G.UIT.C or G.UIT.R,
    config = { align = "cm", padding = args.outer_padding or 0.04 },
    nodes = {
      {
        n = G.UIT.C,
        config = {
          align = "cm",
          padding = args.padding or 0.06,
          r = 0.1,
          hover = true,
          shadow = true,
          colour = initial,
          minw = args.minw or 1.2,
          minh = args.minh or 0.45,
          button = "bb_button_click",
          func = "bb_button_state",
          ref_table = ref,
        },
        nodes = {
          {
            n = G.UIT.T,
            config = { ref_table = ref, ref_value = "label", scale = scale, colour = ref.text_colour, shadow = true, lang = M.cjk_lang() },
          },
        },
      },
    },
  }
end

---@param dst table
---@param src table
local function copy_colour(dst, src)
  dst[1], dst[2], dst[3], dst[4] = src[1], src[2], src[3], src[4]
end

G.FUNCS.bb_button_state = function(e)
  local ref = e.config.ref_table
  if not ref then
    return
  end
  local enabled = ref.enabled == nil or ref.enabled()
  local selected = ref.selected ~= nil and ref.selected()
  if selected then
    e.config.colour = ref.selected_colour
  elseif enabled then
    e.config.colour = type(ref.colour) == "function" and ref.colour() or ref.colour
  else
    e.config.colour = G.C.UI.BACKGROUND_INACTIVE
  end
  e.config.button = (enabled and not selected) and "bb_button_click" or nil
  copy_colour(ref.text_colour, (enabled or selected) and G.C.UI.TEXT_LIGHT or G.C.UI.TEXT_INACTIVE)
  if ref.label_fn then
    ref.label = ref.label_fn()
  end
end

G.FUNCS.bb_button_click = function(e)
  local ref = e.config.ref_table
  if ref and ref.on_click then
    local ok, err = pcall(ref.on_click, e)
    if not ok then
      sendErrorMessage("Button callback failed: " .. tostring(err), "BB.AGENT.UI")
    end
  end
end

--- 单选按钮组, 返回一列 (G.UIT.C) 横排的按钮. 单独占一行时用 M.row 包起来:
--- 行 (R) 的子节点是竖排的, 列 (C) 的子节点才横排.
--- options: { {value, label}, ... }.
---@param options {[1]: any, [2]: string}[]
---@param current fun(): any
---@param on_select fun(value: any)
---@param opts {enabled: (fun(value: any): boolean)?, minw: number?, scale: number?}?
---@return table
function M.radio(options, current, on_select, opts)
  opts = opts or {}
  local nodes = {}
  for i, option in ipairs(options) do
    local value, label = option[1], option[2]
    nodes[i] = M.button({
      label = label,
      col = true,
      minw = opts.minw or 1.2,
      scale = opts.scale,
      selected = function()
        return current() == value
      end,
      enabled = opts.enabled and function()
        return opts.enabled(value)
      end or nil,
      on_click = function()
        on_select(value)
      end,
    })
  end
  return M.col(nodes, { align = "cm" })
end

return M
