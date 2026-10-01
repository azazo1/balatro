--[[
mod 设置页 (模组 -> BalatroBot -> 配置), 即 MOD.config_tab.

左列: agent 模式与内置 agent 的配置 (endpoint, 模型名, 鉴权方式, key, 单局 token 上限, 赢后处理, 策略).
右列: 显示, 开发开关, 状态行. 录像与回放的设置在 bbreplay 自己的设置页.

- 原版文本框的字符表没有 '/', 还会把 '0' 改成 'o', 所以 endpoint, 模型名, key, 策略都用 "从剪贴板粘贴" 输入.
  策略还能复制回剪贴板, 改完再粘回来.
- key 只显示掩码, 不写进日志. 配置以明文存在存档目录的 config/balatrobot.jkr.
- 状态行等文字每帧由根节点的 func 刷新, 按钮的可点与颜色由 widgets 的 bb_button_state 刷新.
]]

---@type table bbcore 的 ui/widgets.lua, init 时注入
local W
local Fields = assert(SMODS.load_file("agent/ui/fields.lua", "balatrobot"))()
-- stream_text 是纯函数, 每次加载各得一份也没关系.
local Text = assert(SMODS.load_file("ui/stream_text.lua", "bbcore"))()

local LOGGER = "BB.AGENT.SETTINGS"

local M = {}

local COL_W = 6.2 -- 每列宽度
local LABEL_W = 1.3 -- 行首标签宽度
local VALUE_W = 2.9 -- 当前值宽度
local STRATEGY_W = 1.9 -- 策略预览宽度: 比 VALUE_W 窄, 行尾多了复制与清除两个按钮, 整行与 key 一行等宽
local SCALE = 0.3

---@class BBSettingsDeps
---@field mod table SMODS mod 对象
---@field modes table agent/mode.lua 模块
---@field mode table agent/mode.lua 的实例
---@field runner table agent/runner.lua
---@field toast table bbcore 的 runtime/toast.lua
---@field agent table BB_AGENT
---@field widgets table bbcore 的 ui/widgets.lua (已 init)
local deps

-- 界面上显示的文字, 由 refresh 与 refresh_values 更新.
local view = {
  endpoint = "",
  model = "",
  key = "",
  strategy = "",
  seed = "",
  mode_note = "",
  action_note = "",
  agent_line = "",
  runner_line = "",
  error_line = "",
}

local AGENT_STATUS = {
  listening = "监听中",
  ["bind failed"] = "端口绑定失败",
  off = "未监听",
  ["off (replaying)"] = "回放中, 未监听",
}

---@param options BBSettingsDeps
function M.init(options)
  deps = options
  W = options.widgets
end

local function config()
  return deps.mod.config
end

local function save()
  SMODS.save_mod_config(deps.mod)
end

local measures = {}

--- 按显示宽度截取开头.
---@param text string
---@param width number?
---@param scale number?
---@return string
local function fit(text, width, scale)
  scale = scale or SCALE
  local lang = W.cjk_lang()
  local key = tostring(lang) .. scale
  local measure = measures[key]
  if not measure then
    measure = Text.cached(function(ch)
      return deps.toast.text_width(lang, ch, scale)
    end)
    measures[key] = measure
  end
  return Text.head(text, width or VALUE_W, measure)
end

-- 错误文字可能很长, 只在变化时重新截取.
local error_source, error_fitted = nil, ""

-- 配置值只在变化时 (打开页面, 粘贴, 清除) 重算, 不每帧测宽.
local function refresh_values()
  local c = config()
  view.endpoint = (c.endpoint and c.endpoint ~= "") and fit(c.endpoint) or "未设置"
  view.model = (c.model and c.model ~= "") and fit(c.model) or "未设置"
  view.key = Fields.mask_key(c.api_key)
  local preview = Fields.strategy_preview(c.strategy)
  view.strategy = preview and fit(preview, STRATEGY_W) or "未设置"
  view.seed = (c.seed and c.seed ~= "") and c.seed or "随机"
end

-- 状态行每帧刷新, 只做字符串拼接.
local function refresh_status()
  local mode, runner = deps.mode, deps.runner
  local locked = mode.lock_reason()
  if locked then
    view.mode_note = "已锁定: " .. locked
  elseif runner.is_busy() then
    view.mode_note = "内置 agent 运行中, 先停止才能切换"
  else
    view.mode_note = "外部与内置互斥, 两者之间切换要先选关闭"
  end

  local status = deps.agent.status
  if mode.current == "external" then
    view.agent_line = "接口: " .. deps.agent.address .. " " .. (AGENT_STATUS[status] or status)
  elseif mode.current == "builtin" then
    view.agent_line = "接口: 不监听 (内置模式)"
  else
    view.agent_line = "接口: " .. (AGENT_STATUS[status] or status)
  end

  if mode.current == "builtin" then
    local s = runner.stats
    view.runner_line = string.format(
      "内置: %s, 请求 %d 次, token %d",
      runner.label(),
      s.requests,
      s.prompt_tokens + s.completion_tokens
    )
    local source = s.last_error ~= "" and ("最近错误: " .. s.last_error) or (runner.notice or "")
    if source ~= error_source then
      error_source = source
      error_fitted = fit(source, COL_W - 0.2, 0.28)
    end
    view.error_line = error_fitted
  else
    view.runner_line = "内置: 未启用"
    view.error_line = ""
  end
