--[[
agent 模式状态机, 纯逻辑, 不依赖 G/SMODS, 可以用 luajit 单测.

三种模式互斥:
- off: 不监听端口, 不运行内置 loop.
- external: HTTP 服务监听端口, 由 just agent-call 这类外部 agent 控制.
- builtin: 不监听端口, 允许启动内置 loop.

切换规则:
- external 与 builtin 之间不能直接切换, 必须先切到 off.
- 内置 loop 运行中 (含暂停, 等待重试) 不能切换, 先停止.
- 启动时设了 BALATROBOT_ENABLE=1: 锁定为 external, 不写回配置.
- 回放进行时锁定, 且不监听端口 (回放驱动独占游戏).

副作用 (启停 HTTP 服务, 写配置) 都经 new() 注入的回调完成.
]]

local M = {}

M.MODES = { "off", "external", "builtin" }

M.LABELS = {
  off = "关闭",
  external = "外部",
  builtin = "内置",
}

local VALID = { off = true, external = true, builtin = true }

---@param mode any
---@return boolean
function M.valid(mode)
  return VALID[mode] == true
end

---@class BBModeOptions
---@field initial string? 配置里保存的模式
---@field env_locked boolean? 启动时由环境变量锁定为 external
---@field replaying (fun(): boolean)? 回放是否进行中
---@field runner_busy (fun(): boolean)? 内置 loop 是否在运行 (含暂停)
---@field set_listening (fun(on: boolean, reason: string?))? 启停 HTTP 服务
---@field persist (fun(mode: string))? 写回配置
---@field log (fun(text: string))?

---@class BBMode
---@field current string
---@field env_locked boolean

---@param options BBModeOptions
---@return table
function M.new(options)
  options = options or {}
  local self = {
    env_locked = options.env_locked == true,
    current = "off",
  }
  if self.env_locked then
    self.current = "external"
  elseif VALID[options.initial] then
    self.current = options.initial
  end

  local function replaying()
    return options.replaying ~= nil and options.replaying() == true
  end

  local function log(text)
    if options.log then
      options.log(text)
    end
  end

  --- 整个模式选择被锁定的原因, 没有锁定时为 nil.
  ---@return string?
  function self.lock_reason()
    if self.env_locked then
      return "由环境变量 BALATROBOT_ENABLE=1 锁定为外部模式"
    end
    if replaying() then
      return "回放进行中"
    end
    return nil
  end

  --- 能否切换到 target, 不能时返回原因.
  ---@param target string
  ---@return boolean ok
  ---@return string? reason
  function self.can_set(target)
    if not VALID[target] then
      return false, "未知模式: " .. tostring(target)
    end
    if target == self.current then
      return true
    end
    local locked = self.lock_reason()
    if locked then
      return false, locked
    end
    if options.runner_busy and options.runner_busy() then
      return false, "内置 agent 运行中, 先停止"
    end
    if target ~= "off" and self.current ~= "off" then
      return false, "外部与内置之间要先切到关闭"
    end
    return true
  end

  --- 按当前模式启停 HTTP 服务. 回放时不监听.
  function self.apply()
    if not options.set_listening then
      return
    end
    if replaying() then
      options.set_listening(false, "replaying")
      return
    end
    options.set_listening(self.current == "external")
  end

  --- 切换模式. 成功时启停服务并写回配置 (环境变量锁定时不写回).
  ---@param target string
  ---@return boolean ok
  ---@return string? reason
  function self.set(target)
    local ok, reason = self.can_set(target)
    if not ok then
      return false, reason
    end
    if target == self.current then
      return true
    end
    local previous = self.current
    self.current = target
    log("Agent mode " .. previous .. " -> " .. target)
    if options.persist and not self.env_locked then
      options.persist(target)
    end
    self.apply()
    return true
  end

  ---@return boolean
  function self.is_builtin()
    return self.current == "builtin"
  end

  ---@return boolean
  function self.is_external()
    return self.current == "external"
  end

  return self
end

return M
