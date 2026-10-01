-- local_call 的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 重点是过期响应: stop 或暂停后 abandon, 再开新调用时旧回复不能喂给新调用.

local DIR = "mods/balatrobot/agent/loop/"
local LocalCall = dofile(DIR .. "local_call.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

love = { timer = { getTime = function() return os.clock() end } }

local debug_logs = {}
local error_logs = {}
sendDebugMessage = function(msg) debug_logs[#debug_logs + 1] = msg end
sendErrorMessage = function(msg) error_logs[#error_logs + 1] = msg end

-- 假 dispatcher: 找到端点就执行, 端点拿到的 send_response 与真实实现一样, 在调用时才去查 Server.send_response.
local function make_env()
  local env = {}
  env.sent = {}
  env.hangs = {} -- 按调用顺序保存端点挂起时留下的 send_response
  env.server = {
    send_response = function(response)
      env.sent[#env.sent + 1] = response
      return true
    end,
  }
  env.dispatcher = { endpoints = {}, Server = env.server }
  env.dispatcher.endpoints.notify = {
    execute = function(_, send_response)
      env.hangs[#env.hangs + 1] = send_response
    end,
  }
  env.dispatcher.dispatch = function(request)
    local endpoint = env.dispatcher.endpoints[request.method]
    if not endpoint then
      env.server.send_response({ message = "Unknown method: " .. request.method, name = "BAD_REQUEST" })
      return
    end
    endpoint.execute(request.params, function(response)
      env.server.send_response(response)
    end)
  end
  LocalCall.install(env.server)
  return env
end

do
  -- 同步响应: 端点立刻回复
  local env = make_env()
  env.dispatcher.endpoints.notify.execute = function(_, send_response)
    send_response({ ok = true })
  end
  local got = nil
  local started = LocalCall.call(env.dispatcher, "notify", { message = "hi" }, nil, function(r) got = r end)
  check("同步响应: 调用启动", started == true)
  check("同步响应: 回调收到结果", got ~= nil and got.ok == true)
  check("同步响应: 调用结束", LocalCall.busy() == false)
  check("同步响应: HTTP 层也收到同一份", #env.sent == 1)
end

do
  -- 挂起的响应回来时仍属于当前调用
  local env = make_env()
  local got = nil
  LocalCall.call(env.dispatcher, "notify", { message = "hi" }, nil, function(r) got = r end)
  check("挂起: 期间标记为忙", LocalCall.busy() == true)
  env.hangs[1]({ ok = 1 })
  check("挂起: 迟来但属本次的响应被接受", got ~= nil and got.ok == 1)
  check("挂起: 处理完后不再忙", LocalCall.busy() == false)
end

do
  -- 过期响应: abandon 之后另开调用, 旧回复不能冒充新调用的结果
  local env = make_env()
  local first_result, second_result = nil, nil
  LocalCall.call(env.dispatcher, "notify", { message = "first" }, nil, function(r) first_result = r end)
  local stale = env.hangs[1]
  LocalCall.abandon()
  check("过期响应: abandon 后不再忙", LocalCall.busy() == false)
  LocalCall.call(env.dispatcher, "notify", { message = "second" }, nil, function(r) second_result = r end)
  local fresh = env.hangs[2]

  stale({ which = "first" })
  check("过期响应: 旧回复被丢弃", first_result == nil and second_result == nil)
  check("过期响应: 计数增加", LocalCall.dropped() == 1)
  check("过期响应: 丢弃时新调用仍在等", LocalCall.busy() == true)
  check("过期响应: 无告警", #error_logs == 0)

  fresh({ which = "second" })
  check("过期响应: 新调用收到自己的结果", second_result ~= nil and second_result.which == "second")
  check("过期响应: 丢弃的旧结果没有交给新调用", second_result.which ~= "first")
end

do
  -- 端点 execute 用完即恢复, 不影响后续 HTTP 路径
  local env = make_env()
  local original = env.dispatcher.endpoints.notify.execute
  LocalCall.call(env.dispatcher, "notify", {}, nil, function() end)
  check("恢复: execute 换回原函数", env.dispatcher.endpoints.notify.execute == original)
  LocalCall.abandon()
end

do
  -- dispatch 抛错时不留悬挂状态, 也不留被替换的 execute
  local env = make_env()
  local original = env.dispatcher.endpoints.notify.execute
  env.dispatcher.dispatch = function()
    error("boom")
  end
  local started, err = LocalCall.call(env.dispatcher, "notify", {}, nil, function() end)
  check("异常: 调用报告失败", started == false and err ~= nil)
  check("异常: 不留下待处理调用", LocalCall.busy() == false)
  check("异常: execute 已恢复", env.dispatcher.endpoints.notify.execute == original)
end

do
  -- 前一次没结束就不允许并发调用
  local env = make_env()
  LocalCall.call(env.dispatcher, "notify", {}, nil, function() end)
  local started, err = LocalCall.call(env.dispatcher, "notify", {}, nil, function() end)
  check("互斥: 第二次调用被拒", started == false and err ~= nil)
  LocalCall.abandon()
end

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("local_call 全部通过")
