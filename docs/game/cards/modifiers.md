# 特殊修饰目录

[总索引](<../README.md>). 这里补充小丑贴纸, 固定位置和负片消耗牌. 计分及失效规则见 [卡牌修饰规则](<../rules/card-modifiers.md>).

## 永恒卡 / Eternal

- ID: `eternal`.
- 效果: 不能出售 / 或被摧毁

## 易腐 / Perishable

- ID: `perishable`.
- 效果: 经过 5 回合后 / 会被削弱 / (剩余[剩余有效回合]回合)

## 租用 / Rental

- ID: `rental`.
- 效果: 售价为 $1,在回合 / 结束时失去 $3

## 固定 / Pinned

- ID: `pinned_left`.
- 效果: 这张小丑牌 / 固定在 / 最左侧

## 负片 / Negative

- ID: `e_negative_consumable`.
- 效果: +1 个消耗牌槽位

来源: [小丑修饰提示](<../../../game/functions/common_events.lua#L2722-L2737>), [版本与负片消耗牌](<../../../game/localization/en-us.lua#L332-L373>).
