--[[
弹窗 (覆盖菜单) 打开时拦截 agent 的操作, 并让等待中的请求先返回.

原版在弹窗打开时暂停游戏 (G.SETTINGS.paused), 暂停前创建的事件都停着. upstream 的端点直接调用
G.FUNCS, 暂停中创建的事件照常执行, 于是 agent 能在弹窗底下继续操作, 与停着的事件互相打架.
实际遇到的: 打过第 8 底注的 Boss 后弹出胜利界面, agent 没理会它直接 cash_out 进商店,
G.round_eval 被移除; 之后点 "无尽模式" 关掉弹窗, 恢复执行的结算事件访问 G.round_eval 崩溃.

人在弹窗打开时也点不到底下的按钮. 这里同样只放行查询类方法与关掉弹窗的方法, 其余返回 INVALID_STATE.

服务端一次只处理一个连接. 请求在等待游戏推进时 (例如 start 等开局完成) 弹出解锁通知, 等待的事件
随游戏暂停, 请求就一直占着连接, agent 发不出 continue. 所以弹窗出现时让等待中的请求先返回当前状态
(带 overlay 字段), 原请求转为后台. 之后 continue 关掉解锁弹窗, 返回原请求的结果.
]]

local M = {}

-- 弹窗打开时仍可调用的方法
local ALLOWED = {
  ["health"] = true,
  ["gamestate"] = true,
  ["rpc.discover"] = true,
  ["screenshot"] = true,
  ["notify"] = true,
  ["save"] = true,
  ["load"] = true,
  ["menu"] = true,
  ["endless"] = true,
  ["continue"] = true,
}

-- continue 等原请求结果的上限, 超时后返回当前状态.
local WAITER_TIMEOUT = 30
-- 打赢后等胜利界面弹出的上限
local WIN_WAIT = 10

-- 当前占着连接的请求: { method, respond, started, done }
M.pending = nil
-- 因弹窗先返回, 仍在后台等游戏推进的原请求
M.orphan = nil
-- 等 orphan 结果的 continue 请求
M.waiter = nil

---@param node table?
---@param button string
---@param depth integer
---@return boolean
local function has_button(node, button, depth)
  if type(node) ~= "table" or depth > 40 then
    return false
  end
  if node.config and node.config.button == button then
    return true
  end
  for _, child in ipairs(node.children or {}) do
    if has_button(child, button, depth + 1) then
      return true
    end
  end
  return false
end

--- 当前弹窗的类型, 没有弹窗时为 nil:
--- "unlock" 解锁通知 (主菜单或开局时), "win" 胜利界面, "other" 局内的设置, 牌组预览等.
--- 局外的其它菜单与游戏结束界面不算, 它们由各方法的 requires_state 处理.
---@return string?
function M.kind()
  local menu = G.OVERLAY_MENU
  if not menu then
    return nil
  end
  if has_button(menu.UIRoot, "continue_unlock", 0) then
    return "unlock"
  end
  if not G.SETTINGS.paused or G.STAGE ~= G.STAGES.RUN or G.STATE == G.STATES.GAME_OVER then
    return nil
  end
  if G.STATE == G.STATES.ROUND_EVAL and G.GAME.won and menu:get_UIE_by_ID("jimbo_spot") then
    return "win"
  end
  return "other"
end

--- 胜利界面已完全弹出: 原版在界面打开 2.5 秒后把 Jimbo 放进 jimbo_spot.
--- 等到这时再返回, 录像里才有完整的胜利界面, 也和人先看到界面再做决定一致.
---@return boolean
local function win_settled()
  local spot = G.OVERLAY_MENU and G.OVERLAY_MENU:get_UIE_by_ID("jimbo_spot")
  local jimbo = spot and spot.config.object
  return jimbo ~= nil and type(jimbo.is) == "function" and jimbo:is(Card_Character)
end
M.win_settled = win_settled

--- 让请求以当前状态先返回, 原请求留在后台.
---@param request table
local function detach(request)
  request.done = true
  sendInfoMessage(
    string.format("%s returned early: %s overlay opened while waiting", request.method, tostring(M.kind())),
    "BB.AGENT"
  )
  request.send(BB_GAMESTATE.get_gamestate())
end

