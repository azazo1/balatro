--[[
运行控制入口: ESC 菜单的 "Agent" 按钮, Agent 面板, F9 快捷键.

- 按钮由 lovely 补丁 (lovely/agent_menu.toml) 在 create_UIBox_options 里调用 BB_AGENT_MENU.button() 插入,
  补丁里只有这一个调用, 显示与否等逻辑都在这里. 只在内置模式下显示.
- 按钮颜色跟随 runner 状态: 运行中绿色, 暂停金色, 出错与停止为原版按钮的红色 (标签文字区分两者).
- Agent 面板: 状态, 本局统计, 开始 / 暂停或继续 / 停止 / 前往设置.
- menu_entries 与 panel_extras 是给以后的 "回放" 按钮等预留的钩子, 目前只有 Agent 一项.
]]

---@type table agent/ui/widgets.lua, init 时注入
local W

local LOGGER = "BB.AGENT.MENU"

local M = {
  ---@type (fun(): table?)[] ESC 菜单里依次插入的按钮, 返回 nil 表示不显示
  menu_entries = {},
  ---@type (fun(): table?)[] Agent 面板按钮行之后追加的节点
  panel_extras = {},
}

---@class BBAgentMenuDeps
---@field mod table SMODS mod 对象
---@field mode table agent/mode.lua 的实例
---@field runner table agent/runner.lua
---@field stream table agent/ui/stream_bar.lua
---@field toast table agent/toast.lua
---@field widgets table agent/ui/widgets.lua (已 init)
local deps

local view = {
  state = "",
  notice = "",
  stats = "",
  error = "",
}

local function refresh()
  local runner = deps.runner
  local s = runner.stats
  view.state = "状态: " .. runner.label()
  view.notice = runner.notice or ""
  view.stats = string.format(
    "本局: 请求 %d 次, 重试 %d 次, token %d (输入 %d, 输出 %d)",
    s.requests,
    s.retries,
    s.run_tokens,
    s.prompt_tokens,
    s.completion_tokens
  )
  view.error = s.last_error ~= "" and ("最近错误: " .. s.last_error) or "最近错误: 无"
end

G.FUNCS.bb_agent_panel_refresh = function(_e)
  if deps then
    refresh()
  end
end

---@return table
local function state_colour()
  local state = deps.runner.state
  if state == "paused" then
    return G.C.GOLD
  elseif deps.runner.is_active() then
    return G.C.GREEN
  end
  return G.C.RED
end

local function panel_definition()
  local runner = deps.runner
  refresh()
  local buttons = {
    W.button({
      label = "开始",
      col = true,
      minw = 2,
      minh = 0.6,
      scale = 0.4,
      colour = G.C.GREEN,
      enabled = function()
        return not runner.is_busy()
      end,
      on_click = function()
        if runner.start() then
          -- 菜单开着时 loop 不执行动作, 开始后直接关掉.
          G.FUNCS.exit_overlay_menu()
        end
      end,
    }),
    W.button({
      label = "暂停",
      label_fn = function()
        return runner.state == "paused" and "继续" or "暂停"
      end,
      col = true,
      minw = 2,
      minh = 0.6,
      scale = 0.4,
      colour = G.C.GOLD,
      enabled = function()
        return runner.is_busy()
      end,
      on_click = function()
        runner.toggle_pause()
      end,
    }),
    W.button({
      label = "停止",
      col = true,
      minw = 2,
      minh = 0.6,
      scale = 0.4,
      colour = G.C.RED,
      enabled = function()
        return runner.state ~= "stopped"
      end,
      on_click = function()
        runner.stop()
      end,
    }),
  }
  local open_config = G.FUNCS["openModUI_" .. deps.mod.id]
  local nodes = {
    W.row({ W.text("内置 Agent", 0.5, G.C.FILTER) }, { align = "cm", padding = 0.05 }),
    W.row({ W.live(view, "state", 0.4) }, { align = "cm" }),
    W.row({ W.live(view, "notice", 0.3, G.C.UI.TEXT_INACTIVE) }, { align = "cm" }),
    W.row({ W.live(view, "stats", 0.32) }, { align = "cm" }),
    W.row({ W.live(view, "error", 0.32, G.C.RED) }, { align = "cm" }),
    W.row({ W.col(buttons, { align = "cm" }) }, { align = "cm", padding = 0.1 }),
  }
  if open_config then
    nodes[#nodes + 1] = W.button({
      label = "前往设置",
      minw = 3,
      minh = 0.6,
      scale = 0.4,
      colour = G.C.BLUE,
      on_click = function()
        open_config({ config = { page = "config" } })
      end,
    })
  end
  for _, extra in ipairs(M.panel_extras) do
    local ok, node = pcall(extra)
    if ok and node then
      nodes[#nodes + 1] = node
    end
  end
  return create_UIBox_generic_options({
    back_func = "options",
    contents = {
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.1, minw = 8, func = "bb_agent_panel_refresh" },
        nodes = { W.col(nodes, { align = "cm", padding = 0.05 }) },
      },
    },
  })
end

G.FUNCS.bb_agent_panel = function(_e)
  G.SETTINGS.paused = true
  G.FUNCS.overlay_menu({ definition = panel_definition() })
end

--- ESC 菜单的 Agent 按钮, 只在内置模式下显示.
---@return table?
local function agent_entry()
  if not deps.mode.is_builtin() then
    return nil
  end
  local runner = deps.runner
  -- 尺寸与 create_UIBox_options 里的 UIBox_button 一致.
  return W.button({
    label = "Agent",
    label_fn = function()
      return "Agent: " .. runner.label()
    end,
    minw = 5,
    minh = 0.9,
    scale = 0.5,
    padding = 0,
    outer_padding = 0,
    colour = state_colour,
    on_click = function()
      G.FUNCS.bb_agent_panel()
    end,
  })
end
M.menu_entries[1] = agent_entry

--- lovely 补丁调用: 返回要插进 ESC 菜单的节点, 没有时返回 nil.
---@return table?
function M.button()
  if not deps then
    return nil
  end
  local nodes = {}
  for _, entry in ipairs(M.menu_entries) do
    local ok, node = pcall(entry)
    if not ok then
      sendErrorMessage("Options menu entry failed: " .. tostring(node), LOGGER)
    elseif node then
      nodes[#nodes + 1] = node
    end
  end
  if #nodes <= 1 then
    return nodes[1]
  end
  -- 多个按钮时包成一行, 中间留出与原版按钮相同的间距.
  local spaced = {}
  for i, node in ipairs(nodes) do
    if i > 1 then
      spaced[#spaced + 1] = { n = G.UIT.R, config = { minh = 0.2 }, nodes = {} }
    end
    spaced[#spaced + 1] = node
  end
  return { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = spaced }
end

--- F9: 内置模式下切换暂停/继续.
function M.hotkey()
  if not deps or not deps.mode.is_builtin() then
    return
  end
  local runner = deps.runner
  if runner.is_busy() then
    runner.toggle_pause()
  else
    deps.stream.show_status("内置 agent 未运行, 在 选项 -> Agent 中开始", 2.5)
  end
end

---@param options BBAgentMenuDeps
function M.init(options)
  deps = options
  W = options.widgets
  SMODS.Keybind({
    key = "agent_pause",
    key_pressed = "f9",
    event = "pressed",
    action = function()
      local ok, err = pcall(M.hotkey)
      if not ok then
        sendErrorMessage("F9 handler failed: " .. tostring(err), LOGGER)
      end
    end,
  })
end

return M
