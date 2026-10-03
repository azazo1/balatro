-- 内置 agent 设置: 固定顶部和对局 / LLM / Decision 三个子页.
-- URL 和 key 使用剪贴板输入, key 只显示掩码, 不进入日志.
local M = {}
local Fields = assert(SMODS.load_file("agent/ui/fields.lua", "balatrobot"))()
local Configuration = assert(SMODS.load_file("agent/configuration.lua", "balatrobot"))()
local W, deps
local WIDTH, SCALE = 6.2, 0.3
local view = { note = "", status = "", required = "", preset = "" }
local page = "play"
local pending_preset, test_request, last_refresh

local function config() return deps.mod.config end
local function save() SMODS.save_mod_config(deps.mod) end
local function editable() return not deps.runner.is_busy() and test_request == nil end
local function fit(value, width) return W.fit_text(tostring(value or ""), width or 2.9, SCALE) end
local function refresh_values()
  local c = config()
  for _, kind in ipairs({ "llm", "decision" }) do
    local profile = c[kind] or {}
    for _, field in ipairs({ "endpoint", "model" }) do
      view[kind .. "_" .. field] = profile[field] ~= "" and fit(profile[field]) or "未设置"
    end
    view[kind .. "_api_key"] = Fields.mask_key(profile.api_key)
  end
  view.seed = c.seed ~= "" and c.seed or "随机"
  view.strategy = fit(Fields.strategy_preview(c.strategy) or "未设置", 1.9)
end

local function refresh_status()
  local ok, err = Configuration.validate(config())
  local backend = config().builtin_backend or "llm"
  view.required = backend == "decision" and "只需 Decision 连接, 不使用 LLM"
    or backend == "hybrid" and "需要 LLM 和 Decision 两份连接" or "只需 LLM 连接"
  view.status = deps.runner.is_busy() and "内置 agent 已开始, 停止后才能改连接与对局设置"
    or ok and "当前方式配置完整" or err
  local lock = deps.mode.lock_reason()
  if lock then view.status = view.status .. "; agent 模式锁定: " .. lock end
  if deps.mode.current == "external" then
    view.status = (deps.agent.status or "off") .. " " .. (deps.agent.address or "") .. (lock and ("; " .. lock) or "")
  end
end

function M.init(options) deps, W = options, options.widgets end

local function cancel_test()
  if test_request then test_request:cancel(); test_request = nil end
end

function M.update()
  if test_request and (deps.runner.is_busy() or not last_refresh or love.timer.getTime() - last_refresh > 0.5) then
    cancel_test()
    view.note = "连接测试已取消"
  end
end

G.FUNCS.bb_settings_refresh = function()
  if not deps then return end
  last_refresh = love.timer.getTime()
  if test_request then test_request:update() end
  refresh_status()
end

local function button(label, click, enabled, width)
  return W.button({ label = label, col = true, minw = width or 0.8, scale = SCALE,
    colour = G.C.BLUE, enabled = enabled or editable, on_click = function()
      if not enabled and not editable() then return end
      click()
    end })
end

local function paste(field, kind)
  if not editable() then return end
  local ok, raw = pcall(love.system.getClipboardText)
  local value, err = Fields.clean_paste(field, ok and raw or nil)
  if not value then view.note = "未粘贴: " .. err; return end
  local target = kind and config()[kind] or config()
  target[field] = value
  if kind == "decision" and field ~= "api_key" then target.provider = "custom"; pending_preset = nil end
  save(); refresh_values()
  view.note = "已粘贴, 下一次开始时使用"
  sendInfoMessage("Builtin agent field updated: " .. (kind and (kind .. ".") or "") .. field, "BB.AGENT.SETTINGS")
end

local function value_row(label, field, kind)
  local key = kind and (kind .. "_" .. field) or field
  local target = function() return kind and config()[kind] or config() end
  return W.row({
    W.col({ W.text(label, SCALE) }, { minw = 1.3 }),
    W.col({ W.live(view, key, SCALE) }, { minw = field == "strategy" and 1.9 or 2.9 }),
    button("粘贴", function() paste(field, kind) end),
    field == "strategy" and button("复制", function() love.system.setClipboardText(config().strategy); view.note = "已复制策略" end,
      function() return (config().strategy or "") ~= "" end) or W.col({}, { minw = 0 }),
    button("清除", function()
      target()[field] = ""; save(); refresh_values(); view.note = "已清除, 下一次开始时使用"
    end, function() return editable() and (target()[field] or "") ~= "" end),
  }, { padding = 0.02 })
end

