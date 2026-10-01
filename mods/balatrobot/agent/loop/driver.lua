--[[
内置 agent 的主循环 (driver). 依赖全部注入, 不直接碰全局, 方便单测.

一轮: 看状态 -> (需要时) 追加状态摘要 -> 流式请求模型 -> 逐个执行工具调用 -> 结果写回历史 -> 下一轮.

- 没有选择的步骤自动处理, 不问模型: 解锁弹窗 continue, 结算 cash_out.
- 胜利按配置 after_win 处理 ("endless" 进入无尽模式继续打, "menu" 回主菜单并停止), 输了回主菜单并停止.
- 人打开了设置等菜单 (overlay 为 other), 或动画没停时等待, 不发请求也不执行动作.
- 防失控: 模型连续几次不调用工具, 同一个调用连续失败, 或模型请求出现不可重试的错误时停下 (halted),
  由运行控制转为自动暂停, 等 user 处理后继续. 单局 token 上限由运行控制按汇报的用量判断.
- 暂停: 进行中的请求直接取消 (半截回复丢弃, 不进历史); 正在执行的动作做完为止, 剩余的工具调用
  回一条 "未执行", 保证每个 tool_call 都有结果. 继续时重新给一次状态摘要 (暂停期间 user 可能手动操作过).

deps:
- client.start(cfg, messages, tools, callbacks) -> req, req:update(), req:cancel()
  callbacks: on_delta(kind, text), on_reset(), on_retry(attempt, max, reason, wait_seconds),
  on_done(message, usage), on_error(reason, detail)
- call(method, params, reason, cb) -> ok, err: 进程内调用端点, cb(response)
- abandon(): 放弃等待中的调用
- gamestate() -> table; overlay() -> "unlock"|"win"|"other"|nil; busy() -> boolean (动画或游戏暂停)
- config() -> {endpoint, model, api_key, auth, after_win}
- json {encode, decode}; now() -> 秒
- bar: begin_request(), push(kind, text), reset(), finish(), show_error(text 或 fun(): string, hold), show_status(text, hold)
- describe(key) -> {name, effect}? (给摘要用)
- on_state(state, detail): 可选, 子状态变化 (idle, requesting, acting, retry_wait, waiting, paused, halted, stopped)
- report(event, ...): 可选, 向运行控制 (agent/runner.lua) 汇报, 由它负责单局 token 上限, 暂停与停止:
  "request"; "retry"; "usage"(prompt, completion); "new_run"; "halt"(reason) 防失控或不可恢复的错误;
  "finish"(result) 本局结束 ("win" / "lose"), 应停止 loop. 没有 report 时 driver 自己处理 halt 与 finish.
- transcript(entry): 可选, 转录一条记录
- log(level, msg): 可选
]]

local M = {}

local STABLE = {
  MENU = true,
  BLIND_SELECT = true,
  SELECTING_HAND = true,
  SHOP = true,
  SMODS_BOOSTER_OPENED = true,
}
local MAX_NUDGES = 3 -- 连续不调用工具的次数上限
local MAX_REPEAT_FAILS = 3 -- 同一个调用连续失败的次数上限
local QUERY_RESULT_MAX = 6000 -- 手册查询结果交给模型的最大字节数

