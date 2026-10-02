--[[
补充包打开或关掉之后, 端点要等多久才返回.

商店买的包关掉后回到 SHOP. 跳过盲注的标签 (魅力 / 空灵 / 流星等) 会从 BLIND_SELECT 打开
5 选 2 或幻灵包, 关掉后回到 BLIND_SELECT. 以前 pack() 死等 SHOP, 请求一直不返回, 内置
loop 占着调用, 画面停在选盲注, 直到人打开选项弹窗把等待中的请求拆掉.
]]

local M = {}

local PACK_STATE_KEYS = {
  "SMODS_BOOSTER_OPENED",
  "PLAY_TAROT",
  "TAROT_PACK",
  "PLANET_PACK",
  "SPECTRAL_PACK",
  "STANDARD_PACK",
  "BUFFOON_PACK",
}

---@param state any G.STATE
---@param states table G.STATES
---@return boolean
function M.in_pack(state, states)
  if type(states) ~= "table" then
    return false
  end
  for _, key in ipairs(PACK_STATE_KEYS) do
    if state == states[key] then
      return true
    end
  end
  return false
end

---@param pack_cards table?
---@return boolean
function M.pack_open(pack_cards)
  return pack_cards ~= nil
    and not pack_cards.REMOVED
    and type(pack_cards.cards) == "table"
    and pack_cards.cards[1] ~= nil
end

--- 标签动画用数字 ID 上锁. skip_blind / frame / wipe 这类控制器内部锁不算.
---@param locks table?
---@return boolean
function M.extra_lock(locks)
  if type(locks) ~= "table" then
    return false
  end
  for key, on in pairs(locks) do
    if on and type(key) == "number" then
      return true
    end
  end
  return false
end

--- 选完一张 (或点跳过) 之后: 还要再选就等包仍开着, 否则等包关掉并回到打开前的界面.
---@param opts table
---@return string|nil "remain" 还能再选, "done" 包已关掉, nil 继续等
function M.after_pick(opts)
  local states = opts.states
  if not opts.skip then
    local before = tonumber(opts.choices_before) or 0
    local now = tonumber(opts.choices_now) or 0
    if before > 1 and now == before - 1 then
      if
        opts.pack_open
        and opts.state_complete
        and states
        and opts.state == states.SMODS_BOOSTER_OPENED
      then
        return "remain"
      end
      return nil
    end
  end
  if opts.pack_open or M.in_pack(opts.state, states) then
    return nil
  end
  if opts.return_to then
    if opts.state == opts.return_to then
      return "done"
    end
    return nil
  end
  if states and (opts.state == states.SHOP or opts.state == states.BLIND_SELECT) then
    return "done"
  end
  return nil
end

--- skip() 等到标签把包打开, 或者确认没有包、已经停在选盲注.
---@param opts table
---@return string|nil "pack" 包已打开, "select" 仍在选盲注, nil 继续等
function M.skip_done(opts)
  local states = opts.states
  if not states then
    return nil
  end
  if opts.state == states.SMODS_BOOSTER_OPENED then
    if opts.pack_open and opts.state_complete then
      return "pack"
    end
    return nil
  end
  if M.in_pack(opts.state, states) then
    return nil
  end
  if opts.state == states.BLIND_SELECT and opts.skipped then
    if opts.pack_open or opts.booster_pack or opts.pack_interrupt or M.extra_lock(opts.locks) then
      return nil
    end
    return "select"
  end
  return nil
end

return M
