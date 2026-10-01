-- 内置 agent 界面纯逻辑的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Mode = dofile("mods/balatrobot/agent/mode.lua")
local Text = dofile("mods/balatrobot/agent/ui/stream_text.lua")
local Fields = dofile("mods/balatrobot/agent/ui/fields.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function new_mode(opts)
  local calls = { listening = {}, persisted = {} }
  opts = opts or {}
  local m = Mode.new({
    initial = opts.initial,
    env_locked = opts.env_locked,
    replaying = function()
      return opts.replaying == true
    end,
    runner_busy = function()
      return opts.busy == true
    end,
    set_listening = function(on, reason)
      calls.listening[#calls.listening + 1] = reason or tostring(on)
    end,
    persist = function(mode)
      calls.persisted[#calls.persisted + 1] = mode
    end,
  })
  return m, calls, opts
end

do -- 模式互斥: 外部与内置之间必须经过关闭
  local m, calls = new_mode({ initial = "external" })
  check("外部不能直接切内置", not m.set("builtin") and m.current == "external")
  check("外部切关闭", m.set("off") and m.current == "off")
  check("关闭切内置", m.set("builtin") and m.current == "builtin")
  check("内置不能直接切外部", not m.can_set("external"))
  check("切换时启停服务", calls.listening[1] == "false" and calls.listening[2] == "false", table.concat(calls.listening, ","))
  check("切换写回配置", calls.persisted[1] == "off" and calls.persisted[2] == "builtin")
  check("未知模式拒绝", not m.set("bogus") and m.current == "builtin")
  local m2 = new_mode({ initial = "bogus" })
  check("配置里的未知模式按关闭", m2.current == "off")
end

do -- 内置 loop 运行中不能切换
  local m, _, opts = new_mode({ initial = "builtin" })
  opts.busy = true
  check("运行中不能切关闭", not m.set("off") and m.current == "builtin")
  opts.busy = false
  check("停止后可以切关闭", m.set("off"))
end

do -- 环境变量锁定为外部, 不写回配置
  local m, calls = new_mode({ initial = "builtin", env_locked = true })
  check("锁定为外部", m.current == "external" and m.lock_reason() ~= nil)
  check("锁定时不能切换", not m.set("off") and not m.can_set("builtin"))
  m.apply()
  check("锁定时监听", calls.listening[1] == "true")
  check("锁定时不写回", #calls.persisted == 0)
end

do -- 回放时锁定且不监听
  local m, calls = new_mode({ initial = "external", replaying = true })
  m.apply()
  check("回放时不监听", calls.listening[1] == "replaying")
  check("回放时不能切换", not m.set("off"))
end

-- 假测宽: ASCII 宽 1, 其余 (中文) 宽 2
local function measure(ch)
  return #ch > 1 and 2 or 1
end

local function joined(pieces)
  local out = {}
  for i, p in ipairs(pieces) do
    out[i] = p.kind .. ":" .. p.text
  end
  return table.concat(out, "|")
end

do -- 尾部截取: 最右端是最新的字, 中英混合按宽度, 宽字放不下时整个丢掉
  local segs = { { kind = "reasoning", text = "思考ab" }, { kind = "content", text = "结论cd" } }
  check("全部放得下", joined(Text.tail(segs, 20, measure)) == "reasoning:思考ab|content:结论cd")
  check("截到分段中间", joined(Text.tail(segs, 8, measure)) == "reasoning:ab|content:结论cd", joined(Text.tail(segs, 8, measure)))
  check("宽字放不下不露半个", joined(Text.tail(segs, 9, measure)) == "reasoning:ab|content:结论cd", joined(Text.tail(segs, 9, measure)))
  check("只剩最后一段", joined(Text.tail(segs, 5, measure)) == "content:论cd", joined(Text.tail(segs, 5, measure)))
  local many = {}
  for i = 1, 6 do
    many[i] = { kind = i % 2 == 0 and "content" or "reasoning", text = "x" .. i }
  end
  local pieces = Text.tail(many, 100, measure, 4)
  check("最多拆成 4 段, 保留最新的", #pieces == 4 and pieces[4].text == "x6" and pieces[1].text == "x3", joined(pieces))
  local spaced = Text.tail({ { kind = "content", text = "ab cd" } }, 3, measure)
  check("窗口左端不留空格", joined(spaced) == "content:cd", joined(spaced))
end

do -- 缓冲: 换行换成空格, 同类合并, 超出上限从前面丢
  local b = Text.new_buffer(10)
  b:append("reasoning", "第一行\n第二")
  b:append("reasoning", "行")
  b:append("content", "\n\nok")
  check("同类合并, 换行变空格", #b.segments == 2 and b.segments[1].text == "第一行 第二行", b.segments[1].text)
  check("段间的换行变成一个空格", b.segments[2].text == " ok", b.segments[2].text)
  b:append("content", "12345")
  check("超出上限从前面丢", b.chars == 10 and b.segments[1].text == "二行", b.segments[1].text)
  b:append("content", "abcdefghijk")
  check("整段丢掉", #b.segments == 1 and b.segments[1].text == "bcdefghijk", b.segments[1].text)
end

do -- 开头截取: 报错文字保留开头
  check("放得下原样返回", Text.head("429 重试", 20, measure) == "429 重试")
  check("放不下以省略号结尾", Text.head("请求失败: 429", 8, measure) == "请求...", Text.head("请求失败: 429", 8, measure))
end

do -- key 掩码: 不泄露中间部分
  local key = "sk-abcdefghijklmnopqrstuvwxyz0123456789ab12"
  local masked = Fields.mask_key(key)
  check("长 key 显示首尾", masked:sub(1, 7) == "sk-a...", masked)
  check("长 key 露出末尾", masked:find("ab12", 1, true) ~= nil, masked)
  check("长 key 不含中间部分", not masked:find("mnop", 1, true), masked)
  check("短 key 全部遮住", Fields.mask_key("short-key") == "****")
  check("空 key", Fields.mask_key("") == "未设置" and Fields.mask_key(nil) == "未设置")
  local mid = Fields.mask_key("abcdefghijklmnop")
  check("露出的字数随长度变化", mid:sub(1, 5) == "ab...", mid)
end

do -- 剪贴板清洗
  check("去掉首尾空白", Fields.clean_paste("model", "  gpt-x \n") == "gpt-x")
  check("endpoint 要有协议", Fields.clean_paste("endpoint", "api.example.com/v1") == nil)
  check("endpoint 接受 https", Fields.clean_paste("endpoint", "https://api.example.com/v1/chat/completions") ~= nil)
  check("key 去掉 Bearer 前缀", Fields.clean_paste("api_key", "Bearer sk-123") == "sk-123")
  check("拒绝中间换行", Fields.clean_paste("api_key", "sk-1\nsk-2") == nil)
  check("空剪贴板", Fields.clean_paste("model", "   ") == nil and Fields.clean_paste("model", nil) == nil)
end

do -- runner: 没有 driver 时不启动; 停止与出错各通知一次录像; 超过 token 上限自动暂停
  local Runner = dofile("mods/balatrobot/agent/runner.lua")
  local limit = 0
  Runner.init({
    can_start = function()
      return true
    end,
    demo_enabled = function()
      return false
    end,
    token_limit = function()
      return limit
    end,
  })
  local stops = {}
  Runner.on_stop[1] = function(reason)
    stops[#stops + 1] = reason
  end
  check("没有 driver 时不启动", not Runner.start() and Runner.state == "stopped")
  local calls = {}
  Runner.set_driver({
    start = function()
      calls[#calls + 1] = "start"
    end,
    pause = function()
      calls[#calls + 1] = "pause"
    end,
    stop = function(_, reason)
      calls[#calls + 1] = "stop:" .. reason
    end,
    update = function()
      error("boom")
    end,
  })
  check("有 driver 时启动", Runner.start() and Runner.state == "running")
  Runner.set_phase("requesting")
  check("暂停", Runner.toggle_pause() and Runner.state == "paused" and Runner.is_busy())
  Runner.set_phase("acting")
  check("暂停后忽略晚到的阶段", Runner.state == "paused")
  check("停止", Runner.stop() and Runner.state == "stopped" and stops[1] == "user")
  Runner.start()
  Runner.update(0.016)
  check("driver 报错进入 error", Runner.state == "error" and Runner.stats.last_error:find("boom", 1, true) ~= nil)
  check("出错只通知一次", #stops == 2 and stops[2] == "error" and calls[#calls] == "stop:error", table.concat(stops, ","))
  check("出错后停止不再通知", Runner.stop() and #stops == 2)
  limit = 100
  Runner.set_driver({})
  Runner.start()
  Runner.add_usage(80, 30)
  check("超过 token 上限自动暂停", Runner.state == "paused" and Runner.stats.last_error ~= "")
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
