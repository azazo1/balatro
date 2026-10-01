--[[
回放教程局: 教程的强制内容是写死的常量, 不走随机, 所以同一局可以重现.

- 重建: 开局前把 G.SETTINGS 的教程状态换成回放用的那份 (未完成 + 初始常量). game.lua 的种子,
  优惠券与标签抽取, 以及 UI_definitions.lua 的商店牌都以它为准. 命令行的临时存档里它通常是空的,
  agent 模式还会把 G.F_SKIP_TUTORIAL 打开 (那会让教程直接被算成完成), 所以两处都要临时改掉.
- 引导: 教程引导是一串要点 "下一句" 的浮层 (common_events.lua 的 tutorial_info 与
  button_callbacks.lua 的 tut_next), 录像里没有这类点击. 这里把 G.FUNCS.tutorial_part 换成不显示
  浮层的版本, 只记 hold_parts; tutorial_controller 照常按阶段推进. 它清 forced_tags 与
  forced_voucher 的时机必须和原局一致, 那两步会改变后面抽到的标签和优惠券.

收尾恢复原值: 内存里留着未完成的教程状态, 玩家下次改设置时就会被写回存档.
]]

local M = {}

local saved = nil

--- 值里只有布尔, 字符串, 数字与列表, 够用.
---@param value any
---@return any
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return out
end

--- 回放时用的教程进度, 与 state_events.lua 的 tutorial_controller 里那份初始值一致.
---@return table
function M.initial_progress()
  return {
    forced_shop = { "j_joker", "c_empress" },
    forced_voucher = "v_grabber",
    forced_tags = { "tag_handy", "tag_garbage" },
    hold_parts = {},
    completed_parts = {},
  }
end

--- 引导的替代实现: 不显示浮层, 直接记下这一步展过. tutorial_controller 靠 hold_parts 才推进
--- 后面几步, 而 tutorial_complete 与 forced_* 的清理都挂在那几步上, 所以这一步不能省.
---@param part string
function M.skip_part(part)
  local progress = G.SETTINGS and G.SETTINGS.tutorial_progress
  if type(progress) ~= "table" then
    return
  end
  progress.hold_parts = progress.hold_parts or {}
  progress.hold_parts[part] = true
end

--- 换成回放用的教程状态: 未完成 + 初始常量, 引导不显示浮层.
--- 教程进度优先用回放文件里的快照放回的那一份 (新录像记了它); 旧文件没有, 用初始常量.
function M.install()
  if saved then
    return
  end
  saved = {
    complete = G.SETTINGS.tutorial_complete,
    progress = copy(G.SETTINGS.tutorial_progress),
    skip_flag = G.F_SKIP_TUTORIAL,
    part = G.FUNCS.tutorial_part,
  }
  G.F_SKIP_TUTORIAL = false
  G.SETTINGS.tutorial_complete = false
  if type(G.SETTINGS.tutorial_progress) ~= "table" then
    G.SETTINGS.tutorial_progress = M.initial_progress()
  end
  G.FUNCS.tutorial_part = M.skip_part
end

--- 恢复回放前的值.
function M.restore()
  if not saved then
    return
  end
  G.F_SKIP_TUTORIAL = saved.skip_flag
  G.SETTINGS.tutorial_complete = saved.complete
  G.SETTINGS.tutorial_progress = saved.progress
  if saved.part then
    G.FUNCS.tutorial_part = saved.part
  end
  saved = nil
end

---@return boolean
function M.active()
  return saved ~= nil
end

return M
