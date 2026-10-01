# 塔罗牌目录
版本: 1.0.1o. 共 22 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [愚者 / c_fool](#c-fool)
- [魔术师 / c_magician](#c-magician)
- [女祭司 / c_high_priestess](#c-high-priestess)
- [皇后 / c_empress](#c-empress)
- [皇帝 / c_emperor](#c-emperor)
- [教皇 / c_heirophant](#c-heirophant)
- [恋人 / c_lovers](#c-lovers)
- [战车 / c_chariot](#c-chariot)
- [正义 / c_justice](#c-justice)
- [隐者 / c_hermit](#c-hermit)
- [命运之轮 / c_wheel_of_fortune](#c-wheel-of-fortune)
- [力量 / c_strength](#c-strength)
- [倒吊人 / c_hanged_man](#c-hanged-man)
- [死神 / c_death](#c-death)
- [节制 / c_temperance](#c-temperance)
- [恶魔 / c_devil](#c-devil)
- [塔 / c_tower](#c-tower)
- [星星 / c_star](#c-star)
- [月亮 / c_moon](#c-moon)
- [太阳 / c_sun](#c-sun)
- [审判 / c_judgement](#c-judgement)
- [世界 / c_world](#c-world)

## 完整条目

<a id="c-fool"></a>

### 1. 愚者 / The Fool

- ID: `c_fool`.
- 基价: $3.
- 效果: 生成本赛局中 / 上一次使用的 / 塔罗牌或星球牌 / 不包括愚者
- 来源: [原型:533](<../../../game/game.lua#L533>).

<a id="c-magician"></a>

### 2. 魔术师 / The Magician

- ID: `c_magician`.
- 基价: $3.
- 效果: 增强 2 张 / 选定卡牌成为 / 幸运牌
- 原型参数: `{"max_highlighted":2,"mod_conv":"m_lucky"}`.
- 来源: [原型:534](<../../../game/game.lua#L534>).

<a id="c-high-priestess"></a>

### 3. 女祭司 / The High Priestess

- ID: `c_high_priestess`.
- 基价: $3.
- 效果: 生成最多 2 张 / 张随机星球牌 / (必须有空位)
- 原型参数: `{"planets":2}`.
- 来源: [原型:535](<../../../game/game.lua#L535>).

<a id="c-empress"></a>

### 4. 皇后 / The Empress

- ID: `c_empress`.
- 基价: $3.
- 效果: 增强 2 张 / 选定卡牌成为 / 倍率牌
- 原型参数: `{"max_highlighted":2,"mod_conv":"m_mult"}`.
- 来源: [原型:536](<../../../game/game.lua#L536>).

<a id="c-emperor"></a>

### 5. 皇帝 / The Emperor

- ID: `c_emperor`.
- 基价: $3.
- 效果: 生成最多 2 张 / 随机塔罗牌 / (必须有空位)
- 原型参数: `{"tarots":2}`.
- 来源: [原型:537](<../../../game/game.lua#L537>).

<a id="c-heirophant"></a>

### 6. 教皇 / The Hierophant

- ID: `c_heirophant`.
- 基价: $3.
- 效果: 增强 2 张 / 选定卡牌成为 / 奖励牌
- 原型参数: `{"max_highlighted":2,"mod_conv":"m_bonus"}`.
- 来源: [原型:538](<../../../game/game.lua#L538>).

<a id="c-lovers"></a>

### 7. 恋人 / The Lovers

- ID: `c_lovers`.
- 基价: $3.
- 效果: 增强 1 张 / 选定卡牌成为 / 万能牌
- 原型参数: `{"max_highlighted":1,"mod_conv":"m_wild"}`.
- 来源: [原型:539](<../../../game/game.lua#L539>).

<a id="c-chariot"></a>

### 8. 战车 / The Chariot

- ID: `c_chariot`.
- 基价: $3.
- 效果: 增强 1 张 / 选定卡牌成为 / 钢铁牌
- 原型参数: `{"max_highlighted":1,"mod_conv":"m_steel"}`.
- 来源: [原型:540](<../../../game/game.lua#L540>).

<a id="c-justice"></a>

### 9. 正义 / Justice

- ID: `c_justice`.
- 基价: $3.
- 效果: 增强 1 张 / 选定卡牌成为 / 玻璃牌
- 原型参数: `{"max_highlighted":1,"mod_conv":"m_glass"}`.
- 来源: [原型:541](<../../../game/game.lua#L541>).

<a id="c-hermit"></a>

### 10. 隐者 / The Hermit

- ID: `c_hermit`.
- 基价: $3.
- 效果: 资金加倍 / (最高 $20)
- 原型参数: `{"extra":20}`.
- 来源: [原型:542](<../../../game/game.lua#L542>).

<a id="c-wheel-of-fortune"></a>

### 11. 命运之轮 / The Wheel of Fortune

- ID: `c_wheel_of_fortune`.
- 基价: $3.
- 效果: 有[概率倍率 normal, 默认 1]/4 几率 / 给一张随机小丑牌 / 添加闪箔,镭射 / 或多彩版本
- 原型参数: `{"extra":4}`.
- 来源: [原型:543](<../../../game/game.lua#L543>).

<a id="c-strength"></a>

### 12. 力量 / Strength

- ID: `c_strength`.
- 基价: $3.
- 效果: 将最多 2 张 / 选定卡牌 / 点数提高 1
- 原型参数: `{"max_highlighted":2,"mod_conv":"up_rank"}`.
- 来源: [原型:544](<../../../game/game.lua#L544>).

<a id="c-hanged-man"></a>

### 13. 倒吊人 / The Hanged Man

- ID: `c_hanged_man`.
- 基价: $3.
- 效果: 摧毁最多 2 张 / 选定卡牌
- 原型参数: `{"max_highlighted":2,"remove_card":true}`.
- 来源: [原型:545](<../../../game/game.lua#L545>).

<a id="c-death"></a>

### 14. 死神 / Death

- ID: `c_death`.
- 基价: $3.
- 效果: 选定 2 张卡牌, / 将靠左的那张牌 / 变成靠右的那张牌 / (你可以拖动来改变位置)
- 原型参数: `{"max_highlighted":2,"min_highlighted":2,"mod_conv":"card"}`.
- 来源: [原型:546](<../../../game/game.lua#L546>).

<a id="c-temperance"></a>

### 15. 节制 / Temperance

- ID: `c_temperance`.
- 基价: $3.
- 效果: 获得拥有的小丑牌 / 售出价格总和的 / 资金(最高 $50) / (当前 $[当前可得金额])
- 原型参数: `{"extra":50}`.
- 来源: [原型:547](<../../../game/game.lua#L547>).

<a id="c-devil"></a>

### 16. 恶魔 / The Devil

- ID: `c_devil`.
- 基价: $3.
- 效果: 增强 1 张 / 选定卡牌成为 / 黄金牌
- 原型参数: `{"max_highlighted":1,"mod_conv":"m_gold"}`.
- 来源: [原型:548](<../../../game/game.lua#L548>).

<a id="c-tower"></a>

### 17. 塔 / The Tower

- ID: `c_tower`.
- 基价: $3.
- 效果: 增强 1 张 / 选定卡牌成为 / 石头牌
- 原型参数: `{"max_highlighted":1,"mod_conv":"m_stone"}`.
- 来源: [原型:549](<../../../game/game.lua#L549>).

<a id="c-star"></a>

### 18. 星星 / The Star

- ID: `c_star`.
- 基价: $3.
- 效果: 将最多 3 张 / 选定卡牌 / 转换为方片
- 原型参数: `{"max_highlighted":3,"suit_conv":"Diamonds"}`.
- 来源: [原型:550](<../../../game/game.lua#L550>).

<a id="c-moon"></a>

### 19. 月亮 / The Moon

- ID: `c_moon`.
- 基价: $3.
- 效果: 将最多 3 张 / 选定卡牌 / 转换为梅花
- 原型参数: `{"max_highlighted":3,"suit_conv":"Clubs"}`.
- 来源: [原型:551](<../../../game/game.lua#L551>).

<a id="c-sun"></a>

### 20. 太阳 / The Sun

- ID: `c_sun`.
- 基价: $3.
- 效果: 将最多 3 张 / 选定卡牌 / 转换为红桃
- 原型参数: `{"max_highlighted":3,"suit_conv":"Hearts"}`.
- 来源: [原型:552](<../../../game/game.lua#L552>).

<a id="c-judgement"></a>

### 21. 审判 / Judgement

- ID: `c_judgement`.
- 基价: $3.
- 效果: 生成一张随机的 / 小丑牌 / (必须有空位)
- 来源: [原型:553](<../../../game/game.lua#L553>).

<a id="c-world"></a>

### 22. 世界 / The World

- ID: `c_world`.
- 基价: $3.
- 效果: 将最多 3 张 / 选定卡牌 / 转换为黑桃
- 原型参数: `{"max_highlighted":3,"suit_conv":"Spades"}`.
- 来源: [原型:554](<../../../game/game.lua#L554>).
