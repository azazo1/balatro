-- 给 Decision 的自包含观察, 不包含有序牌堆和连接配置.
local M = {}
local RULES = [[
Balatro 的目标是用剩余出牌次数达到当前盲注的目标分.
筹码 x 倍率得分, 乘倍率与加倍率顺序有关, 小丑从左到右结算.
出牌会移走所有选中牌, 不只有计分牌; 留牌效果与红色蜡封也会影响收益.
弃牌消耗一次弃牌机会并补牌. 金钱有利息档, 买卖要比较本局收益与后续成长.
跳盲注获得标签但不进入该盲注后的商店. Boss 不能跳过.
背面牌身份未知, 不能根据不可观察信息决策. 不提供真实摸牌顺序.
结算与弹窗由程序处理, 只在提供的封闭候选中选择, 不生成工具调用或说明文本.
]]

function M.new(deps)
  local observation = {}
  function observation.state(gs, cfg, trail, planning)
    -- 每次新建摘要器, 不因 LLM 的 seen 缓存省掉当前卡牌效果.
    local state = {
      rules = RULES,
      game = deps.summary.new(deps.describe):render(gs),
      settings = { after_win = cfg.after_win, after_run = cfg.after_run, fixed_seed = cfg.seed, strategy = cfg.strategy },
      planning = planning,
      dynamics = deps.dynamics and deps.dynamics() or nil,
      hands = {},
      recent_actions = {},
    }
    for name, hand in pairs(gs.hands or {}) do
      state.hands[name] = { chips = hand.chips, mult = hand.mult, level = hand.level,
        played = hand.played, played_this_round = hand.played_this_round }
    end
    for i = math.max(1, #(trail or {}) - 19), #(trail or {}) do state.recent_actions[#state.recent_actions + 1] = trail[i] end
    -- 字节预算是保守上限, 不声称能精确代替模型 tokenizer.
    while #deps.json.encode(state) > 96 * 1024 and #state.recent_actions > 0 do table.remove(state.recent_actions, 1) end
    if #deps.json.encode(state) > 96 * 1024 then return nil, "Decision 当前观察超过输入预算, 请缩短策略或减少局面复杂度" end
    return state
  end
  return observation
end

return M
