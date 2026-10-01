-- local_call 的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 重点是过期响应: stop 或暂停后 abandon, 再开新调用时旧回复不能喂给新调用.

local LocalCall = dofile("mods/balatrobot/agent/loop/local_call.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

sendDebugMessage = function() end
sendErrorMessage = function() end

-- 假 dispatcher: 与真实实现一样, 端点拿到的 send_response 在调用时才去查 Server.send_response.
-- notify 端点默认挂起, 按调用顺序把 send_response 存进 env.hangs.
local function make_env()
  local env = { sent = {}, hangs = {} }
  env.server = {
    send_response = function(response)
      env.sent[#env.sent + 1] = response
      return true
    end,
  }
  env.dispatcher = { endpoints = {} }
  env.dispatcher.endpoints.notify = {
    execute = function(_, send_response)
      env.hangs[#env.hangs + 1] = send_response
    end,
  }
  env.dispatcher.dispatch = function(request)
    env.dispatcher.endpoints[request.method].execute(request.params, function(response)
      env.server.send_response(response)
    end)
  end
  LocalCall.install(env.server)
  return env
end

do -- 同步响应: 端点立刻回复
  local env = make_env()
  env.dispatcher.endpoints.notify.execute = function(_, send_response)
    send_response({ ok = true })
  end
  local got = nil
  local started = LocalCall.call(env.dispatcher, "notify", {}, nil, function(r) got = r end)
  check("同步响应: 回调收到结果", started == true and got ~= nil and got.ok == true)
  check("同步响应: 调用结束", LocalCall.busy() == false)
  check("同步响应: HTTP 层也收到同一份", #env.sent == 1)
end

do -- 挂起的响应回来时仍属于当前调用
  local env = make_env()
  local got = nil
  LocalCall.call(env.dispatcher, "notify", {}, nil, function(r) got = r end)
  check("挂起: 期间标记为忙", LocalCall.busy() == true)
  env.hangs[1]({ ok = 1 })
  check("挂起: 迟来但属本次的响应被接受", got ~= nil and got.ok == 1 and LocalCall.busy() == false)
end

do -- 过期响应: abandon 之后另开调用, 旧回复不能冒充新调用的结果
  local env = make_env()
  local first, second = nil, nil
  LocalCall.call(env.dispatcher, "notify", {}, nil, function(r) first = r end)
  LocalCall.abandon()
  LocalCall.call(env.dispatcher, "notify", {}, nil, function(r) second = r end)

  env.hangs[1]({ which = "first" })
  check("过期响应: 旧回复被丢弃并计数", first == nil and second == nil and LocalCall.dropped() == 1)
  check("过期响应: 丢弃时新调用仍在等", LocalCall.busy() == true)

  env.hangs[2]({ which = "second" })
  check("过期响应: 新调用收到自己的结果", second ~= nil and second.which == "second")
end

do -- dispatch 期间外层 (overlay) 包上的 execute 不能被拆掉, 闸门也不能越套越多
  local env = make_env()
  local raw_calls, outer_calls = 0, 0
  local endpoint = env.dispatcher.endpoints.notify
  endpoint.execute = function(_, send_response)
    raw_calls = raw_calls + 1
    send_response({})
  end
  local dispatch = env.dispatcher.dispatch
  env.dispatcher.dispatch = function(request)
    if not endpoint.outer then
      endpoint.outer = true
      local inner = endpoint.execute
      endpoint.execute = function(...)
        outer_calls = outer_calls + 1
        return inner(...)
      end
    end
    return dispatch(request)
  end
  for _ = 1, 3 do
    LocalCall.call(env.dispatcher, "notify", {}, nil, function() end)
  end
  check("外层包装: 每次调用都经过", outer_calls == 3, tostring(outer_calls))
  check("外层包装: 每次调用原端点只执行一次", raw_calls == 3, tostring(raw_calls))
end

do -- dispatch 抛错时不留悬挂状态
  local env = make_env()
  env.dispatcher.dispatch = function()
    error("boom")
  end
  local started, err = LocalCall.call(env.dispatcher, "notify", {}, nil, function() end)
  check("异常: 调用报告失败且不留待处理调用", started == false and err ~= nil and LocalCall.busy() == false)
end

do -- 前一次没结束就不允许并发调用
  local env = make_env()
  LocalCall.call(env.dispatcher, "notify", {}, nil, function() end)
  local started = LocalCall.call(env.dispatcher, "notify", {}, nil, function() end)
  check("互斥: 第二次调用被拒", started == false)
  LocalCall.abandon()
end

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("local_call 全部通过")