end

G.FUNCS.bb_settings_refresh = function(_e)
  if deps then
    refresh_status()
  end
end

---@param field string endpoint / model / api_key
local function paste(field)
  local ok, raw = pcall(love.system.getClipboardText)
  local value, reason = Fields.clean_paste(field, ok and raw or nil)
  if not value then
    view.action_note = "未粘贴: " .. reason
    return
  end
  config()[field] = value
  save()
  refresh_values()
  if field == "strategy" then
    view.action_note = "已粘贴策略, 下一次开始时生效"
  elseif field == "seed" then
    view.action_note = "已设置种子, 内置 agent 开局时使用"
  else
    view.action_note = "已粘贴"
  end
  -- 只记字段名, 不记内容.
  sendInfoMessage("Builtin agent " .. field .. " updated from clipboard", LOGGER)
end

--- 行尾的小按钮 (复制, 清除).
---@param label string
---@param colour table?
---@param enabled (fun(): boolean)?
---@param on_click fun()
---@return table
local function small_button(label, colour, enabled, on_click)
  return W.button({
    label = label,
    col = true,
    minw = 0.8,
    scale = SCALE,
    colour = colour,
    enabled = enabled,
    on_click = on_click,
  })
end

local function has_strategy()
  return Fields.strategy_preview(config().strategy) ~= nil
end

--- 策略一行: 预览, 粘贴, 复制, 清除. 预览比其它行窄, 给多出的两个按钮让位.
local function strategy_row()
  return W.row({
    W.col({ W.text("策略", SCALE) }, { minw = LABEL_W }),
    W.col({ W.live(view, "strategy", SCALE, G.C.UI.TEXT_LIGHT) }, { minw = STRATEGY_W }),
    W.button({
      label = "粘贴",
      col = true,
      minw = 0.8,
      scale = SCALE,
      colour = G.C.BLUE,
      on_click = function()
        paste("strategy")
      end,
    }),
    small_button("复制", G.C.BLUE, has_strategy, function()
      local ok = pcall(love.system.setClipboardText, config().strategy)
      view.action_note = ok and "已复制策略到剪贴板" or "复制失败"
    end),
    small_button("清除", nil, has_strategy, function()
      config().strategy = ""
      save()
      refresh_values()
      view.action_note = "已清除策略, 下一次开始时生效"
      sendInfoMessage("Builtin agent strategy cleared", LOGGER)
    end),
  }, { padding = 0.02 })
end