local function radio(label, options, field, kind, width, tooltip)
  return W.row({
    W.col({ W.text(label, SCALE) }, { minw = 1.3, tooltip = tooltip }),
    W.radio(options, function() return (kind and config()[kind] or config())[field] end, function(value)
      if not editable() then return end
      (kind and config()[kind] or config())[field] = value; save()
    end, { enabled = editable, minw = width or 1.2, scale = 0.28 }),
  })
end

local function root(nodes)
  return { n = G.UIT.ROOT, config = { align = "cm", padding = 0.04, colour = G.C.CLEAR, func = "bb_settings_refresh" }, nodes = nodes }
end

local function toggle(label, field, callback)
  return W.localize_tree(create_toggle({ label = label, ref_table = config(), ref_value = field,
    col = true, w = 2.4, label_scale = SCALE, callback = function(value)
      save(); if callback then callback(value) end
    end }))
end

local function play_page()
  page = "play"
  local limits = {}
  for i, v in ipairs(Fields.TOKEN_LIMITS) do limits[i] = { v, Fields.TOKEN_LIMIT_LABELS[i] } end
  return root({
    W.row({ W.col({
      W.title("对局设置"),
      radio("token 上限", limits, "token_limit", nil, 0.95, W.tip("单局上限", "统计两种模型的合计用量, 超过后暂停. 0 为不限.")),
      radio("赢后处理", { { "menu", "回菜单" }, { "endless", "无尽模式" } }, "after_win", nil, 1.5),
      radio("局后处理", { { "stop", "停止" }, { "continue", "继续" } }, "after_run", nil, 1.5),
      value_row("种子", "seed"), value_row("策略", "strategy"),
      W.row({ W.text("固定种子最多 8 位字母数字, 空为随机.", 0.27) }),
    }, { minw = WIDTH }), W.col({
      W.title("显示与消息"),
      W.row({ toggle("显示 agent 消息", "show_messages", function(on)
        deps.toast.enabled = on; if not on then deps.toast.clear("right") end
      end) }),
      W.row({ toggle("显示工具调用", "show_calls", function(on)
        deps.toast.calls_enabled = on; if not on then deps.toast.clear("left") end
      end) }),
      W.row({ toggle("演示流式条", "demo_stream") }),
      W.row({ W.radio({ { "normal", "阅读" }, { "fast", "快速" } }, deps.pace.current, deps.pace.set, { minw = 1.4, scale = SCALE }) }),
      W.row({ W.text("消息开关与节奏可以即时修改.", 0.27) }),
    }, { minw = WIDTH }) }, { align = "tm" }),
  })
end

local function connection_nodes(kind)
  return {
    W.title(kind == "llm" and "LLM 连接" or "Decision 连接"),
    value_row("endpoint", "endpoint", kind), value_row("模型", "model", kind), value_row("key", "api_key", kind),
    radio("鉴权", { { "bearer", "Bearer" }, { "raw", "原始" }, { "x-api-key", "x-api-key" } }, "auth", kind, 1.2),
    W.row({ W.text("key 以明文保存在本机, 不进入日志.", 0.27) }),
    W.row({ W.text("URL 和 key 从剪贴板粘贴, key 只显示掩码.", 0.27) }),
  }
end

local function llm_page()
  page = "llm"
  local contexts, efforts = {}, {}
  for i, v in ipairs(Fields.CONTEXT_LIMITS) do contexts[i] = { v, Fields.CONTEXT_LIMIT_LABELS[i] } end
  for i, v in ipairs(Fields.REASONING_EFFORTS) do efforts[i] = { v, Fields.REASONING_EFFORT_LABELS[i] } end
  return root({ W.row({
    W.col(connection_nodes("llm"), { minw = WIDTH }),
    W.col({ W.title("LLM 推理设置"),
      radio("协议", { { "chat", "Chat" }, { "responses", "Responses" }, { "anthropic", "Anthropic" } }, "api_format", "llm", 1.4),
      radio("上下文", contexts, "context_limit", "llm", 0.7, W.tip("最大上下文", "达到 80% 后压缩较早对话.")),
      radio("思考强度", efforts, "reasoning_effort", "llm", 0.7),
      radio("Claude 思考", { { "adaptive", "自适应" }, { "budget", "固定预算" }, { "omit", "不指定" } }, "thinking", "llm", 1.3),
      W.row({ W.text("自适应用于 Claude 4.6+, 固定预算用于旧版.", 0.27) }),
      W.row({ W.text("Decision 模式不使用本页的连接与推理设置.", 0.27) }),
    }, { minw = WIDTH }),
  }, { align = "tm" }) })
end

