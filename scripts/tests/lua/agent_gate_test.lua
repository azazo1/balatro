-- 讲解门槛的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 覆盖 bbcore 的端点派发: 讲解还在屏幕上时, 改状态的操作挂起等它退去; 只读方法与 notify/start/menu 不等.

-- dispatcher 用 socket.gettime 计时, 测试里给一个可推进的假时钟.
local clock = 0
package.preload.socket = function()
  return { gettime = function() return clock end }
end

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

G = { STATES = { MENU = 1, SHOP = 2, PLAY_TAROT = 3 }, STATE = 2 }
BB_ERROR_NAMES = {
  BAD_REQUEST = "BAD_REQUEST",
  INVALID_STATE = "INVALID_STATE",
  INTERNAL_ERROR = "INTERNAL_ERROR",
}
-- 只读方法: 手册查询与状态查询由别的 mod 登记进 PASSIVE, 这里只放一个代表.
BB_ACTIVITY = { PASSIVE = { gamestate = true } }
sendDebugMessage = function() end
sendWarnMessage = function() end
sendErrorMessage = function() end

-- 假的 BB_TOAST: 只提供门槛用的三个字段, 真实实现在 runtime/toast.lua.
local toast = { gate_enabled = true, id = nil }
BB_TOAST = {
  gate_enabled = true,
  gate_id = function() return toast.id end,
  gate_open = function(id) return toast.id ~= id end,
}

SMODS = {
  load_file = function(path)
    return assert(loadfile("mods/bbcore/" .. path))
  end,
}

dofile("mods/bbcore/src/lua/core/dispatcher.lua")

local executed = {}
local responses = {}
BB_DISPATCHER.Server = {
  send_response = function(response)
    responses[#responses + 1] = response
    return true
  end,
}

local function register(name, requires_state)
  assert(BB_DISPATCHER.register({
    name = name,
    description = "测试用",
    schema = {},
    requires_state = requires_state,
    execute = function(_, send_response)
      executed[#executed + 1] = name
      send_response({ success = true })
    end,
  }))
end

local SHOP = { G.STATES.SHOP }
register("play", SHOP)
register("discard", SHOP)
register("gamestate")
register("notify")
register("start", { G.STATES.MENU })
register("menu")

local function dispatch(method)
  BB_DISPATCHER.dispatch({ jsonrpc = "2.0", method = method, params = {}, id = 1 })
end

local function reset()
  executed, responses = {}, {}
  toast.id = nil
  clock = 0
  BB_DISPATCHER.update() -- 清掉上一次留下的挂起请求
  executed, responses = {}, {}
end

do -- 没有讲解时直接执行, 有讲解时挂起
  reset()
  dispatch("play")
  check("没有讲解时立刻执行", #executed == 1 and executed[1] == "play", table.concat(executed, ","))
  check("立刻执行时有响应", #responses == 1)

  reset()
  toast.id = 7
  dispatch("play")
  check("讲解还在时先不执行", #executed == 0, table.concat(executed, ","))
  check("挂起时还没有响应", #responses == 0)
  toast.id = nil
  BB_DISPATCHER.update()
  check("讲解退去后执行", #executed == 1 and executed[1] == "play", table.concat(executed, ","))
  check("执行后有响应", #responses == 1)
end

do -- 只读方法与 notify/start/menu 不等讲解
  reset()
  toast.id = 7
  G.STATE = G.STATES.MENU -- start 只在主菜单可用
  for _, method in ipairs({ "gamestate", "notify", "start", "menu" }) do
    dispatch(method)
  end
  G.STATE = G.STATES.SHOP
  check(
    "只读与 notify/start/menu 立刻执行",
    #executed == 4 and table.concat(executed, ",") == "gamestate,notify,start,menu",
    table.concat(executed, ",")
  )
end

do -- 多个挂起的请求按到达顺序执行, 队首还在等时后面的不抢先
  reset()
  toast.id = 7
  dispatch("play")
  dispatch("discard")
  check("两个都挂起", #executed == 0, table.concat(executed, ","))
  toast.id = nil
  BB_DISPATCHER.update()
  check("按到达顺序执行", table.concat(executed, ",") == "play,discard", table.concat(executed, ","))
end

do -- 挂起期间阶段变了: 执行前再查一次, 不执行而是返回阶段错误
  reset()
  toast.id = 7
  dispatch("play")
  G.STATE = G.STATES.PLAY_TAROT
  toast.id = nil
  BB_DISPATCHER.update()
  G.STATE = G.STATES.SHOP
  check("阶段变了就不执行", #executed == 0, table.concat(executed, ","))
  check("返回阶段错误", #responses == 1 and responses[1].name == "INVALID_STATE", tostring(#responses))
end

do -- 讲解显示异常时不能卡住请求: 超过上限直接执行
  reset()
  toast.id = 7
  dispatch("play")
  clock = 119
  BB_DISPATCHER.update()
  check("上限内继续等", #executed == 0, table.concat(executed, ","))
  clock = 121
  BB_DISPATCHER.update()
  check("超过上限直接执行", #executed == 1 and executed[1] == "play", table.concat(executed, ","))
end

do -- 门槛关掉时 (回放禁用) 不等
  reset()
  toast.id = 7
  BB_TOAST.gate_id = function() return nil end
  dispatch("play")
  check("门槛关掉时立刻执行", #executed == 1 and executed[1] == "play", table.concat(executed, ","))
end

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("讲解门槛全部通过")