---@param label string
---@param ref_value string
---@param field string
---@param extra table?
---@return table
local function value_row(label, ref_value, field, extra)
  local nodes = {
    W.col({ W.text(label, SCALE) }, { minw = LABEL_W }),
    W.col({ W.live(view, ref_value, SCALE, G.C.UI.TEXT_LIGHT) }, { minw = VALUE_W }),
    W.button({
      label = "粘贴",
      col = true,
      minw = 0.8,
      scale = SCALE,
      colour = G.C.BLUE,
      on_click = function()
        paste(field)
      end,
    }),
  }
  if extra then
    nodes[#nodes + 1] = extra
  end
  return W.row(nodes, { padding = 0.02 })
end

--- 种子一行: 当前种子 (空为 "随机"), 粘贴, 清除. 要放在 value_row 之后, 局部函数没有提升.
local function seed_row()
  return value_row("种子", "seed", "seed", small_button("清除", nil, function()
    return (config().seed or "") ~= ""
  end, function()
    config().seed = ""
    save()
    refresh_values()
    view.action_note = "已清除种子, 内置 agent 开局随机"
    sendInfoMessage("Builtin agent seed cleared", LOGGER)
  end))
end

---@param label string
---@param ref_value string
---@param callback fun(value: boolean)?
---@return table
local function toggle(label, ref_value, callback)
  return W.localize_tree(create_toggle({
    label = label,
    ref_table = config(),
    ref_value = ref_value,
    w = 3.2,
    label_scale = SCALE,
    callback = function(value)
      save()
      if callback then
        callback(value)
      end
    end,
  }))
end

local function mode_column()
  local mode = deps.mode
  local mode_options = {}
  for i, key in ipairs(deps.modes.MODES) do
    mode_options[i] = { key, deps.modes.LABELS[key] }
  end
  local auth_options = { { "bearer", "Bearer" }, { "x-api-key", "x-api-key" } }
  local limit_options = {}
  for i, v in ipairs(Fields.TOKEN_LIMITS) do
    limit_options[i] = { v, Fields.TOKEN_LIMIT_LABELS[i] }
  end
  local context_options = {}
  for i, v in ipairs(Fields.CONTEXT_LIMITS) do
    context_options[i] = { v, Fields.CONTEXT_LIMIT_LABELS[i] }
  end

  return W.col({
    W.title("agent 模式"),
    W.row({
      W.radio(mode_options, function()
        return mode.current
      end, function(value)
        local ok, reason = mode.set(value)
        if not ok then
          view.action_note = "未切换: " .. tostring(reason)
        end
      end, {
        minw = 1.5,
        enabled = function(value)
          return (mode.can_set(value))
        end,
      }),
    }),
    W.row({ W.live(view, "mode_note", 0.27, G.C.UI.TEXT_INACTIVE) }),
    W.title("内置 agent"),
    value_row("endpoint", "endpoint", "endpoint"),
    value_row("模型名", "model", "model"),
    value_row("key", "key", "api_key", W.button({
      label = "清除",
      col = true,
      minw = 0.8,
      scale = SCALE,
      enabled = function()
        return (config().api_key or "") ~= ""
      end,
      on_click = function()
        config().api_key = ""
        save()
        refresh_values()
        view.action_note = "已清除 key"
        sendInfoMessage("Builtin agent api_key cleared", LOGGER)
      end,
    })),
    W.row({
      W.col({ W.text("鉴权", SCALE) }, { minw = LABEL_W }),
      W.radio(auth_options, function()
        return config().auth
      end, function(value)
        config().auth = value
        save()
      end, { minw = 1.3, scale = SCALE }),
    }),
    W.row({ W.text("单局 token 上限", SCALE) }, { padding = 0.04 }),
    W.row({
      W.radio(limit_options, function()
        return Fields.TOKEN_LIMITS[Fields.token_limit_index(config().token_limit)]
      end, function(value)
        config().token_limit = value
        save()
      end, { minw = 1.05, scale = 0.28 }),
    }),
    W.row({ W.text("最大上下文 (到 80% 时压缩较早的对话)", SCALE) }, { padding = 0.04 }),
    W.row({
      W.radio(context_options, function()
        return Fields.CONTEXT_LIMITS[Fields.context_limit_index(config().context_limit)]
      end, function(value)
        config().context_limit = value
        save()
      end, { minw = 0.85, scale = 0.28 }),
    }),
    W.row({ W.text("赢下一局之后", SCALE) }, { padding = 0.04 }),
    W.row({
      W.radio({ { "menu", "回主菜单并停止" }, { "endless", "继续无尽模式" } }, function()
        return config().after_win
      end, function(value)
        config().after_win = value
        save()
      end, { minw = 2.2, scale = 0.28 }),
    }),
    seed_row(),
    strategy_row(),
    W.row({ W.live(view, "action_note", 0.27, G.C.UI.TEXT_INACTIVE) }),
    W.row({ W.text("endpoint 填 chat completions 的完整地址, 从剪贴板粘贴.", 0.26, G.C.UI.TEXT_INACTIVE) }),
    W.row({ W.text("策略: 自己写的打法要求, 粘贴后下一次开始时生效.", 0.26, G.C.UI.TEXT_INACTIVE) }),
    W.row({ W.text("种子: 最多 8 位字母和数字, 空为随机; 固定种子的局按原版规则不计解锁和统计.", 0.26, G.C.UI.TEXT_INACTIVE) }),
    W.row({ W.text("key 以明文保存在本机存档目录 (config/balatrobot.jkr).", 0.26, G.C.UI.TEXT_INACTIVE) }),
    W.row({
      W.text(
        love._os == "Android"
            and "Android: 该文件权限为 0600, 靠组权限的文件管理器读不到; Android 10 及以前有存储权限的应用仍可能读到."
          or "配置文件权限为 0600, 只允许本应用读写.",
        0.26,
        G.C.UI.TEXT_INACTIVE
      ),
    }),
  }, { minw = COL_W, padding = 0.05 })
end

local function side_column()
  local nodes = { W.title("显示") }
  nodes[#nodes + 1] = toggle("显示 agent 消息", "show_messages", function(value)
    deps.toast.enabled = value
    if not value then
      deps.toast.clear()
    end
  end)
  nodes[#nodes + 1] = toggle("演示流式条 (开发用)", "demo_stream")
  nodes[#nodes + 1] = W.title("状态")
  for _, key in ipairs({ "agent_line", "runner_line" }) do
    nodes[#nodes + 1] = W.row({ W.live(view, key, 0.28) })
  end
  nodes[#nodes + 1] = W.row({ W.live(view, "error_line", 0.28, G.C.RED) })
  return W.col(nodes, { minw = COL_W, padding = 0.05 })
end

--- MOD.config_tab
---@return table
function M.build()
  refresh_values()
  refresh_status()
  view.action_note = ""
  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.15, r = 0.1, colour = G.C.BLACK, func = "bb_settings_refresh" },
    nodes = {
      W.row({
        mode_column(),
        W.col({}, { minw = 0.2 }),
        side_column(),
      }, { align = "tm", padding = 0 }),
    },
  }
end

return M