local function choose_preset(provider)
  if not editable() then return end
  local profile = config().decision
  if provider ~= "custom" and ((profile.endpoint or "") ~= "" or (profile.model or "") ~= "") then
    pending_preset = provider
    view.preset = "待应用: " .. (provider == "typesafe" and "TypeSafe" or "AIHubMix")
    view.note = "点应用预设确认替换 endpoint / 模型 / 鉴权, key 不变"
  else
    Configuration.apply_preset(profile, provider); save(); refresh_values()
    pending_preset = nil; view.preset = ""; view.note = "已选择自定义连接"
  end
end

local function test_connection()
  if not editable() or not deps.decision_client then return end
  local probe = Configuration.copy(config())
  probe.builtin_backend = "decision"
  local ok, err = Configuration.validate(probe)
  if not ok then view.note = err; return end
  view.note = "正在测试 Decision 连接, 会产生少量用量"
  test_request = deps.decision_client.test(probe.decision, {
    on_done = function(_, usage)
      test_request = nil
      view.note = "Decision 连接正常, 测试 token " .. tostring((usage.prompt_tokens or 0) + (usage.completion_tokens or 0))
    end,
    on_error = function(reason, detail)
      test_request = nil; view.note = fit(reason .. (detail and (": " .. detail) or ""), 11)
    end,
    on_retry = function(attempt) view.note = "连接测试退避重试 " .. attempt .. "/5" end,
  })
end

local function decision_page()
  page = "decision"
  return root({ W.row({
    W.col(connection_nodes("decision"), { minw = WIDTH }),
    W.col({
      W.title("System One"),
      W.row({ W.radio({ { "typesafe", "TypeSafe" }, { "aihubmix", "AIHubMix" }, { "custom", "自定义" } },
        function() return config().decision.provider end, choose_preset, { enabled = editable, minw = 1.4, scale = SCALE }) }),
      W.row({ W.live(view, "preset", 0.27), button("应用预设", function()
        Configuration.apply_preset(config().decision, pending_preset); pending_preset = nil; view.preset = ""
        save(); refresh_values(); view.note = "已应用预设, key 保留, 请核对 key 所属平台后测试"
      end, function() return editable() and pending_preset ~= nil end, 1.5) }),
      radio("最低置信度", { { 0, "不限制" }, { 0.5, "0.5" }, { 0.7, "0.7" }, { 0.9, "0.9" } }, "min_confidence", "decision", 1),
      W.row({ W.text("低于阈值暂停, confidence 不等于正确率.", 0.27) }),
      W.row({ W.text("混合模式仅有一项候选时用 Noul 判断, 至少 0.5.", 0.27) }),
      W.row({ button("测试连接 (少量用量)", test_connection,
        function() return editable() and deps.decision_client ~= nil end, 3),
        button("取消测试", function() cancel_test(); view.note = "连接测试已取消" end,
          function() return test_request ~= nil end, 1.5) }),
      W.row({ W.text("自定义填写 API 根地址或完整 Decision 地址.", 0.27) }),
      W.row({ W.text("其他平台尽力兼容, 不从域名猜测协议或鉴权.", 0.27) }),
    }, { minw = WIDTH }),
  }, { align = "tm" }) })
end

function M.build()
  cancel_test(); refresh_values(); refresh_status(); view.note = ""
  local modes = {}
  for _, key in ipairs(deps.modes.MODES) do modes[#modes + 1] = { key, deps.modes.LABELS[key] } end
  return root({
    W.row({ W.text("agent", SCALE), W.radio(modes, function() return deps.mode.current end, function(value)
      local ok, err = deps.mode.set(value); if not ok then view.note = tostring(err) end
    end, { minw = 1.4, enabled = function(value) return deps.mode.can_set(value) end }),
    W.col({}, { minw = 0.3 }),
    W.text("内置方式", SCALE), W.radio({ { "llm", "LLM" }, { "decision", "Decision" }, { "hybrid", "混合" } },
      function() return config().builtin_backend end, function(value)
        if editable() then config().builtin_backend = value; save(); refresh_status() end
      end, { minw = 1.4, enabled = editable }) }),
    W.row({ W.live(view, "required", 0.27) }),
    W.row({ W.live(view, "status", 0.27, G.C.UI.TEXT_INACTIVE) }),
    W.localize_tree(create_tabs({ scale = 0.7, text_scale = SCALE, no_shoulders = true, tabs = {
      { label = "对局", chosen = page == "play", tab_definition_function = play_page },
      { label = "LLM", chosen = page == "llm", tab_definition_function = llm_page },
      { label = "Decision", chosen = page == "decision", tab_definition_function = decision_page },
    } })),
    W.row({ W.live(view, "note", 0.27, G.C.UI.TEXT_INACTIVE) }),
  })
end

return M
