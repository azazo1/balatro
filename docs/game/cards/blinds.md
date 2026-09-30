# 盲注目录
版本: 1.0.1n. 共 30 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [小盲注 / bl_small](#bl-small)
- [大盲注 / bl_big](#bl-big)
- [钩子 / bl_hook](#bl-hook)
- [公牛 / bl_ox](#bl-ox)
- [房屋 / bl_house](#bl-house)
- [围墙 / bl_wall](#bl-wall)
- [车轮 / bl_wheel](#bl-wheel)
- [手臂 / bl_arm](#bl-arm)
- [梅花 / bl_club](#bl-club)
- [鱼 / bl_fish](#bl-fish)
- [灵媒 / bl_psychic](#bl-psychic)
- [挑衅 / bl_goad](#bl-goad)
- [水 / bl_water](#bl-water)
- [窗口 / bl_window](#bl-window)
- [镣铐 / bl_manacle](#bl-manacle)
- [眼睛 / bl_eye](#bl-eye)
- [嘴巴 / bl_mouth](#bl-mouth)
- [植物 / bl_plant](#bl-plant)
- [巨蟒 / bl_serpent](#bl-serpent)
- [支柱 / bl_pillar](#bl-pillar)
- [针 / bl_needle](#bl-needle)
- [头部 / bl_head](#bl-head)
- [牙齿 / bl_tooth](#bl-tooth)
- [燧石 / bl_flint](#bl-flint)
- [标记 / bl_mark](#bl-mark)
- [琥珀之实 / bl_final_acorn](#bl-final-acorn)
- [翠绿之叶 / bl_final_leaf](#bl-final-leaf)
- [靛紫之杯 / bl_final_vessel](#bl-final-vessel)
- [绯红之心 / bl_final_heart](#bl-final-heart)
- [蔚蓝之铃 / bl_final_bell](#bl-final-bell)

## 完整条目

<a id="bl-small"></a>

### 1. 小盲注 / Small Blind

- ID: `bl_small`.
- 效果: 无特殊效果
- 基础分乘数: 1; 击败奖励: $3.
- 来源: [原型:264](<../../../game/game.lua#L264>).

<a id="bl-big"></a>

### 2. 大盲注 / Big Blind

- ID: `bl_big`.
- 效果: 无特殊效果
- 基础分乘数: 1.5; 击败奖励: $4.
- 来源: [原型:265](<../../../game/game.lua#L265>).

<a id="bl-hook"></a>

### 3. 钩子 / The Hook

- ID: `bl_hook`.
- 效果: 每次出牌 / 随机弃掉 2 张手牌
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":1}`.
- 来源: [原型:267](<../../../game/game.lua#L267>).

<a id="bl-ox"></a>

### 4. 公牛 / The Ox

- ID: `bl_ox`.
- 效果: 打出[本盲注固定惩罚牌型]牌型时 / 资金归 $0
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":6}`.
- 来源: [原型:266](<../../../game/game.lua#L266>).

<a id="bl-house"></a>

### 5. 房屋 / The House

- ID: `bl_house`.
- 效果: 第一次的手牌 / 以背面朝上方式抽取
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:274](<../../../game/game.lua#L274>).

<a id="bl-wall"></a>

### 6. 围墙 / The Wall

- ID: `bl_wall`.
- 效果: 特大盲注
- 基础分乘数: 4; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:273](<../../../game/game.lua#L273>).

<a id="bl-wheel"></a>

### 7. 车轮 / The Wheel

- ID: `bl_wheel`.
- 效果: /7 几率,抽到的牌 / 会是背面朝上
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:278](<../../../game/game.lua#L278>).

<a id="bl-arm"></a>

### 8. 手臂 / The Arm

- ID: `bl_arm`.
- 效果: 降低打出的 / 牌型等级
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:279](<../../../game/game.lua#L279>).

<a id="bl-club"></a>

### 9. 梅花 / The Club

- ID: `bl_club`.
- 效果: 所有梅花牌 / 都被削弱
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":1}`.
- 来源: [原型:270](<../../../game/game.lua#L270>).

<a id="bl-fish"></a>

### 10. 鱼 / The Fish

- ID: `bl_fish`.
- 效果: 出牌后自动抽取的牌 / 都是背面朝上
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:269](<../../../game/game.lua#L269>).

<a id="bl-psychic"></a>

### 11. 灵媒 / The Psychic

- ID: `bl_psychic`.
- 效果: 必须出 5 张牌
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":1}`.
- 来源: [原型:280](<../../../game/game.lua#L280>).

<a id="bl-goad"></a>

### 12. 挑衅 / The Goad

- ID: `bl_goad`.
- 效果: 所有黑桃牌 / 都被削弱
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":1}`.
- 来源: [原型:281](<../../../game/game.lua#L281>).

<a id="bl-water"></a>

### 13. 水 / The Water

- ID: `bl_water`.
- 效果: 初始弃牌 / 次数为 0
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:282](<../../../game/game.lua#L282>).

<a id="bl-window"></a>

### 14. 窗口 / The Window

- ID: `bl_window`.
- 效果: 所有方片牌 / 都被削弱
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":1}`.
- 来源: [原型:289](<../../../game/game.lua#L289>).

<a id="bl-manacle"></a>

### 15. 镣铐 / The Manacle

- ID: `bl_manacle`.
- 效果: 手牌上限-1
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":1}`.
- 来源: [原型:271](<../../../game/game.lua#L271>).

<a id="bl-eye"></a>

### 16. 眼睛 / The Eye

- ID: `bl_eye`.
- 效果: 本回合中不可 / 打出重复牌型
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":3}`.
- 来源: [原型:283](<../../../game/game.lua#L283>).

<a id="bl-mouth"></a>

### 17. 嘴巴 / The Mouth

- ID: `bl_mouth`.
- 效果: 本回合只能打出 / 1 种牌型
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:268](<../../../game/game.lua#L268>).

<a id="bl-plant"></a>

### 18. 植物 / The Plant

- ID: `bl_plant`.
- 效果: 所有人头牌 / 都被削弱
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":4}`.
- 来源: [原型:284](<../../../game/game.lua#L284>).

<a id="bl-serpent"></a>

### 19. 巨蟒 / The Serpent

- ID: `bl_serpent`.
- 效果: 出牌或弃牌后 / 总是抽 3 张牌
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":5}`.
- 来源: [原型:290](<../../../game/game.lua#L290>).

<a id="bl-pillar"></a>

### 20. 支柱 / The Pillar

- ID: `bl_pillar`.
- 效果: 在这一底注中 / 打出过的牌都被削弱
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":1}`.
- 来源: [原型:291](<../../../game/game.lua#L291>).

<a id="bl-needle"></a>

### 21. 针 / The Needle

- ID: `bl_needle`.
- 效果: 本回合只能出一次牌
- 基础分乘数: 1; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:285](<../../../game/game.lua#L285>).

<a id="bl-head"></a>

### 22. 头部 / The Head

- ID: `bl_head`.
- 效果: 所有红桃牌 / 都被削弱
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":1}`.
- 来源: [原型:286](<../../../game/game.lua#L286>).

<a id="bl-tooth"></a>

### 23. 牙齿 / The Tooth

- ID: `bl_tooth`.
- 效果: 每出一张牌 / 损失 $1
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":3}`.
- 来源: [原型:272](<../../../game/game.lua#L272>).

<a id="bl-flint"></a>

### 24. 燧石 / The Flint

- ID: `bl_flint`.
- 效果: 基础筹码和 / 倍率减半
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:292](<../../../game/game.lua#L292>).

<a id="bl-mark"></a>

### 25. 标记 / The Mark

- ID: `bl_mark`.
- 效果: 所有人头牌都是 / 以背面朝上的方式抽取
- 基础分乘数: 2; 击败奖励: $5.
- Boss 候选条件原型: `{"max":10,"min":2}`.
- 来源: [原型:275](<../../../game/game.lua#L275>).

<a id="bl-final-acorn"></a>

### 26. 琥珀之实 / Amber Acorn

- ID: `bl_final_acorn`.
- 效果: 翻转并洗乱 / 所有小丑牌
- 基础分乘数: 2; 击败奖励: $8.
- Boss 候选条件原型: `{"max":10,"min":10,"showdown":true}`.
- 来源: [原型:293](<../../../game/game.lua#L293>).

<a id="bl-final-leaf"></a>

### 27. 翠绿之叶 / Verdant Leaf

- ID: `bl_final_leaf`.
- 效果: 所有卡牌都被削弱 / 直到售出 1 张小丑牌
- 基础分乘数: 2; 击败奖励: $8.
- Boss 候选条件原型: `{"max":10,"min":10,"showdown":true}`.
- 来源: [原型:287](<../../../game/game.lua#L287>).

<a id="bl-final-vessel"></a>

### 28. 靛紫之杯 / Violet Vessel

- ID: `bl_final_vessel`.
- 效果: 超大盲注
- 基础分乘数: 6; 击败奖励: $8.
- Boss 候选条件原型: `{"max":10,"min":10,"showdown":true}`.
- 来源: [原型:288](<../../../game/game.lua#L288>).

<a id="bl-final-heart"></a>

### 29. 绯红之心 / Crimson Heart

- ID: `bl_final_heart`.
- 效果: 每次出牌 / 使随机一张小丑牌失效
- 基础分乘数: 2; 击败奖励: $8.
- Boss 候选条件原型: `{"max":10,"min":10,"showdown":true}`.
- 来源: [原型:294](<../../../game/game.lua#L294>).

<a id="bl-final-bell"></a>

### 30. 蔚蓝之铃 / Cerulean Bell

- ID: `bl_final_bell`.
- 效果: 迫使 1 张牌 / 总是被选中
- 基础分乘数: 2; 击败奖励: $8.
- Boss 候选条件原型: `{"max":10,"min":10,"showdown":true}`.
- 来源: [原型:277](<../../../game/game.lua#L277>).