---@param deps table
---@return table
function M.new(deps)
  local tools = deps.tools or assert(deps.load("tools"))
  local prompt = deps.prompt or assert(deps.load("prompt"))
  local history_mod = deps.history or assert(deps.load("history"))
  local summary_mod = deps.summary or assert(deps.load("summary"))

  local self = {
    state = "stopped",
    stats = { requests = 0, prompt_tokens = 0, completion_tokens = 0, cached_tokens = 0, actions = 0 },
    last_error = nil,
  }

  local history = history_mod.new(prompt.SYSTEM)
  local summarizer = summary_mod.new(deps.describe)
  local req = nil -- 进行中的模型请求
  local queue = nil -- {calls, index}
  local calling = false -- 端点调用进行中
  local fresh = false -- 模型是否已经拿到最新的状态摘要 (动作结果或用户消息里)
  local note = nil -- 下一轮附在状态前的说明
  local nudges = 0
  local fail_key, fail_count = nil, 0
  local pause_requested = false
  local retry = nil -- {at, attempt, max, reason}
  local last_ante = nil

  local function report(event, ...)
    if deps.report then
      deps.report(event, ...)
      return true
    end
    return false
  end

  local function log(level, msg)
    if deps.log then
      deps.log(level, msg)
    end
  end

  local function transcript(entry)
    if deps.transcript then
      entry.t = deps.now()
      pcall(deps.transcript, entry)
    end
  end

  local function set_state(state, detail)
    self.state = state
    if deps.on_state then
      deps.on_state(state, detail)
    end
  end

  ---@param reason string
  local function halt(reason)
    self.last_error = reason
    log("warn", "Agent loop halted: " .. reason)
    transcript({ type = "halt", reason = reason })
    set_state("halted", reason)
    -- 运行控制会自动暂停 (红字显示原因) 并回调 pause; 继续时保留历史.
    if not report("halt", reason) then
      deps.bar.show_error(reason, 8)
    end
  end

  ---@param result string "win" | "lose"
  local function finish_run(result)
    transcript({ type = "finish", result = result })
    if not report("finish", result) then
      self.stop(result)
    end
  end

  --- 自动步骤: 调用端点, 完成后回到 idle, 下一轮重新给状态.
  local function auto(method, params, text, after)
    calling = true
    set_state("acting", method)
    local ok, err = deps.call(method, params, nil, function(response)
      calling = false
      fresh = false
      if response.message then
        log("warn", "Auto step " .. method .. " failed: " .. tostring(response.message))
        note = (note and note .. "\n" or "") .. string.format("(自动 %s 失败: %s)", method, response.message)
      else
        history:note(text)
        note = (note and note .. "\n" or "") .. "(" .. text .. ")"
      end
      transcript({ type = "auto", method = method, ok = response.message == nil })
      if after then
        after(response)
      elseif self.state == "acting" then
        set_state("idle")
      end
    end)
    if not ok then
      calling = false
      halt("自动 " .. method .. " 调用失败: " .. tostring(err))
    end
  end

  ---@param gs table
  ---@return string
  local function turn_message(gs)
    local text = prompt.turn(summarizer:render(gs), note)
    note = nil
    return text
  end

  local function on_delta(kind, text)
    deps.bar.push(kind, text)
  end

  local function finish_request()
    req = nil
    retry = nil
  end

  local callbacks = {}

  local function send_request()
    local cfg = deps.config()
    self.stats.requests = self.stats.requests + 1
    report("request")
    deps.bar.begin_request()
    set_state("requesting")
    transcript({ type = "request", messages = #history.messages })
    local started = deps.now()
    callbacks.started = started
    req = deps.client.start(cfg, history.messages, tools.definitions({ knowledge = deps.knowledge ~= false }), callbacks)
  end

  function callbacks.on_delta(kind, text)
    retry = nil
    on_delta(kind, text)
  end

  function callbacks.on_reset()
    deps.bar.reset()
  end

  function callbacks.on_retry(attempt, max, reason, wait)
    local entry = { at = deps.now() + wait, attempt = attempt, max = max, reason = reason }
    retry = entry
    transcript({ type = "retry", attempt = attempt, reason = reason, wait = wait })
    log("info", string.format("Model request retry %d/%d in %ds: %s", attempt, max, wait, reason))
    report("retry")
    -- 文字用函数, 流式条每次刷新重新求值, 倒计时实时更新; 重发后第一个增量会换回正常内容.
    deps.bar.show_error(function()
      local left = math.max(0, math.ceil(entry.at - deps.now()))
      return string.format("%s, %d 秒后重试 (%d/%d)", entry.reason, left, entry.attempt, entry.max)
    end, wait + 1)
    set_state("retry_wait", reason)
  end

  function callbacks.on_error(reason, detail)
    finish_request()
    transcript({ type = "error", reason = reason, detail = detail })
    -- 配置错误这类原因太笼统, 带上具体说明 user 才知道改哪里.
    local text = tostring(reason)
    if type(detail) == "string" and detail ~= "" and not text:find(detail, 1, true) then
      local short = detail:gsub("%s+", " ")
      if #short > 120 then
        -- 按字节截断, 退回到 UTF-8 字符边界, 免得切出半个汉字
        local cut = 120
        while cut > 1 and short:byte(cut + 1) and short:byte(cut + 1) >= 0x80 and short:byte(cut + 1) < 0xC0 do
          cut = cut - 1
        end
        short = short:sub(1, cut) .. "..."
      end
      text = text .. ": " .. short
    end
    halt(text)
  end

  function callbacks.on_done(message, usage)
    finish_request()
    deps.bar.finish()
    usage = usage or {}
    self.stats.prompt_tokens = self.stats.prompt_tokens + (usage.prompt_tokens or 0)
    self.stats.completion_tokens = self.stats.completion_tokens + (usage.completion_tokens or 0)
    self.stats.cached_tokens = self.stats.cached_tokens + (usage.cached or 0)
    transcript({
      type = "response",
      seconds = deps.now() - (callbacks.started or deps.now()),
      usage = usage,
      content = message.content,
      reasoning = message.reasoning_content,
      tool_calls = message.tool_calls,
    })
    history:add(message)

    local calls = message.tool_calls or {}
    if #calls == 0 then
      nudges = nudges + 1
      if nudges >= MAX_NUDGES then
        halt("模型连续 " .. nudges .. " 次没有调用工具")
        return
      end
      history:add({ role = "user", content = prompt.NUDGE })
      fresh = true -- 状态没变, 不必再附一遍摘要
      set_state("idle")
    else
      nudges = 0
      queue = { calls = calls, index = 1 }
      set_state("acting")
    end
    -- 放在最后: 超过单局上限时运行控制会同步回调 pause, 此时队列已经就位, 能正确回 "未执行".
    report("usage", usage.prompt_tokens or 0, usage.completion_tokens or 0)
  end

  ---@param call table
  ---@param content string
  local function tool_result(call, content)
    history:add({ role = "tool", tool_call_id = call.id, content = content })
  end

  --- 剩余的工具调用都回 "未执行".
  ---@param why string
  local function skip_rest(why)
    if not queue then
      return
    end
    for i = queue.index, #queue.calls do
      tool_result(queue.calls[i], "未执行: " .. why)
    end
    queue = nil
  end

  ---@param value any
  ---@return string
  local function encode_query(value)
    local ok, text = pcall(deps.json.encode, value)
    text = ok and text or tostring(value)
    if #text > QUERY_RESULT_MAX then
      text = text:sub(1, QUERY_RESULT_MAX) .. "...(已截断, 用 offset 或更具体的 section 继续读)"
    end
    return text
  end

  --- 执行队列里的下一个工具调用.
  local function run_next()
    local call = queue.calls[queue.index]
    queue.index = queue.index + 1
    local fn = call["function"] or {}
    local name = fn.name
    local args = {}
    if fn.arguments and fn.arguments ~= "" then
      local ok, decoded = pcall(deps.json.decode, fn.arguments)
      if not ok or type(decoded) ~= "table" then
        tool_result(call, "失败: arguments 不是合法的 JSON 对象")
        return
      end
      args = decoded
    end
    local method, params, reason = tools.to_request(name, args)
    if not method then
      tool_result(call, "失败: " .. tostring(reason))
      return
    end
    local key = name .. " " .. tostring(fn.arguments)

    calling = true
    transcript({ type = "call", method = method, params = params, reason = reason })
    local ok, err = deps.call(method, params, reason, function(response)
      calling = false
      local failed = response.message ~= nil
      if failed then
        tool_result(call, "失败: " .. tostring(response.message))
        history:note(string.format("%s 失败: %s", method, tostring(response.message)))
        if key == fail_key then
          fail_count = fail_count + 1
        else
          fail_key, fail_count = key, 1
        end
        -- 失败后状态可能和模型以为的不同, 剩下的调用不再执行.
        skip_rest("前一个操作失败")
        if fail_count >= MAX_REPEAT_FAILS then
          halt("同一个操作连续失败 " .. fail_count .. " 次: " .. method)
        end
        return
      end
      fail_key, fail_count = nil, 0
      if tools.ACTIONS[method] then
        self.stats.actions = self.stats.actions + 1
        if method == "start" then
          summarizer:forget()
          report("new_run")
        end
        tool_result(call, "完成. 当前状态:\n" .. summarizer:render(response))
        fresh = true
        history:note(string.format("%s %s%s", method, deps.json.encode(params), reason and (" (" .. reason .. ")") or ""))
      elseif tools.QUERIES[method] then
        tool_result(call, encode_query(response))
      else
        tool_result(call, "已显示")
      end
    end)
    if not ok then
      calling = false
      tool_result(call, "失败: " .. tostring(err))
      skip_rest("前一个操作失败")
    end
  end

  local overlay_seen, overlay_since = nil, 0

  --- 解锁通知和胜利界面先停留一会儿再自动处理, 让观众看清.
  ---@param overlay string?
  ---@return boolean ready
  local function overlay_ready(overlay)
    if overlay ~= overlay_seen then
      overlay_seen, overlay_since = overlay, deps.now()
    end
    return deps.now() - overlay_since >= (deps.overlay_hold or 0)
  end

  --- idle 时决定下一步.
  local function step_idle()
    if deps.busy() then
      return
    end
    local cfg = deps.config()
    local overlay = deps.overlay()
    if (overlay == "unlock" or overlay == "win") and not overlay_ready(overlay) then
      set_state("waiting", overlay)
      return
    end
    overlay_ready(overlay)
    if overlay == "unlock" then
      auto("continue", nil, "关掉了解锁通知")
      return
    elseif overlay == "win" then
      if cfg.after_win == "endless" then
        auto("endless", nil, "赢下本局, 进入无尽模式")
      else
        auto("menu", nil, "赢下本局, 回主菜单", function()
          finish_run("win")
        end)
      end
      return
    elseif overlay then
      set_state("waiting", overlay)
      return
    end

    local gs = deps.gamestate()
    if gs.state == "GAME_OVER" then
      auto("menu", nil, "本局失败, 回主菜单", function()
        finish_run("lose")
      end)
      return
    elseif gs.state == "ROUND_EVAL" then
      auto("cash_out", nil, string.format("第 %s 回合结算, 进入商店", tostring(gs.round_num)))
      return
    elseif not STABLE[gs.state] then
      set_state("waiting", gs.state)
      return
    end

    -- 进入新底注的选盲注时, 或历史估算超预算时压缩, 只在一轮完整结束的边界上做.
    local new_ante = gs.state == "BLIND_SELECT" and last_ante ~= nil and gs.ante_num ~= last_ante
    if gs.state == "BLIND_SELECT" then
      last_ante = gs.ante_num
    end
    if history:settled() and (new_ante or history:over_budget()) and #history.messages > 2 then
      summarizer:forget()
      history:compact(turn_message(gs), prompt.recap)
      log("info", "Agent history compacted")
      transcript({ type = "compact" })
    elseif not fresh then
      history:add({ role = "user", content = turn_message(gs) })
    end
    -- 模型已经拿到最新状态; 之后只有动作, 自动步骤或暂停继续会让它过期.
    fresh = true
    send_request()
  end

  function self.start()
    if self.state ~= "stopped" and self.state ~= "halted" then
      return
    end
    if self.state == "stopped" then
      history:reset()
      summarizer:forget()
      last_ante = nil
    end
    nudges, fail_key, fail_count = 0, nil, 0
    fresh, note, pause_requested = false, nil, false
    self.last_error = nil
    transcript({ type = "start" })
    set_state("idle")
  end

  --- 停下后继续 (halted 状态), 保留历史.
  self.retry = self.start

  function self.pause()
    if self.state == "stopped" or self.state == "paused" then
      return
    end
    if req then
      req:cancel()
      finish_request()
      deps.bar.reset()
    end
    if calling then
      pause_requested = true
      return
    end
    skip_rest("已暂停")
    transcript({ type = "pause" })
    set_state("paused")
  end

  function self.resume()
    if self.state ~= "paused" and not pause_requested then
      return
    end
    pause_requested = false
    fresh = false
    note = "(暂停后继续, 期间可能有手动操作, 以下面的状态为准)"
    transcript({ type = "resume" })
    set_state("idle")
  end

  ---@param why string?
  function self.stop(why)
    if req then
      req:cancel()
      finish_request()
    end
    if calling then
      calling = false
      deps.abandon()
    end
    queue = nil
    pause_requested = false
    history:reset()
    transcript({ type = "stop", reason = why })
    set_state("stopped", why)
  end

  function self.update()
    if req then
      req:update()
      if retry and req and self.state == "retry_wait" and deps.now() >= retry.at then
        set_state("requesting")
      end
      return
    end
    if calling then
      return
    end
    if pause_requested then
      pause_requested = false
      skip_rest("已暂停")
      set_state("paused")
      return
    end
    if self.state == "acting" then
      if queue and queue.index <= #queue.calls then
        if deps.busy() or deps.overlay() == "other" then
          return
        end
        run_next()
        return
      end
      queue = nil
      set_state("idle")
      return
    end
    if self.state == "idle" or self.state == "waiting" then
      step_idle()
    end
  end

  -- 只给测试用.
  self._history = history

  return self
end

return M
