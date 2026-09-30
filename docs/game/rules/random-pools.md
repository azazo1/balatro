# 随机池与种子

以本仓库 Balatro 1.0.1n 源码为准. 本文说明生成资格, 去重与保底, 隐藏牌替换, 版本和贴纸抽样, 以及随机流状态. 商店操作与包大小见 [商店与补充包](<shop-and-packs.md>), 单卡原型见 [卡牌目录](<../cards/>).

## 1. `create_card` 的生成流水线

普通抽样不是从全目录直接抽一张. 源码调用顺序如下:

1. 若有 `forced_key`, 先跳过隐藏替换判断.
2. 否则若 `soulable=true`, 尝试灵魂/黑洞替换, 成功时设置 `forced_key`.
3. 若 `_type=='Base'`, 强制 `c_base`.
4. 有未禁用的 `forced_key` 时直接选择该原型, 不调用普通卡池, 不检查解锁/重复/增强门槛/池标记/星球软锁. 禁用的强制 key 不会被直接生成, 转普通池路径.
5. 没有有效强制 key 时调用 `get_current_pool`, 按类型和必要的稀有度建池, 抽选并重抽不可用占位.
6. 若类型为 `Base` 或 `Enhanced`, 从 `P_CARDS` 抽牌面.
7. 构造 `Card`, `set_ability` 标记这个原型已占用.
8. 若生成类型为 `Joker`, 应用全永恒挑战设置, 再根据生成区域处理赌注贴纸, 最后抽版本.

`area` 和 `key_append` 是生成输入的一部分, 影响贴纸资格及随机流. `skip_materialize` 只影响显示过程, 不代表跳过抽样. `soulable` 不是 "生成的是幻灵" 的同义词, 必须由调用方显式传 true.