--- 包装端点的 execute, 给每个请求一个只生效一次的 respond.
---@param endpoint table
local function wrap_endpoint(endpoint)
  if endpoint.__bb_overlay_wrapped then
    return
  end
  endpoint.__bb_overlay_wrapped = true
  local execute = endpoint.execute
  endpoint.execute = function(params, send_response)
    -- opened_with: 请求发出时已打开的弹窗 (例如在胜利界面调用 menu), 这个弹窗不触发先返回.
    local request = {
      method = endpoint.name,
      send = send_response,
      started = love.timer.getTime(),
      done = false,
      opened_with = M.kind(),
      was_won = G.GAME and G.GAME.won or false,
    }
    M.pending = request
    execute(params, function(response)
      -- 这次操作打赢了整局: upstream 在胜利界面弹出前就返回, 这里等界面完全弹出, 让返回里带 overlay = "win".
      if not request.done and not request.held and not request.was_won and response.won and not response.message then
        if not (M.kind() == "win" and win_settled()) then
          request.held = love.timer.getTime()
          return
        end
      end
      if request.done then
        -- 已先返回的原请求完成了, 结果交给等着它的 continue, 没人等就丢弃.
        local waiter = M.waiter
        if request == M.orphan then
          M.orphan = nil
          if waiter and not waiter.done then
            M.waiter = nil
            waiter.done = true
            waiter.send(response)
          end
        end
        return
      end
      request.done = true
      if M.pending == request then
        M.pending = nil
      end
      send_response(response)
    end)
  end
end

---@param dispatcher table BB_DISPATCHER
---@param gamestate table BB_GAMESTATE
function M.install(dispatcher, gamestate)
  local dispatch = dispatcher.dispatch
  dispatcher.dispatch = function(request)
    -- 上一个请求的连接已断开但还没返回, 不能让它的结果发到新连接上.
    if M.pending and not M.pending.done then
      M.pending.done = true
    end
    M.pending = nil

    local method = type(request) == "table" and request.method or nil
    -- agent 发了新的操作, 后台原请求的结果已不再需要.
    if method ~= "continue" and not BB_ACTIVITY.PASSIVE[method] and method ~= "notify" then
      M.orphan = nil
    end
    local kind = M.kind()
    if kind and type(method) == "string" and not ALLOWED[method] then
      local hint
      if kind == "win" then
        hint = "The run is won and the win screen is open. Call 'endless' to keep playing or 'menu' to return to the main menu"
      elseif kind == "unlock" then
        hint = "An unlock notification is open. Call 'continue' to close it"
      else
        hint = "An overlay menu is open in game. Close it in game or call 'menu'"
      end
      return dispatcher.send_error("Method '" .. method .. "' is not available now. " .. hint, BB_ERROR_NAMES.INVALID_STATE)
    end
    local endpoint = type(method) == "string" and dispatcher.endpoints[method] or nil
    if endpoint then
      wrap_endpoint(endpoint)
    end
    return dispatch(request)
  end

  -- 所有端点的返回里带上 overlay 字段, agent 据此判断要不要先关弹窗.
  local get_gamestate = gamestate.get_gamestate
  gamestate.get_gamestate = function(...)
    local state = get_gamestate(...)
    if type(state) == "table" then
      state.overlay = M.kind()
    end
    return state
  end
end

--- continue 端点调用: 关掉解锁弹窗, 有后台的原请求时等它的结果.
---@param send_response fun(response: table)
function M.continue(send_response)
  local request = M.pending
  local waiting = M.orphan ~= nil and request ~= nil
  if waiting then
    M.waiter = request
  end
  G.FUNCS.continue_unlock()
  -- 没有原请求时直接返回. 原请求可能在 continue_unlock 强制处理事件时就完成并已返回.
  if not waiting or (M.orphan == nil and not request.done) then
    M.waiter = nil
    send_response(BB_GAMESTATE.get_gamestate())
  end
end

--- 每帧调用: 等待中的请求遇到弹窗时先返回.
function M.update()
  local request = M.pending
  if not request or request.done then
    return
  end
  local kind = M.kind()
  if request.held then
    -- 打赢后等胜利界面完全弹出, 最多等 WIN_WAIT 秒.
    if (kind == "win" and win_settled()) or love.timer.getTime() - request.held > WIN_WAIT then
      request.done = true
      M.pending = nil
      request.send(BB_GAMESTATE.get_gamestate())
    end
    return
  end
  if request == M.waiter then
    -- continue 在等原请求: 又弹出解锁通知或等太久时先返回, 原请求继续留在后台.
    if kind == "unlock" or love.timer.getTime() - request.started > WAITER_TIMEOUT then
      M.waiter = nil
      M.pending = nil
      detach(request)
    end
    return
  end
  -- notify 只在等消息读完, 不受弹窗影响.
  if kind and kind ~= request.opened_with and request.method ~= "notify" then
    M.pending = nil
    -- 只有解锁通知关掉后原请求会接着完成, 其它弹窗下原请求的结果直接丢弃.
    if kind == "unlock" then
      M.orphan = request
    end
    detach(request)
  end
end

return M
