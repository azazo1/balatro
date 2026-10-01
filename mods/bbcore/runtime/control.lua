--[[
谁在操作游戏 (BB_CONTROL). 回放 (bbreplay) 与 agent (balatrobot) 在不同的 mod 里, 靠这里互斥,
彼此不直接引用.

- 独占: 回放开始时 claim("replay"), 结束时 release. 期间 balatrobot 不开 HTTP 端口, 内置 loop 不能开始.
- 忙碌来源: 占着游戏但不独占的一方 (内置 loop 运行或暂停中) 用 add_busy 登记, 回放据此拒绝开始.
- on_change: 独占者变化时通知, balatrobot 据此重新按模式启停 HTTP 服务.
]]

local LOGGER = "BB.CONTROL"

local M = {}

---@type string?
local owner = nil
---@type {name: string, fn: fun(): boolean}[]
local busy_sources = {}
---@type fun(owner: string?, previous: string?)[]
local listeners = {}

local function notify(previous)
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, owner, previous)
    if not ok then
      sendWarnMessage("Control listener failed: " .. tostring(err), LOGGER)
    end
  end
end

--- 当前独占者, 没有时为 nil.
---@return string?
function M.owner()
  return owner
end

--- 登记一个忙碌来源, 例如 balatrobot 的内置 loop.
---@param name string 显示给用户的名字, 例如 "内置 agent"
---@param fn fun(): boolean
function M.add_busy(name, fn)
  busy_sources[#busy_sources + 1] = { name = name, fn = fn }
end

--- 有没有别的东西在操作游戏. 返回第一个忙碌来源的名字.
---@return string? name
function M.busy()
  for _, source in ipairs(busy_sources) do
    local ok, result = pcall(source.fn)
    if ok and result then
      return source.name
    end
  end
  return nil
end

--- 申请独占. 已被别人独占或有忙碌来源时失败, 返回挡住它的那一方 (独占者或忙碌来源的名字).
---@param name string
---@return boolean ok
---@return string? blocker
function M.claim(name)
  if owner == name then
    return true
  end
  if owner then
    return false, owner
  end
  local busy = M.busy()
  if busy then
    return false, busy
  end
  local previous = owner
  owner = name
  sendInfoMessage("Control claimed by " .. name, LOGGER)
  notify(previous)
  return true
end

--- 释放独占. 不是自己独占时不做事.
---@param name string
function M.release(name)
  if owner ~= name then
    return
  end
  owner = nil
  sendInfoMessage("Control released by " .. name, LOGGER)
  notify(name)
end

---@param fn fun(owner: string?, previous: string?)
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

return M