来源: [create_card](<../../../game/functions/common_events.lua#L2082-L2153>), [Card:set_ability](<../../../game/card.lua#L349-L354>).

## 2. 当前卡池的建造与筛选

### 2.1 先选稀有度, 后按资格筛选

小丑 `rarity` 的阈值为 `r<=0.7` 普通, `0.7<r<=0.95` 罕见, `r>0.95` 稀有. 默认抽取 `r=pseudorandom('rarity'..ante..append)`. `_rarity` 参数是阈值输入, **不是稀有度编号**: 调用者传 `0` 可强制普通, `0.9` 强制罕见, `1` 强制稀有. 只有 `_legendary=true` 强制传奇池编号 4.

其他类型使用对应 `P_CENTER_POOLS[type]`; `Tarot_Planet` 是合并的塔罗/星球池. 普通合资格池内按原型等概率, 不按小丑价格/编号再加权. 星球原型虽然定义 `freq=1`, 此处并不读取 `freq`.

| 筛选分支 | 合资格条件 |
| --- | --- |
| `Enhanced` | 原型一律先允许, 再经过最终禁用表检查 |
| `Demo` | 必须同时有 `pos` 与 `config` |
| `Tag` | 若有 `requires`, 该目标原型必须 `discovered`; 若有 `min_ante`, 当前底注达到门槛 |
| 普通类型通用门槛 | 不被重复占用, 或有有效马戏团长; 且 `unlocked ~= false` 或 `rarity==4` |
| `Voucher` | 本局尚未兑换, 所有 `requires` 前置已兑换, 当前券区域里没有同 key |
| `Planet` | 普通星球不限已出牌型; `config.softlock` 星球要求对应 `hands[hand_type].played > 0` |
| 有 `enhancement_gate` 的小丑 | 当前整副牌 `G.playing_cards` 中至少存在该增强 key 的卡 |
| 黑洞与灵魂 | 普通池永远排除 |
| 任意类型最终排除 | `no_pool_flag` 已为真, 或 `yes_pool_flag` 尚不为真, 或 `banned_keys[key]` 为真 |

来源: [get_current_pool](<../../../game/functions/common_events.lua#L1963-L2035>).

### 2.2 解锁与发现不能混同

- `unlocked` 影响通常的抽样资格. 传奇原型即使 `unlocked=false` 也允许进入传奇生成池.
- `discovered` 通常只影响收藏和展示, **未发现的已解锁卡照样会出现在商店/包中**. 生成在商店, 包区, 小丑区和持有消耗牌区会绕过未知卡背面展示.
- 特例是标签 `requires` 看目标原型的 `discovered`, 不是本局已经持有或解锁. 例如部分稀有度/版本标签需要先发现相应卡或版本.
- 游戏启动读取存档后会修改原型解锁和发现状态. 分析实际存档的一次游戏时不能只把原型默认 `unlocked` 当最终值.

来源: [get_current_pool](<../../../game/functions/common_events.lua#L1982-L1988>), [create_card 显示参数](<../../../game/functions/common_events.lua#L2126-L2130>), [Game:init_item_prototypes 标签定义](<../../../game/game.lua#L224-L248>).

### 2.3 去重与马戏团长

`used_jokers` 这个字段名称容易误导: 它不仅标记小丑, 也标记塔罗/星球/幻灵/优惠券等原型.

- `Card:set_ability` 在非覆盖菜单情况下把匹配名称的原型标记为 true. 因此商店未购买的卡, 包中未选择的卡, 持有区卡都可能占用标记.
- 普通生成在标记为 true 时排除同 key. 包里的卡依次构造, 因此已展示位置会使后续位置通常不能再抽同卡.
- `Card:remove` 删除卡后, 用 `find_joker(name,true)` 检查小丑和持有消耗牌区是否还有同名卡. 没有则清空匹配原型标记. 所以这不是 "本局见过一次就永远不再出现".
- 删除/使用/卖出/重掷/退出商店/关闭包可能重新放开资格. 重掷先销毁旧库存再生成新库存, 所以未购买的旧卡可以再次出现.
- 实现清理检查只扫描持有的小丑和消耗牌区, 不扫描所有商店/包对象. 极端多来源/复制状态必须以实际 `used_jokers` 为准, 不应另写一个想当然的全局物件集合去重算法.
- 马戏团长 Showman `j_ring_master` 通过 `find_joker('Showman')` 取消通用重复门槛. 处于减益的小丑默认不被此查询计入, 因而失效的马戏团长不能解除去重.
- 马戏团长不解除解锁, 禁用, 稀有度, 增强门槛, 池标记, 星球软锁, 优惠券本局已兑换与前置限制. 强制指定卡和复制卡有自己的路径, 也不等于需要马戏团长.

来源: [Card:set_ability](<../../../game/card.lua#L349-L354>), [Card:remove](<../../../game/card.lua#L4741-L4748>), [find_joker](<../../../game/functions/misc_functions.lua#L903-L916>), [get_current_pool](<../../../game/functions/common_events.lua#L1987-L2024>).

### 2.4 增强门槛与灭绝标记

仅判断整副牌中现在是否有对应增强, 不要求该卡当前在手牌, 在抽牌区, 未减益, 曾经计分, 或达到多个副本的数量. 收藏解锁条件和本局池门槛是两回事.

| 小丑 key | `enhancement_gate` |
| --- | --- |
| `j_steel_joker` | `m_steel` |
| `j_stone` | `m_stone` |
| `j_lucky_cat` | `m_lucky` |
| `j_ticket` | `m_gold` |
| `j_glass` | `m_glass` |

大麦克香蕉 Gros Michel `j_gros_michel` 带 `no_pool_flag='gros_michel_extinct'`, 卡文迪什 Cavendish `j_cavendish` 带 `yes_pool_flag='gros_michel_extinct'`.

- 本局初始标记空, 大麦克可进入普通池, 卡文迪什不行.
- 大麦克在回合结束的自毁概率触发时把该标记置 true; 后续普通池排除大麦克, 允许卡文迪什.
- 直接卖掉大麦克不会设置灭绝标记. 普通复制/强制生成路径也不替换自毁规则.
- 马戏团长不绕过这两个池标记.

来源: [相关原型](<../../../game/game.lua#L401-L494>), [Gros Michel 自毁](<../../../game/card.lua#L3015-L3037>), [池标记筛选](<../../../game/functions/common_events.lua#L2027-L2028>).

### 2.5 隐藏星球

`c_planet_x`, `c_ceres`, `c_eris` 分别对应 `Five of a Kind`, `Flush House`, `Flush Five`, 具有 `softlock=true`. 只有本局该牌型 `played>0` 才加入普通 Planet/Tarot_Planet 生成池. 不是只要在牌型预览中组成, 不是只要已收藏发现, 也不是只要被黑洞升级过.

望远镜的强制 key 路径跳过普通池资格; 但选择候选牌型时要求 `visible` 且 `played>0`, 正常仍不会凭空强制从未出过的隐藏星球.

来源: [隐藏星球原型](<../../../game/game.lua#L566-L568>), [get_current_pool Planet](<../../../game/functions/common_events.lua#L2008-L2010>), [望远镜](<../../../game/card.lua#L1737-L1754>).

### 2.6 占位重抽与空池保底

筛掉的条目不直接删除, 在原位置放 `UNAVAILABLE`. 按池位置抽选, 若得到此占位, 以 `_pool_key..'_resample'..it` 继续重抽, `it` 从 2 开始. 因此有资格的候选最终可近似视为等概率, 但复现种子时不能把池缩成只含有效项的数组, 那会改变抽样位置和随机流消费.

没有任何合资格原型时改为单条保底, 这条保底不会再经过普通筛选:

| 请求类型 | 保底 |
| --- | --- |
| Tarot / Tarot_Planet | `c_strength` |
| Planet | `c_pluto` |
| Spectral | `c_incantation` |
| Joker / Demo | `j_joker` |
| Voucher | `v_blank` |
| Tag | `tag_handy` |
| 其他 | `j_joker` |

例如传奇池全被占用且没有马戏团长, 生成传奇请求也可能返回普通 `j_joker`. 不能把保底另解释为更换稀有度后重抽.

来源: [get_current_pool 保底](<../../../game/functions/common_events.lua#L2038-L2052>), [create_card 重抽](<../../../game/functions/common_events.lua#L2113-L2121>).

### 2.7 优惠券与包的专用选择器

- `get_next_voucher_key` 使用 Voucher 池, 普通流 key 为 `Voucher..ante`, 标签调用改为 `Voucher_fromtag`, 并有同样的占位重抽.
- 两级优惠券的第二级需要本局已兑换第一级, 收藏解锁第二级不足以满足本局前置. 已兑换的券不再抽到, 直到触发空池保底这种实现例外.
- `get_pack` 不走通用 `used_jokers` 去重或 `unlocked` 筛选. 它依据 `Booster` 原型的 `weight`, 可选 `kind`, 和 `banned_keys` 加权抽取. 普通首次小丑包保证先于这个权重算法.

来源: [get_next_voucher_key](<../../../game/functions/common_events.lua#L1901-L1911>), [get_pack](<../../../game/functions/common_events.lua#L1944-L1960>), [Voucher 筛选](<../../../game/functions/common_events.lua#L1989-L2007>).

## 3. 灵魂与黑洞的隐藏替换

灵魂 The Soul `c_soul` 和黑洞 Black Hole `c_black_hole` 都属于 Spectral, 但不在正常 Spectral 池中抽取.

### 3.1 资格与判定顺序

仅当没有预先指定 `forced_key`, `soulable=true`, 且 `banned_keys['c_soul']` 不为真时, 才进入下列替换区块:

| 请求类型 | 第 1 次判定 | 第 2 次判定 |
| --- | --- | --- |
| Tarot / Tarot_Planet | 灵魂 | 无 |
| Planet | 无 | 黑洞 |
| Spectral | 灵魂 | 黑洞 |
| Base / Enhanced / Joker | 无 | 无 |

每次判定还要求目标未被 `used_jokers` 占用, 或有有效马戏团长. 判定为 `pseudorandom('soul_'..type..ante) > 0.997`, 单次理想均匀概率 0.3%.

Spectral 的顺序是先灵魂, 再黑洞, **两次都可能执行**. 第二次黑洞成功会覆盖第一次灵魂成功的 `forced_key`. 两个目标都合资格时, 若把两次抽样近似为独立均匀数, 最终黑洞 0.3%, 灵魂 `0.003*0.997=0.2991%`, 普通幻灵 99.4009%. 这是概率模型近似, 精确结果须按两次有状态随机调用复现, 不能把它改成一次互斥 0.3%/0.3% 区间.

**本地实现细节**: 外层只检查 `c_soul` 是否禁用, 因而禁用灵魂会同时关闭黑洞的这条隐藏替换路径. 黑洞自身被禁用时, 即使抽到强制黑洞, 后续有效 forced-key 检查也会失败并回普通池. 不要把禁止表仅理解为修改最终权重.

来源: [create_card 隐藏替换](<../../../game/functions/common_events.lua#L2087-L2113>).

### 3.2 哪些来源允许隐藏替换

- 秘术包正常塔罗位置允许灵魂; 有 `v_omen_globe` 且该位置改抽幻灵时允许灵魂和黑洞.
- 天体包正常星球位置允许黑洞. 望远镜已经明确指定星球的第一位置不执行替换; 所有牌型次数为 0 时第一位置未强制, 仍允许替换.
- 幻灵包允许两者.
- 普通商店即使幽灵牌组开放幻灵, 仍没有 `soulable=true`, 不允许这两张隐藏牌.
- 第六感 `j_sixth_sense` 和通灵 `j_seance` 生成幻灵的调用没有 `soulable=true`, 不会生成灵魂/黑洞.
- 后续同包位置通常不能再生成已经展示的相同隐藏牌, 因为第一个 Card 构造已写 `used_jokers`; 马戏团长可解除这一限制.

来源: [Card:open](<../../../game/card.lua#L1730-L1757>), [create_card_for_shop](<../../../game/functions/UI_definitions.lua#L776>), [Sixth Sense](<../../../game/card.lua#L2611>), [Seance](<../../../game/card.lua#L3794>).

## 4. 版本抽样

### 4.1 普通 `poll_edition`

定义 `u=pseudorandom(pseudoseed(key))`, `m=_mod or 1`, `E=G.GAME.edition_rate`. 非保证模式从上到下第一个满足的分支胜出:

```text
若允许负片 且 u > 1 - 0.003*m: Negative
否则若 u > 1 - 0.006*E*m: Polychrome
否则若 u > 1 - 0.020*E*m: Holographic
否则若 u > 1 - 0.040*E*m: Foil
否则: 无版本
```

阈值是累计尾区间, **0.003/0.006/0.02/0.04 不是四个互斥概率**. 正常小丑 `m=1`, 允许负片:

| `E` | 无版本 | 闪箔 Foil | 镭射 Holographic | 多彩 Polychrome | 负片 Negative |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 96% | 2% | 1.4% | 0.3% | 0.3% |
| 2, 打磨 Hone `v_hone` | 92% | 4% | 2.8% | 0.9% | 0.3% |
| 4, 焕彩 Glow Up `v_glow_up` | 84% | 8% | 5.6% | 2.1% | 0.3% |

两级券设置 `E=2/4`, 不是先 x2 再 x4 得 8. 负片阈值不乘 `E`, 所以本地打磨/焕彩不会提高负片概率. 由于负片先抢走顶端区间, 多彩的实际互斥概率不是简单地把默认 0.3% 乘 2 或 4.

标准包 `m=2,_no_neg=true`:

| `E` | 无版本 | 闪箔 | 镭射 | 多彩 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 92% | 4% | 2.8% | 1.2% |
| 2 | 84% | 8% | 5.6% | 2.4% |
| 4 | 68% | 16% | 11.2% | 4.8% |

一般高修正值下应按阈值顺序和 `[0,1]` 区间截断求概率, 不要盲目线性外推到超过 100%.

来源: [poll_edition](<../../../game/functions/common_events.lua#L2055-L2079>), [Card:apply_to_run](<../../../game/card.lua#L1900-L1903>), [版本券原型](<../../../game/game.lua#L594-L611>).

### 4.2 保证版本与特殊来源

`_guaranteed=true` 使用固定系数 25, 不读取 `edition_rate` 或 `_mod`. 不允许负片时概率为闪箔 50%, 镭射 35%, 多彩 15%, 不留无版本区间. 允许负片时为闪箔 50%, 镭射 35%, 多彩 7.5%, 负片 7.5%.

光环 `c_aura` 和命运之轮 `c_wheel_of_fortune` 成功后都调用保证版本并禁止负片; 命运之轮是否成功的前置概率另算. 幻象商店游戏牌也用 50%/35%/15% 的版本内部分布, 但走专用分支, 总获版概率 20%. 版本标签是强制版本, 不用上述概率.

版本抽样, 稀有度, 标准包增强/蜡封, 隐藏牌替换, 贴纸判断都未使用 `G.GAME.probabilities.normal`. 六六大顺 Oops! All 6s `j_oops` 不会提高这些生成概率. 不要把所有带概率的机制都乘同一个全局概率值.

来源: [Aura](<../../../game/card.lua#L1195>), [Wheel](<../../../game/card.lua#L1484>), [保证版分支](<../../../game/functions/common_events.lua#L2058-L2067>), [Illusion](<../../../game/functions/UI_definitions.lua#L786-L793>), [版本标签](<../../../game/tag.lua#L393-L446>).

## 5. 商店和小丑包的贴纸抽样

只有 Joker 生成在 `G.shop_jokers` 或 `G.pack_cards` 时执行赌注贴纸抽样. 消耗牌效果生成到 `G.jokers` 的小丑不走这一步, 所以灵魂生成的传奇通常没有永恒/易腐/租赁, 除非全永恒挑战等另行强制.

1. 若 `modifiers.all_eternal`, 先调用 `set_eternal(true)`.
2. 取一个共享数 `q`:
   - 商店 key `etperpoll..ante`.
   - 包区 key `packetper..ante`.
3. 若允许永恒且 `q>0.7`, 尝试永恒.
4. 否则若允许易腐且 `0.4<q<=0.7`, 尝试易腐.
5. 若允许租赁, 用另一抽样 `r>0.7` 尝试租赁, 可与永恒/易腐叠加.

| 通常赌注累计条件 | 标志 | 对合兼容性卡的尝试概率 |
| --- | --- | ---: |
| 赌注 >=4 | `enable_eternals_in_shop` | 永恒 30% |
| 赌注 >=7 | `enable_perishables_in_shop` | 易腐 30%, 永恒另占 30%, 无两者 40% |
| 赌注 >=8 | `enable_rentals_in_shop` | 独立租赁 30% |

- 永恒/易腐共享 `q`, 互斥, 不是两次各 30% 的独立抽样.
- `set_eternal` 需要 `eternal_compat` 且还不是易腐. `set_perishable` 需要 `perishable_compat` 且还不是永恒.
- 抽到某贴纸区间但此小丑不兼容时, 不改抽另一贴纸. 所以对全部目录统计时贴纸频率会低于简单的 30%.
- 易腐初始剩余回合数 5. 租赁买价 $1, 每回合费用初始 $3. 具体贴纸行为见 [卡牌修饰](<card-modifiers.md>).
- 同一槽的贴纸和版本是不同判断, 可同时带负片和租赁等组合.

来源: [create_card 贴纸](<../../../game/functions/common_events.lua#L2133-L2150>), [Card:set_eternal / set_perishable / set_rental](<../../../game/card.lua#L506-L524>), [Game:start_run 赌注](<../../../game/game.lua#L2032-L2041>), [默认费用与寿命](<../../../game/game.lua#L1896-L1897>).

## 6. 随机种子和状态

### 6.1 命名随机流

游戏保存 `G.GAME.pseudorandom.seed`, `hashed_seed`, 和每个 key 的浮点状态. 不是只维护一个连续 "第 N 次随机" 的全局游戏流.

`pseudohash(str)` 从字符串末字节向前迭代, 初始 `num=1`:

```text
num = ((1.1239285023 / num) * byte(str,i) * pi + pi*i) % 1
```

对 `pseudoseed(key)` 的一次调用:

```text
若 key 尚无状态: state[key] = pseudohash(key .. run_seed)
state[key] = abs(tonumber(format('%.13f', (2.134453429141 + state[key]*1.72431234) % 1)))
返回 (state[key] + hashed_seed) / 2
```

`pseudorandom(seed,min,max)` 若入参是字符串先取其 `pseudoseed`, 然后执行 `math.randomseed(seed)` 并取一次 `math.random` 或整数区间抽样. `pseudorandom_element` 也会 reseed; 它先按 `sort_id` 或 key 排序, 再用 `math.random(#keys)` 选一项. 数组原位置, 对象键顺序和 `sort_id` 都会影响复现.

来源: [pseudohash / pseudoseed / pseudorandom](<../../../game/functions/misc_functions.lua#L279-L319>), [pseudorandom_element](<../../../game/functions/misc_functions.lua#L253-L267>).

### 6.2 常用 key 与复现输入

| 抽样阶段 | 常见命名流 |
| --- | --- |
| 商店类别 | `cdt..ante` |
| 小丑稀有度 | `rarity..ante..append` |
| 普通小丑/其他具体卡 | `Joker..rarity..append..ante` 或 `type..append..ante` |
| 传奇具体卡 | `Joker4`, 不追加底注/来源 append |
| 隐藏替换 | `soul_..type..ante` |
| 新游戏牌牌面 | `front..append..ante` |
| 小丑版本 | `edi..append..ante` |
| 包选择 | `shop_pack..ante` |
| 标准包增强判定 | `stdset..ante` |
| 标准包版本 | `standard_edition..ante` |
| 标准包蜡封判定/颜色 | `stdseal..ante` / `stdsealtype..ante` |
| 当前券 | `Voucher..ante` |
| 标签额外券 | `Voucher_fromtag` |

来源 append 常见 `sho` 商店, `buf` 小丑包, `ar1` 秘术塔罗, `ar2` 秘术幻灵, `pl1` 天体包, `spe` 幻灵包, `sta` 标准包. 被筛掉的候选触发 `..._resample2`, `..._resample3`, ... 的另外命名流.

- 重复相同 key 会推进该 key, 不会重放同一个结果. 换底注通常换 key, 传奇流是例外.
- 同种子若采取不同操作, 如重掷次数, 包打开顺序, 生成其他同流卡, 去重/禁用/解锁变化, 后续抽卡可能不同.
- 不应仅凭相同 seed 保证所有存档/牌组/赌注/收藏状态与操作序列产生相同对象.
- 精确预测还需要当前 `pseudorandom` 各 key 状态, 底注, `used_jokers`, `used_vouchers`, 禁用项, 牌组/券/小丑效果和池排序.
- 幻象的增强试掷在商店类别表构造时就可能消耗 `illusion` 流, 即使最终抽中的不是游戏牌; 复现时需保留代码调用顺序, 不能只模拟已成功的分支.
- 仍有原生 `math.random` 路径, 如首次小丑包图案, `pseudoseed('seed')`. 它们依赖当前全局 RNG 状态, 不完全由独立命名 key 隔离.
- 浮点哈希, 13 位小数格式化, Lua/LuaJIT 原生 RNG 必须与实际运行时一致. 此文提供源码算法, 不承诺跨 RNG 实现的逐次一致性.

来源: [get_current_pool key 拼接](<../../../game/functions/common_events.lua#L1968-L1972>), [池 key 尾部](<../../../game/functions/common_events.lua#L2052>), [create_card key](<../../../game/functions/common_events.lua#L2087-L2150>), [Card:open key](<../../../game/card.lua#L1730-L1774>), [create_card_for_shop](<../../../game/functions/UI_definitions.lua#L765-L788>).

### 6.3 初始种子和金色赌注传奇偏置

指定 `args.seed` 时直接用它, 标记为 seeded; 否则教程可用 `TUTORIAL`, 普通新局调用 `generate_starting_seed`. 创建初始 `hashed_seed=pseudohash(run_seed)`.

自动生成种子通常是 8 个字符, 来自光标位置/停留时间等输入. 金色赌注 `stake>=8` 若传奇池中既有已获得金贴纸的卡又有尚未获得的卡, 会反复生成候选 seed, 通过 `get_first_legendary(seed)` 预判 `Joker4` 的首次结果, 直到它属于未获金贴纸者. 这是**选择初始种子**, 不是灵魂使用时临时换传奇池. 显式给定 seed 不走这个筛种子过程.

所以 Wiki 所述金色赌注首次传奇偏向未获金贴纸卡, 在本地是有条件的新局 seed 筛选, 不是任意指定种子下都无条件保证.

来源: [generate_starting_seed / get_first_legendary](<../../../game/functions/misc_functions.lua#L219-L250>), [Game:start_run seed 初始化](<../../../game/game.lua#L2144-L2150>).

## 7. Wiki 验证, 默认概率与不确定边界

交叉验证页面:

- [The Shop](<https://balatrowiki.org/w/The_Shop>): 与本地默认商店权重, 小丑稀有度, 券改权重, 幻象, 重掷补货范围一致. 其价格算法使用 round half down 概括, 对默认整数价格和折扣结果与本地一致, 精确括号顺序已在 [商店文档](<shop-and-packs.md#8-wiki-交叉验证与版本边界>) 单列.
- [The Soul](<https://balatrowiki.org/w/The_Soul>): 确认每个允许的包位置以 0.3% 尝试灵魂, 普通商店/第六感/通灵不生成, 无马戏团长的包内去重, 传奇池空时普通小丑保底, 金色赌注通过种子筛选偏向未获贴纸传奇.

Wiki 把灵魂/黑洞都概括为每位置 0.3%. 本地 Spectral 请求有两次顺序判定及后者覆盖前者, 因此此文区分单次尝试概率和最终卡结果, 不照搬两个互斥各 0.3%. `c_soul` 禁用连带关闭隐藏黑洞是实现条件, 不是宣称所有版本都有此规则.

文中百分比基于理想均匀随机抽样和默认未禁用的原型池. 有状态伪随机的精确单局序列以实际 key 状态及运行时为准. 未运行游戏或进行大样本统计, 不把源码阈值模型误称为实测独立性结论.
