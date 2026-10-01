# 星球牌目录
版本: 1.0.1o. 共 12 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [水星 / c_mercury](#c-mercury)
- [金星 / c_venus](#c-venus)
- [地球 / c_earth](#c-earth)
- [火星 / c_mars](#c-mars)
- [木星 / c_jupiter](#c-jupiter)
- [土星 / c_saturn](#c-saturn)
- [天王星 / c_uranus](#c-uranus)
- [海王星 / c_neptune](#c-neptune)
- [冥王星 / c_pluto](#c-pluto)
- [X 行星 / c_planet_x](#c-planet-x)
- [谷神星 / c_ceres](#c-ceres)
- [阋神星 / c_eris](#c-eris)

## 完整条目

<a id="c-mercury"></a>

### 1. 水星 / Mercury

- ID: `c_mercury`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级对子 / +1 倍率并且 / +15 筹码
- 原型参数: `{"hand_type":"Pair"}`.
- 来源: [原型:557](<../../../game/game.lua#L557>).

<a id="c-venus"></a>

### 2. 金星 / Venus

- ID: `c_venus`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级三条 / +2 倍率并且 / +20 筹码
- 原型参数: `{"hand_type":"Three of a Kind"}`.
- 来源: [原型:558](<../../../game/game.lua#L558>).

<a id="c-earth"></a>

### 3. 地球 / Earth

- ID: `c_earth`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级葫芦 / +2 倍率并且 / +25 筹码
- 原型参数: `{"hand_type":"Full House"}`.
- 来源: [原型:559](<../../../game/game.lua#L559>).

<a id="c-mars"></a>

### 4. 火星 / Mars

- ID: `c_mars`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级四条 / +3 倍率并且 / +30 筹码
- 原型参数: `{"hand_type":"Four of a Kind"}`.
- 来源: [原型:560](<../../../game/game.lua#L560>).

<a id="c-jupiter"></a>

### 5. 木星 / Jupiter

- ID: `c_jupiter`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级同花 / +2 倍率并且 / +15 筹码
- 原型参数: `{"hand_type":"Flush"}`.
- 来源: [原型:561](<../../../game/game.lua#L561>).

<a id="c-saturn"></a>

### 6. 土星 / Saturn

- ID: `c_saturn`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级顺子 / +3 倍率并且 / +30 筹码
- 原型参数: `{"hand_type":"Straight"}`.
- 来源: [原型:562](<../../../game/game.lua#L562>).

<a id="c-uranus"></a>

### 7. 天王星 / Uranus

- ID: `c_uranus`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级两对 / +1 倍率并且 / +20 筹码
- 原型参数: `{"hand_type":"Two Pair"}`.
- 来源: [原型:563](<../../../game/game.lua#L563>).

<a id="c-neptune"></a>

### 8. 海王星 / Neptune

- ID: `c_neptune`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级同花顺 / +4 倍率并且 / +40 筹码
- 原型参数: `{"hand_type":"Straight Flush"}`.
- 来源: [原型:564](<../../../game/game.lua#L564>).

<a id="c-pluto"></a>

### 9. 冥王星 / Pluto

- ID: `c_pluto`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级高牌 / +1 倍率并且 / +10 筹码
- 原型参数: `{"hand_type":"High Card"}`.
- 来源: [原型:565](<../../../game/game.lua#L565>).

<a id="c-planet-x"></a>

### 10. X 行星 / Planet X

- ID: `c_planet_x`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级五条 / +3 倍率并且 / +35 筹码
- 原型参数: `{"hand_type":"Five of a Kind","softlock":true}`.
- 来源: [原型:566](<../../../game/game.lua#L566>).

<a id="c-ceres"></a>

### 11. 谷神星 / Ceres

- ID: `c_ceres`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级同花葫芦 / +4 倍率并且 / +40 筹码
- 原型参数: `{"hand_type":"Flush House","softlock":true}`.
- 来源: [原型:567](<../../../game/game.lua#L567>).

<a id="c-eris"></a>

### 12. 阋神星 / Eris

- ID: `c_eris`.
- 基价: $3.
- 效果: (等级[当前等级]) / 升级同花五条 / +3 倍率并且 / +50 筹码
- 原型参数: `{"hand_type":"Flush Five","softlock":true}`.
- 来源: [原型:568](<../../../game/game.lua#L568>).
