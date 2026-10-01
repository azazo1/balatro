# 小丑牌目录
版本: 1.0.1o. 共 150 项. [总索引](<../README.md>).
以下效果直接由游戏原型和本地化生成. 方括号标记需要从当前局状态读取的动态值, 不是固定奖励. 价格为无版本, 无折扣, 无通胀的原型基价. 解锁状态是新档初始值, 不是 user 当前存档状态.
小丑兼容标记仅表示能否复制或带贴纸, 不代表成长副作用能被复制. 精确触发和边界以 [规则](<../rules/scoring.md>) 及 [机制](<../mechanics/joker-mechanics.md>) 为准.
## 快速定位
- [小丑 / j_joker](#j-joker)
- [贪婪小丑 / j_greedy_joker](#j-greedy-joker)
- [色欲小丑 / j_lusty_joker](#j-lusty-joker)
- [愤怒小丑 / j_wrathful_joker](#j-wrathful-joker)
- [暴食小丑 / j_gluttenous_joker](#j-gluttenous-joker)
- [开心小丑 / j_jolly](#j-jolly)
- [古怪小丑 / j_zany](#j-zany)
- [疯狂小丑 / j_mad](#j-mad)
- [狂野小丑 / j_crazy](#j-crazy)
- [滑稽小丑 / j_droll](#j-droll)
- [奸诈小丑 / j_sly](#j-sly)
- [狡猾小丑 / j_wily](#j-wily)
- [聪敏小丑 / j_clever](#j-clever)
- [阴险小丑 / j_devious](#j-devious)
- [精明小丑 / j_crafty](#j-crafty)
- [半张小丑 / j_half](#j-half)
- [模具小丑 / j_stencil](#j-stencil)
- [四指 / j_four_fingers](#j-four-fingers)
- [哑剧演员 / j_mime](#j-mime)
- [信用卡 / j_credit_card](#j-credit-card)
- [仪式匕首 / j_ceremonial](#j-ceremonial)
- [旗帜 / j_banner](#j-banner)
- [神秘之峰 / j_mystic_summit](#j-mystic-summit)
- [大理石小丑 / j_marble](#j-marble)
- [积分卡 / j_loyalty_card](#j-loyalty-card)
- [八号球 / j_8_ball](#j-8-ball)
- [印错小丑 / j_misprint](#j-misprint)
- [黄昏 / j_dusk](#j-dusk)
- [致胜之拳 / j_raised_fist](#j-raised-fist)
- [混沌小丑 / j_chaos](#j-chaos)
- [斐波那契 / j_fibonacci](#j-fibonacci)
- [钢铁小丑 / j_steel_joker](#j-steel-joker)
- [恐怖面孔 / j_scary_face](#j-scary-face)
- [抽象小丑 / j_abstract](#j-abstract)
- [延迟满足 / j_delayed_grat](#j-delayed-grat)
- [烂脱口秀演员 / j_hack](#j-hack)
- [幻视 / j_pareidolia](#j-pareidolia)
- [大麦克香蕉 / j_gros_michel](#j-gros-michel)
- [偶数史蒂文 / j_even_steven](#j-even-steven)
- [奇数托德 / j_odd_todd](#j-odd-todd)
- [学者 / j_scholar](#j-scholar)
- [名片 / j_business](#j-business)
- [超新星 / j_supernova](#j-supernova)
- [搭乘巴士 / j_ride_the_bus](#j-ride-the-bus)
- [太空小丑 / j_space](#j-space)
- [鸡蛋 / j_egg](#j-egg)
- [窃贼 / j_burglar](#j-burglar)
- [黑板 / j_blackboard](#j-blackboard)
- [跑步选手 / j_runner](#j-runner)
- [冰淇淋 / j_ice_cream](#j-ice-cream)
- [DNA / j_dna](#j-dna)
- [飞溅 / j_splash](#j-splash)
- [蓝色小丑 / j_blue_joker](#j-blue-joker)
- [第六感 / j_sixth_sense](#j-sixth-sense)
- [星座 / j_constellation](#j-constellation)
- [徒步者 / j_hiker](#j-hiker)
- [无面小丑 / j_faceless](#j-faceless)
- [绿色小丑 / j_green_joker](#j-green-joker)
- [叠加态 / j_superposition](#j-superposition)
- [待办清单 / j_todo_list](#j-todo-list)
- [卡文迪什 / j_cavendish](#j-cavendish)
- [老千小丑 / j_card_sharp](#j-card-sharp)
- [红牌 / j_red_card](#j-red-card)
- [疯狂 / j_madness](#j-madness)
- [方形小丑 / j_square](#j-square)
- [通灵 / j_seance](#j-seance)
- [乌合之众 / j_riff_raff](#j-riff-raff)
- [吸血鬼 / j_vampire](#j-vampire)
- [捷径 / j_shortcut](#j-shortcut)
- [全息影像 / j_hologram](#j-hologram)
- [流浪者 / j_vagabond](#j-vagabond)
- [男爵 / j_baron](#j-baron)
- [9 霄云外 / j_cloud_9](#j-cloud-9)
- [火箭 / j_rocket](#j-rocket)
- [方尖石塔 / j_obelisk](#j-obelisk)
- [迈达斯面具 / j_midas_mask](#j-midas-mask)
- [摔跤手 / j_luchador](#j-luchador)
- [照片 / j_photograph](#j-photograph)
- [礼品卡 / j_gift](#j-gift)
- [黑龟豆 / j_turtle_bean](#j-turtle-bean)
- [侵蚀 / j_erosion](#j-erosion)
- [私人车位 / j_reserved_parking](#j-reserved-parking)
- [邮件回扣 / j_mail](#j-mail)
- [冲向月球 / j_to_the_moon](#j-to-the-moon)
- [幻觉 / j_hallucination](#j-hallucination)
- [占卜师 / j_fortune_teller](#j-fortune-teller)
- [杂耍师 / j_juggler](#j-juggler)
- [醉汉 / j_drunkard](#j-drunkard)
- [石头小丑 / j_stone](#j-stone)
- [黄金小丑 / j_golden](#j-golden)
- [招财猫 / j_lucky_cat](#j-lucky-cat)
- [棒球卡 / j_baseball](#j-baseball)
- [斗牛 / j_bull](#j-bull)
- [零糖可乐 / j_diet_cola](#j-diet-cola)
- [交易卡 / j_trading](#j-trading)
- [闪示卡 / j_flash](#j-flash)
- [爆米花 / j_popcorn](#j-popcorn)
- [备用裤子 / j_trousers](#j-trousers)
- [古老小丑 / j_ancient](#j-ancient)
- [拉面 / j_ramen](#j-ramen)
- [对讲机 / j_walkie_talkie](#j-walkie-talkie)
- [苏打水 / j_selzer](#j-selzer)
- [城堡 / j_castle](#j-castle)
- [微笑表情 / j_smiley](#j-smiley)
- [篝火 / j_campfire](#j-campfire)
- [黄金门票 / j_ticket](#j-ticket)
- [骷髅先生 / j_mr_bones](#j-mr-bones)
- [杂技演员 / j_acrobat](#j-acrobat)
- [喜与悲 / j_sock_and_buskin](#j-sock-and-buskin)
- [侠盗 / j_swashbuckler](#j-swashbuckler)
- [游吟诗人 / j_troubadour](#j-troubadour)
- [证书 / j_certificate](#j-certificate)
- [模糊小丑 / j_smeared](#j-smeared)
- [回溯 / j_throwback](#j-throwback)
- [未断选票 / j_hanging_chad](#j-hanging-chad)
- [璞玉 / j_rough_gem](#j-rough-gem)
- [血石 / j_bloodstone](#j-bloodstone)
- [箭头 / j_arrowhead](#j-arrowhead)
- [缟玛瑙 / j_onyx_agate](#j-onyx-agate)
- [玻璃小丑 / j_glass](#j-glass)
- [马戏团长 / j_ring_master](#j-ring-master)
- [花盆 / j_flower_pot](#j-flower-pot)
- [蓝图 / j_blueprint](#j-blueprint)
- [小小丑 / j_wee](#j-wee)
- [快乐安迪 / j_merry_andy](#j-merry-andy)
- [六六大顺 / j_oops](#j-oops)
- [偶像 / j_idol](#j-idol)
- [重影 / j_seeing_double](#j-seeing-double)
- [斗牛士 / j_matador](#j-matador)
- [上路吧杰克 / j_hit_the_road](#j-hit-the-road)
- [二重奏 / j_duo](#j-duo)
- [三重奏 / j_trio](#j-trio)
- [一家人 / j_family](#j-family)
- [秩序 / j_order](#j-order)
- [部落 / j_tribe](#j-tribe)
- [特技演员 / j_stuntman](#j-stuntman)
- [隐形小丑 / j_invisible](#j-invisible)
- [头脑风暴 / j_brainstorm](#j-brainstorm)
- [卫星 / j_satellite](#j-satellite)
- [射月 / j_shoot_the_moon](#j-shoot-the-moon)
- [驾驶执照 / j_drivers_license](#j-drivers-license)
- [卡牌术士 / j_cartomancer](#j-cartomancer)
- [天文学家 / j_astronomer](#j-astronomer)
- [烧焦小丑 / j_burnt](#j-burnt)
- [提靴带 / j_bootstraps](#j-bootstraps)
- [卡尼奥 / j_caino](#j-caino)
- [特里布莱 / j_triboulet](#j-triboulet)
- [约里克 / j_yorick](#j-yorick)
- [希科 / j_chicot](#j-chicot)
- [帕奇欧 / j_perkeo](#j-perkeo)

## 完整条目

<a id="j-joker"></a>

### 1. 小丑 / Joker

- ID: `j_joker`.
- 基价: $2.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: +4 倍率
- 原型参数: `{"mult":4}`.
- 来源: [原型:368](<../../../game/game.lua#L368>).

<a id="j-greedy-joker"></a>

### 2. 贪婪小丑 / Greedy Joker

- ID: `j_greedy_joker`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的 / 方片花色牌 / 在计分时给予+3 倍率
- 原型参数: `{"extra":{"s_mult":3,"suit":"Diamonds"}}`.
- 来源: [原型:369](<../../../game/game.lua#L369>).

<a id="j-lusty-joker"></a>

### 3. 色欲小丑 / Lusty Joker

- ID: `j_lusty_joker`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的 / 红桃花色牌 / 在计分时给予+3 倍率
- 原型参数: `{"extra":{"s_mult":3,"suit":"Hearts"}}`.
- 来源: [原型:370](<../../../game/game.lua#L370>).

<a id="j-wrathful-joker"></a>

### 4. 愤怒小丑 / Wrathful Joker

- ID: `j_wrathful_joker`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的 / 黑桃花色牌 / 在计分时给予+3 倍率
- 原型参数: `{"extra":{"s_mult":3,"suit":"Spades"}}`.
- 来源: [原型:371](<../../../game/game.lua#L371>).

<a id="j-gluttenous-joker"></a>

### 5. 暴食小丑 / Gluttonous Joker

- ID: `j_gluttenous_joker`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的 / 梅花花色牌 / 在计分时给予+3 倍率
- 原型参数: `{"extra":{"s_mult":3,"suit":"Clubs"}}`.
- 来源: [原型:372](<../../../game/game.lua#L372>).

<a id="j-jolly"></a>

### 6. 开心小丑 / Jolly Joker

- ID: `j_jolly`.
- 基价: $3.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含对子 / +8 倍率
- 原型参数: `{"t_mult":8,"type":"Pair"}`.
- 来源: [原型:373](<../../../game/game.lua#L373>).

<a id="j-zany"></a>

### 7. 古怪小丑 / Zany Joker

- ID: `j_zany`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含三条 / +12 倍率
- 原型参数: `{"t_mult":12,"type":"Three of a Kind"}`.
- 来源: [原型:374](<../../../game/game.lua#L374>).

<a id="j-mad"></a>

### 8. 疯狂小丑 / Mad Joker

- ID: `j_mad`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含两对 / +10 倍率
- 原型参数: `{"t_mult":10,"type":"Two Pair"}`.
- 来源: [原型:375](<../../../game/game.lua#L375>).

<a id="j-crazy"></a>

### 9. 狂野小丑 / Crazy Joker

- ID: `j_crazy`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含顺子 / +12 倍率
- 原型参数: `{"t_mult":12,"type":"Straight"}`.
- 来源: [原型:376](<../../../game/game.lua#L376>).

<a id="j-droll"></a>

### 10. 滑稽小丑 / Droll Joker

- ID: `j_droll`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含同花 / +10 倍率
- 原型参数: `{"t_mult":10,"type":"Flush"}`.
- 来源: [原型:377](<../../../game/game.lua#L377>).

<a id="j-sly"></a>

### 11. 奸诈小丑 / Sly Joker

- ID: `j_sly`.
- 基价: $3.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含对子 / +50 筹码
- 原型参数: `{"t_chips":50,"type":"Pair"}`.
- 来源: [原型:378](<../../../game/game.lua#L378>).

<a id="j-wily"></a>

### 12. 狡猾小丑 / Wily Joker

- ID: `j_wily`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含三条 / +100 筹码
- 原型参数: `{"t_chips":100,"type":"Three of a Kind"}`.
- 来源: [原型:379](<../../../game/game.lua#L379>).

<a id="j-clever"></a>

### 13. 聪敏小丑 / Clever Joker

- ID: `j_clever`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含两对 / +80 筹码
- 原型参数: `{"t_chips":80,"type":"Two Pair"}`.
- 来源: [原型:380](<../../../game/game.lua#L380>).

<a id="j-devious"></a>

### 14. 阴险小丑 / Devious Joker

- ID: `j_devious`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含顺子 / +100 筹码
- 原型参数: `{"t_chips":100,"type":"Straight"}`.
- 来源: [原型:381](<../../../game/game.lua#L381>).

<a id="j-crafty"></a>

### 15. 精明小丑 / Crafty Joker

- ID: `j_crafty`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中 / 包含同花 / +80 筹码
- 原型参数: `{"t_chips":80,"type":"Flush"}`.
- 来源: [原型:382](<../../../game/game.lua#L382>).

<a id="j-half"></a>

### 16. 半张小丑 / Half Joker

- ID: `j_half`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌 / 少于等于 3 张 / +20 倍率
- 原型参数: `{"extra":{"mult":20,"size":3}}`.
- 来源: [原型:384](<../../../game/game.lua#L384>).

<a id="j-stencil"></a>

### 17. 模具小丑 / Joker Stencil

- ID: `j_stencil`.
- 基价: $8.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每个空的小丑牌槽位 / 获得 X1 倍率 / 模具小丑算作空位 / (当前为 X[空槽数加模板张数] )
- 来源: [原型:385](<../../../game/game.lua#L385>).

<a id="j-four-fingers"></a>

### 18. 四指 / Four Fingers

- ID: `j_four_fingers`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 所有同花和 / 顺子都可以 / 由 4 张牌组成
- 来源: [原型:386](<../../../game/game.lua#L386>).

<a id="j-mime"></a>

### 19. 哑剧演员 / Mime

- ID: `j_mime`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 重新触发所有 / 留在手牌中的 / 牌的能力
- 原型参数: `{"extra":1}`.
- 来源: [原型:387](<../../../game/game.lua#L387>).

<a id="j-credit-card"></a>

### 20. 信用卡 / Credit Card

- ID: `j_credit_card`.
- 基价: $1.
- 稀有度: 普通 Common.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 可以负债 / 最多-$20
- 原型参数: `{"extra":20}`.
- 来源: [原型:388](<../../../game/game.lua#L388>).

<a id="j-ceremonial"></a>

### 21. 仪式匕首 / Ceremonial Dagger

- ID: `j_ceremonial`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 在选择盲注时 / 摧毁右侧的小丑牌 / 并将其售价的两倍 / 永久添加至这张牌的倍率 / (当前为+[当前倍率]倍)
- 原型参数: `{"mult":0}`.
- 来源: [原型:389](<../../../game/game.lua#L389>).

<a id="j-banner"></a>

### 22. 旗帜 / Banner

- ID: `j_banner`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每一个剩余的 / 弃牌次数 / +30 筹码
- 原型参数: `{"extra":30}`.
- 来源: [原型:390](<../../../game/game.lua#L390>).

<a id="j-mystic-summit"></a>

### 23. 神秘之峰 / Mystic Summit

- ID: `j_mystic_summit`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 当剩余 0 次 / 弃牌次数 / +15 倍率
- 原型参数: `{"extra":{"d_remaining":0,"mult":15}}`.
- 来源: [原型:391](<../../../game/game.lua#L391>).

<a id="j-marble"></a>

### 24. 大理石小丑 / Marble Joker

- ID: `j_marble`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 选择盲注后 / 牌组中会添加 / 一张石头牌
- 原型参数: `{"extra":1}`.
- 来源: [原型:392](<../../../game/game.lua#L392>).

<a id="j-loyalty-card"></a>

### 25. 积分卡 / Loyalty Card

- ID: `j_loyalty_card`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每第 6 次出牌时 / 给予 X4 倍率 / ([距下次激活的倒计数])
- 原型参数: `{"extra":{"Xmult":4,"every":5,"remaining":"5 remaining"}}`.
- 来源: [原型:393](<../../../game/game.lua#L393>).

<a id="j-8-ball"></a>

### 26. 八号球 / 8 Ball

- ID: `j_8_ball`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的每一张 8 / 有[概率倍率 normal, 默认 1]/4 几率在计分时 / 生成一张塔罗牌 / (必须有空位)
- 原型参数: `{"extra":4}`.
- 来源: [原型:394](<../../../game/game.lua#L394>).

<a id="j-misprint"></a>

### 27. 印错小丑 / Misprint

- ID: `j_misprint`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: +0 至 +23 倍率, 每次出牌随机取值.
- 原型参数: `{"extra":{"max":23,"min":0}}`.
- 来源: [原型:395](<../../../game/game.lua#L395>).

<a id="j-dusk"></a>

### 28. 黄昏 / Dusk

- ID: `j_dusk`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每回合的 / 最后一次出牌时 / 所有打出的牌会被触发两次
- 解锁条件原型: `{"extra":"","hidden":true,"type":""}`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:396](<../../../game/game.lua#L396>).

<a id="j-raised-fist"></a>

### 29. 致胜之拳 / Raised Fist

- ID: `j_raised_fist`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 将留在手牌中点数最小牌 / 点数的两倍 / 加到倍率上
- 来源: [原型:397](<../../../game/game.lua#L397>).

<a id="j-chaos"></a>

### 30. 混沌小丑 / Chaos the Clown

- ID: `j_chaos`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每次商店 / 1 次免费重掷
- 原型参数: `{"extra":1}`.
- 来源: [原型:398](<../../../game/game.lua#L398>).

<a id="j-fibonacci"></a>

### 31. 斐波那契 / Fibonacci

- ID: `j_fibonacci`.
- 基价: $8.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的每一张 / A,2,3,5,8 / 在计分时给予+8 倍率
- 原型参数: `{"extra":8}`.
- 来源: [原型:400](<../../../game/game.lua#L400>).

<a id="j-steel-joker"></a>

### 32. 钢铁小丑 / Steel Joker

- ID: `j_steel_joker`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 完整牌组内每有一张 / 钢铁牌 / 给予 X0.2 倍率 / (当前为 X[当前乘倍率]倍率)
- 入池增强门槛: `m_steel`.
- 原型参数: `{"extra":0.2}`.
- 来源: [原型:401](<../../../game/game.lua#L401>).

<a id="j-scary-face"></a>

### 33. 恐怖面孔 / Scary Face

- ID: `j_scary_face`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的人头牌 / 在计分时 / 给予+30 筹码
- 原型参数: `{"extra":30}`.
- 来源: [原型:402](<../../../game/game.lua#L402>).

<a id="j-abstract"></a>

### 34. 抽象小丑 / Abstract Joker

- ID: `j_abstract`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每有一张小丑牌 / +3 倍率 / (当前为+[当前小丑张数乘 3]倍率)
- 原型参数: `{"extra":3}`.
- 来源: [原型:403](<../../../game/game.lua#L403>).

<a id="j-delayed-grat"></a>

### 35. 延迟满足 / Delayed Gratification

- ID: `j_delayed_grat`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果在回合结束时 / 没有使用弃牌,则每把弃牌 / 获得 $2
- 原型参数: `{"extra":2}`.
- 来源: [原型:404](<../../../game/game.lua#L404>).

<a id="j-hack"></a>

### 36. 烂脱口秀演员 / Hack

- ID: `j_hack`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 重新触发 / 所有打出的 / 2,3,4 和 5
- 原型参数: `{"extra":1}`.
- 来源: [原型:405](<../../../game/game.lua#L405>).

<a id="j-pareidolia"></a>

### 37. 幻视 / Pareidolia

- ID: `j_pareidolia`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 所有卡牌 / 均视为 / 人头牌
- 来源: [原型:406](<../../../game/game.lua#L406>).

<a id="j-gros-michel"></a>

### 38. 大麦克香蕉 / Gros Michel

- ID: `j_gros_michel`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: +15 倍率 / 回合结束时 / 有[概率倍率 normal, 默认 1]/6 的几率 / 摧毁此牌
- 排除标记: `gros_michel_extinct`.
- 原型参数: `{"extra":{"mult":15,"odds":6}}`.
- 来源: [原型:407](<../../../game/game.lua#L407>).

<a id="j-even-steven"></a>

### 39. 偶数史蒂文 / Even Steven

- ID: `j_even_steven`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的点数为 / 偶数的牌 / 在计分时给予+4 倍率 / (10,8,6,4,2)
- 原型参数: `{"extra":4}`.
- 来源: [原型:408](<../../../game/game.lua#L408>).

<a id="j-odd-todd"></a>

### 40. 奇数托德 / Odd Todd

- ID: `j_odd_todd`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的点数为 / 奇数的牌 / 在计分时给予+31 筹码 / (A,9,7,5,3)
- 原型参数: `{"extra":31}`.
- 来源: [原型:409](<../../../game/game.lua#L409>).

<a id="j-scholar"></a>

### 41. 学者 / Scholar

- ID: `j_scholar`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的 A 牌 / 在计分时给予 / +4 倍率 / 和+20 筹码
- 原型参数: `{"extra":{"chips":20,"mult":4}}`.
- 来源: [原型:410](<../../../game/game.lua#L410>).

<a id="j-business"></a>

### 42. 名片 / Business Card

- ID: `j_business`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的人头牌在计分时 / 有[概率倍率 normal, 默认 1]/2 的几率 / 获得 $2
- 原型参数: `{"extra":2}`.
- 来源: [原型:411](<../../../game/game.lua#L411>).

<a id="j-supernova"></a>

### 43. 超新星 / Supernova

- ID: `j_supernova`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 将牌型在本赛局内 / 被打出过的次数 / 添加至倍率
- 原型参数: `{"extra":1}`.
- 来源: [原型:412](<../../../game/game.lua#L412>).

<a id="j-ride-the-bus"></a>

### 44. 搭乘巴士 / Ride the Bus

- ID: `j_ride_the_bus`.
- 基价: $6.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 连续打出没有 / 计分人头牌的牌时 / 这张小丑牌获得+1 倍率 / 失败将会重置倍率 / (当前为+[当前倍率]倍率)
- 解锁条件原型: `{"type":"discard_custom"}`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:413](<../../../game/game.lua#L413>).

<a id="j-space"></a>

### 45. 太空小丑 / Space Joker

- ID: `j_space`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 有[概率倍率 normal, 默认 1]/4 的 / 几率升级 / 打出的牌型等级
- 原型参数: `{"extra":4}`.
- 来源: [原型:414](<../../../game/game.lua#L414>).

<a id="j-egg"></a>

### 46. 鸡蛋 / Egg

- ID: `j_egg`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 在回合结束时 / 本卡的出售价值 / 增加 $3
- 原型参数: `{"extra":3}`.
- 来源: [原型:416](<../../../game/game.lua#L416>).

<a id="j-burglar"></a>

### 47. 窃贼 / Burglar

- ID: `j_burglar`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 选择盲注后 / 出牌次数+3,并 / 失去所有弃牌次数
- 原型参数: `{"extra":3}`.
- 来源: [原型:417](<../../../game/game.lua#L417>).

<a id="j-blackboard"></a>

### 48. 黑板 / Blackboard

- ID: `j_blackboard`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果留在手牌中的 / 所有牌都是黑桃或梅花 / 则 X3 倍率
- 原型参数: `{"extra":3}`.
- 来源: [原型:418](<../../../game/game.lua#L418>).

<a id="j-runner"></a>

### 49. 跑步选手 / Runner

- ID: `j_runner`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 如果打出的牌中包含 / 顺子 / 这张小丑获得+15 筹码 / (当前为+[当前筹码, 初始 0]筹码)
- 原型参数: `{"extra":{"chip_mod":15,"chips":0}}`.
- 来源: [原型:419](<../../../game/game.lua#L419>).

<a id="j-ice-cream"></a>

### 50. 冰淇淋 / Ice Cream

- ID: `j_ice_cream`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: +[当前筹码, 初始 100]筹码 / 每次出牌后 / -5 筹码
- 原型参数: `{"extra":{"chip_mod":5,"chips":100}}`.
- 来源: [原型:420](<../../../game/game.lua#L420>).

<a id="j-dna"></a>

### 51. DNA / DNA

- ID: `j_dna`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果回合的第一次出牌 / 只有 1 张牌,则将其 / 永久复制到牌组,并将 / 复制牌放到手牌中
- 来源: [原型:421](<../../../game/game.lua#L421>).

<a id="j-splash"></a>

### 52. 飞溅 / Splash

- ID: `j_splash`.
- 基价: $3.
- 稀有度: 普通 Common.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每张打出的牌 / 都可以计分
- 来源: [原型:422](<../../../game/game.lua#L422>).

<a id="j-blue-joker"></a>

### 53. 蓝色小丑 / Blue Joker

- ID: `j_blue_joker`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每张牌组内剩余 / 的卡牌,+2 筹码 / (当前为+[剩余抽牌堆张数乘 2]筹码)
- 原型参数: `{"extra":2}`.
- 来源: [原型:423](<../../../game/game.lua#L423>).

<a id="j-sixth-sense"></a>

### 54. 第六感 / Sixth Sense

- ID: `j_sixth_sense`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果回合的第一次出牌 / 是一张单独的 6 / 则将其销毁并生成一张幻灵牌 / (必须有空位)
- 来源: [原型:424](<../../../game/game.lua#L424>).

<a id="j-constellation"></a>

### 55. 星座 / Constellation

- ID: `j_constellation`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 每使用一张星球牌 / 这张小丑牌获得 X0.1 倍率 / (当前为 X[当前乘倍率]倍率)
- 原型参数: `{"Xmult":1,"extra":0.1}`.
- 来源: [原型:425](<../../../game/game.lua#L425>).

<a id="j-hiker"></a>

### 56. 徒步者 / Hiker

- ID: `j_hiker`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的每一张牌 / 在计分时 / 会永久获得+5 筹码
- 原型参数: `{"extra":5}`.
- 来源: [原型:426](<../../../game/game.lua#L426>).

<a id="j-faceless"></a>

### 57. 无面小丑 / Faceless Joker

- ID: `j_faceless`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果同时弃掉 / 3 张或更多张 / 人头牌 / 获得 $5
- 原型参数: `{"extra":{"dollars":5,"faces":3}}`.
- 来源: [原型:427](<../../../game/game.lua#L427>).

<a id="j-green-joker"></a>

### 58. 绿色小丑 / Green Joker

- ID: `j_green_joker`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 每次出牌,这张小丑牌+1 倍率 / 每次弃牌,这张小丑牌-1 倍率 / (当前为+[当前倍率]倍)
- 原型参数: `{"extra":{"discard_sub":1,"hand_add":1}}`.
- 来源: [原型:428](<../../../game/game.lua#L428>).

<a id="j-superposition"></a>

### 59. 叠加态 / Superposition

- ID: `j_superposition`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌中包含 / 一张 A 和一个顺子 / 生成一张塔罗牌 / (必须有空位)
- 来源: [原型:429](<../../../game/game.lua#L429>).

<a id="j-todo-list"></a>

### 60. 待办清单 / To Do List

- ID: `j_todo_list`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果出牌牌型为[本回合目标牌型] / 获得 $4 / 每回合结束时 / 牌型都会改变
- 原型参数: `{"extra":{"dollars":4,"poker_hand":"High Card"}}`.
- 来源: [原型:430](<../../../game/game.lua#L430>).

<a id="j-cavendish"></a>

### 61. 卡文迪什 / Cavendish

- ID: `j_cavendish`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: X3 倍率 / 回合结束时 / 有[概率倍率 normal, 默认 1]/1000 的几率 / 摧毁此牌
- 入池要求标记: `gros_michel_extinct`.
- 原型参数: `{"extra":{"Xmult":3,"odds":1000}}`.
- 来源: [原型:432](<../../../game/game.lua#L432>).

<a id="j-card-sharp"></a>

### 62. 老千小丑 / Card Sharp

- ID: `j_card_sharp`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果打出的牌型已经 / 在本回合打出过 / 则 X3 倍率
- 原型参数: `{"extra":{"Xmult":3}}`.
- 来源: [原型:433](<../../../game/game.lua#L433>).

<a id="j-red-card"></a>

### 63. 红牌 / Red Card

- ID: `j_red_card`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 当跳过任一补充包时 / 这张小丑牌获得+3 倍率 / (当前为+[当前倍率]倍率)
- 原型参数: `{"extra":3}`.
- 来源: [原型:434](<../../../game/game.lua#L434>).

<a id="j-madness"></a>

### 64. 疯狂 / Madness

- ID: `j_madness`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 在小盲注或大盲注被选中时 / 这张小丑牌获得 X0.5 倍率 / 然后随机摧毁一张小丑牌 / (当前为 X[当前乘倍率]倍率)
- 原型参数: `{"extra":0.5}`.
- 来源: [原型:435](<../../../game/game.lua#L435>).

<a id="j-square"></a>

### 65. 方形小丑 / Square Joker

- ID: `j_square`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 如果打出的牌 / 正好是 4 张牌 / 这张小丑牌获得+4 筹码 / (当前为+[当前筹码]筹码)
- 原型参数: `{"extra":{"chip_mod":4,"chips":0}}`.
- 来源: [原型:436](<../../../game/game.lua#L436>).

<a id="j-seance"></a>

### 66. 通灵 / Séance

- ID: `j_seance`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果牌型为 / 同花顺,随机生成 / 一张幻灵牌 / (必须有空位)
- 原型参数: `{"extra":{"poker_hand":"Straight Flush"}}`.
- 来源: [原型:437](<../../../game/game.lua#L437>).

<a id="j-riff-raff"></a>

### 67. 乌合之众 / Riff-Raff

- ID: `j_riff_raff`.
- 基价: $6.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 在选择盲注时 / 生成 2 张普通小丑牌 / (必须有空间)
- 原型参数: `{"extra":2}`.
- 来源: [原型:438](<../../../game/game.lua#L438>).

<a id="j-vampire"></a>

### 68. 吸血鬼 / Vampire

- ID: `j_vampire`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 每打出一张计分的增强卡牌 / 这张小丑牌获得 X0.1 倍率 / 并移除卡牌的增强效果 / (当前为 X[当前乘倍率]倍率)
- 原型参数: `{"Xmult":1,"extra":0.1}`.
- 来源: [原型:439](<../../../game/game.lua#L439>).

<a id="j-shortcut"></a>

### 69. 捷径 / Shortcut

- ID: `j_shortcut`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 让顺子可以 / 相隔 1 个点数组成 / (例如:10 8 6 5 3)
- 来源: [原型:440](<../../../game/game.lua#L440>).

<a id="j-hologram"></a>

### 70. 全息影像 / Hologram

- ID: `j_hologram`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 每添加一张卡牌 / 到你的牌组中, / 这张小丑牌获得 X0.25 倍率 / (当前为 X[当前乘倍率]倍率)
- 原型参数: `{"Xmult":1,"extra":0.25}`.
- 来源: [原型:441](<../../../game/game.lua#L441>).

<a id="j-vagabond"></a>

### 71. 流浪者 / Vagabond

- ID: `j_vagabond`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果在出牌时 / 资金少于等于 $4 / 则获得一张塔罗牌
- 原型参数: `{"extra":4}`.
- 来源: [原型:442](<../../../game/game.lua#L442>).

<a id="j-baron"></a>

### 72. 男爵 / Baron

- ID: `j_baron`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 留在手牌中的 / 每一张 K / 会给予 X1.5 倍率
- 原型参数: `{"extra":1.5}`.
- 来源: [原型:443](<../../../game/game.lua#L443>).

<a id="j-cloud-9"></a>

### 73. 9 霄云外 / Cloud 9

- ID: `j_cloud_9`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每个回合结束时 / 你完整牌组内的每张 9 / 使你获得 $1 / (当前 $[完整牌组中 9 的张数])
- 原型参数: `{"extra":1}`.
- 来源: [原型:444](<../../../game/game.lua#L444>).

<a id="j-rocket"></a>

### 74. 火箭 / Rocket

- ID: `j_rocket`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 每个回合结束时你获得 $[当前收入, 初始 1] / 击败 Boss 盲注 / 会使这一金额增加 $2
- 原型参数: `{"extra":{"dollars":1,"increase":2}}`.
- 来源: [原型:445](<../../../game/game.lua#L445>).

<a id="j-obelisk"></a>

### 75. 方尖石塔 / Obelisk

- ID: `j_obelisk`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 连续打出不是你 / 最常用的牌型时 / 这张小丑牌获得 X0.2 倍率 / 失败将会重置倍率 / (当前为 X[当前乘倍率]倍率)
- 原型参数: `{"Xmult":1,"extra":0.2}`.
- 来源: [原型:446](<../../../game/game.lua#L446>).

<a id="j-midas-mask"></a>

### 76. 迈达斯面具 / Midas Mask

- ID: `j_midas_mask`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的所有人头牌 / 在计分时 / 变为黄金牌
- 来源: [原型:448](<../../../game/game.lua#L448>).

<a id="j-luchador"></a>

### 77. 摔跤手 / Luchador

- ID: `j_luchador`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: 售出这张小丑牌 / 会消除当前回合中 / Boss 盲注的限制条件
- 来源: [原型:449](<../../../game/game.lua#L449>).

<a id="j-photograph"></a>

### 78. 照片 / Photograph

- ID: `j_photograph`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的第一张人头牌 / 在计分时 / 会给予 X2 倍率
- 原型参数: `{"extra":2}`.
- 来源: [原型:450](<../../../game/game.lua#L450>).

<a id="j-gift"></a>

### 79. 礼品卡 / Gift Card

- ID: `j_gift`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 在每回合结束时 / 使拥有的每张小丑牌 / 和消耗牌 / 售价增加 $1
- 原型参数: `{"extra":1}`.
- 来源: [原型:451](<../../../game/game.lua#L451>).

<a id="j-turtle-bean"></a>

### 80. 黑龟豆 / Turtle Bean

- ID: `j_turtle_bean`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: 手牌上限+[当前手牌加成, 初始 5] / 每回合结束时减 1
- 原型参数: `{"extra":{"h_mod":1,"h_size":5}}`.
- 来源: [原型:452](<../../../game/game.lua#L452>).

<a id="j-erosion"></a>

### 81. 侵蚀 / Erosion

- ID: `j_erosion`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 在你的牌组中 / 每比完整的[本局初始牌组张数]张牌少一张 / 就获得+4 倍率 / (当前为+[当前倍率]倍率)
- 原型参数: `{"extra":4}`.
- 来源: [原型:453](<../../../game/game.lua#L453>).

<a id="j-reserved-parking"></a>

### 82. 私人车位 / Reserved Parking

- ID: `j_reserved_parking`.
- 基价: $6.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 留在手牌中的 / 每一张人头牌 / 有[概率倍率 normal, 默认 1]/2 几率 / 给予 $1
- 原型参数: `{"extra":{"dollars":1,"odds":2}}`.
- 来源: [原型:454](<../../../game/game.lua#L454>).

<a id="j-mail"></a>

### 83. 邮件回扣 / Mail-In Rebate

- ID: `j_mail`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每弃掉一张[本回合目标点数] / 即可获得 $5 / 每个回合点数都会变
- 原型参数: `{"extra":5}`.
- 来源: [原型:455](<../../../game/game.lua#L455>).

<a id="j-to-the-moon"></a>

### 84. 冲向月球 / To the Moon

- ID: `j_to_the_moon`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 回合结束时 / 每拥有 $5 / 可以额外获得 $1 的利息
- 原型参数: `{"extra":1}`.
- 来源: [原型:456](<../../../game/game.lua#L456>).

<a id="j-hallucination"></a>

### 85. 幻觉 / Hallucination

- ID: `j_hallucination`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打开任一补充包时 / 有[概率倍率 normal, 默认 1]/2 几率 / 生成一张塔罗牌 / (必须有空位)
- 原型参数: `{"extra":2}`.
- 来源: [原型:457](<../../../game/game.lua#L457>).

<a id="j-fortune-teller"></a>

### 86. 占卜师 / Fortune Teller

- ID: `j_fortune_teller`.
- 基价: $6.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 本赛局内每使用过一张塔罗牌 / 这张小丑获得+1 倍率 / (当前为+[已使用塔罗牌总数])
- 原型参数: `{"extra":1}`.
- 来源: [原型:458](<../../../game/game.lua#L458>).

<a id="j-juggler"></a>

### 87. 杂耍师 / Juggler

- ID: `j_juggler`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 手牌上限+1
- 原型参数: `{"h_size":1}`.
- 来源: [原型:459](<../../../game/game.lua#L459>).

<a id="j-drunkard"></a>

### 88. 醉汉 / Drunkard

- ID: `j_drunkard`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每回合 / 弃牌次数+1
- 原型参数: `{"d_size":1}`.
- 来源: [原型:460](<../../../game/game.lua#L460>).

<a id="j-stone"></a>

### 89. 石头小丑 / Stone Joker

- ID: `j_stone`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 完整牌组内每有一张 / 石头牌 / +25 筹码 / (当前为+[当前筹码]筹码)
- 入池增强门槛: `m_stone`.
- 原型参数: `{"extra":25}`.
- 来源: [原型:461](<../../../game/game.lua#L461>).

<a id="j-golden"></a>

### 90. 黄金小丑 / Golden Joker

- ID: `j_golden`.
- 基价: $6.
- 稀有度: 普通 Common.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 在回合结束时 / 获得 $4
- 原型参数: `{"extra":4}`.
- 来源: [原型:462](<../../../game/game.lua#L462>).

<a id="j-lucky-cat"></a>

### 91. 招财猫 / Lucky Cat

- ID: `j_lucky_cat`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 每次成功触发 / 一张幸运牌时 / 这张小丑牌获得 X0.25 倍率 / (当前为 X[当前乘倍率]倍率)
- 入池增强门槛: `m_lucky`.
- 原型参数: `{"Xmult":1,"extra":0.25}`.
- 来源: [原型:464](<../../../game/game.lua#L464>).

<a id="j-baseball"></a>

### 92. 棒球卡 / Baseball Card

- ID: `j_baseball`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每张罕见小丑牌 / 会给予 X1.5 倍率
- 原型参数: `{"extra":1.5}`.
- 来源: [原型:465](<../../../game/game.lua#L465>).

<a id="j-bull"></a>

### 93. 斗牛 / Bull

- ID: `j_bull`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每拥有 $1 / +2 筹码 / (当前为+[非负金钱乘 2]筹码)
- 原型参数: `{"extra":2}`.
- 来源: [原型:466](<../../../game/game.lua#L466>).

<a id="j-diet-cola"></a>

### 94. 零糖可乐 / Diet Cola

- ID: `j_diet_cola`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: 售出这牌就可以 / 创建一个免费的 / 双倍标签
- 来源: [原型:467](<../../../game/game.lua#L467>).

<a id="j-trading"></a>

### 95. 交易卡 / Trading Card

- ID: `j_trading`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 如果每回合的第一次弃牌 / 只有 1 张牌,则将其 / 摧毁并获得 $3
- 原型参数: `{"extra":3}`.
- 来源: [原型:468](<../../../game/game.lua#L468>).

<a id="j-flash"></a>

### 96. 闪示卡 / Flash Card

- ID: `j_flash`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 在商店中每重掷一次 / 这张小丑牌获得+2 倍率 / (当前为+[当前倍率]倍率)
- 原型参数: `{"extra":2,"mult":0}`.
- 来源: [原型:469](<../../../game/game.lua#L469>).

<a id="j-popcorn"></a>

### 97. 爆米花 / Popcorn

- ID: `j_popcorn`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: +[当前倍率, 初始 20]倍率 / 每回合结束时 / -4 倍率
- 原型参数: `{"extra":4,"mult":20}`.
- 来源: [原型:470](<../../../game/game.lua#L470>).

<a id="j-trousers"></a>

### 98. 备用裤子 / Spare Trousers

- ID: `j_trousers`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 如果打出的牌中包含 / 两对 / 则这张小丑牌获得+2 倍率 / (当前为+[当前倍率]倍率)
- 原型参数: `{"extra":2}`.
- 来源: [原型:471](<../../../game/game.lua#L471>).

<a id="j-ancient"></a>

### 99. 古老小丑 / Ancient Joker

- ID: `j_ancient`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的[本回合目标花色]牌 / 在计分时 / 会给予 X1.5 倍率 / 回合结束时改变需求花色
- 原型参数: `{"extra":1.5}`.
- 来源: [原型:472](<../../../game/game.lua#L472>).

<a id="j-ramen"></a>

### 100. 拉面 / Ramen

- ID: `j_ramen`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: X[当前乘倍率, 初始 2]倍率 / 每弃掉一张牌 / 失去 X0.01 倍率
- 原型参数: `{"Xmult":2,"extra":0.01}`.
- 来源: [原型:473](<../../../game/game.lua#L473>).

<a id="j-walkie-talkie"></a>

### 101. 对讲机 / Walkie Talkie

- ID: `j_walkie_talkie`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的每张 10 和 4 / 在计分时获得+10 筹码 / 以及+4 倍率
- 原型参数: `{"extra":{"chips":10,"mult":4}}`.
- 来源: [原型:474](<../../../game/game.lua#L474>).

<a id="j-selzer"></a>

### 102. 苏打水 / Seltzer

- ID: `j_selzer`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: false; 可易腐: true.
- 新档初始解锁: true.
- 效果: 在接下来的[剩余有效出牌次数, 初始 10]次出牌中 / 重新触发所有 / 打出的卡牌
- 原型参数: `{"extra":10}`.
- 来源: [原型:475](<../../../game/game.lua#L475>).

<a id="j-castle"></a>

### 103. 城堡 / Castle

- ID: `j_castle`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: true.
- 效果: 每弃掉一张[本回合目标花色]牌 / 这张小丑牌获得+3 筹码 / 每个回合花色都会变 / (当前为+[当前筹码]筹码)
- 原型参数: `{"extra":{"chip_mod":3,"chips":0}}`.
- 来源: [原型:476](<../../../game/game.lua#L476>).

<a id="j-smiley"></a>

### 104. 微笑表情 / Smiley Face

- ID: `j_smiley`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 打出的人头牌 / 在计分时 / 给予+5 倍率
- 原型参数: `{"extra":5}`.
- 来源: [原型:477](<../../../game/game.lua#L477>).

<a id="j-campfire"></a>

### 105. 篝火 / Campfire

- ID: `j_campfire`.
- 基价: $9.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: true.
- 效果: 每售出一张牌 / 这张小丑牌获得 X0.25 倍率 / Boss 盲注被击败时重置倍率 / (当前为 X[当前乘倍率]倍率)
- 原型参数: `{"extra":0.25}`.
- 来源: [原型:478](<../../../game/game.lua#L478>).

<a id="j-ticket"></a>

### 106. 黄金门票 / Golden Ticket

- ID: `j_ticket`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 打出的黃金牌 / 在计分时获得 $4
- 解锁说明: 打出一手五张 / 只包含 / 黃金牌的牌
- 解锁条件原型: `{"extra":"Gold","type":"hand_contents"}`.
- 入池增强门槛: `m_gold`.
- 原型参数: `{"extra":4}`.
- 来源: [原型:480](<../../../game/game.lua#L480>).

<a id="j-mr-bones"></a>

### 107. 骷髅先生 / Mr. Bones

- ID: `j_mr_bones`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: false; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果最终得到的 / 筹码至少是 / 所需筹码的 25% / 则不会死亡 / 自毁
- 解锁说明: 输掉 5 局游戏 / ([当前存档累计值])
- 解锁条件原型: `{"extra":5,"type":"c_losses"}`.
- 来源: [原型:481](<../../../game/game.lua#L481>).

<a id="j-acrobat"></a>

### 108. 杂技演员 / Acrobat

- ID: `j_acrobat`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 每回合的最后一次 / 出牌时, X3 倍率
- 解锁说明: 打出 200 次牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":200,"type":"c_hands_played"}`.
- 原型参数: `{"extra":3}`.
- 来源: [原型:482](<../../../game/game.lua#L482>).

<a id="j-sock-and-buskin"></a>

### 109. 喜与悲 / Sock and Buskin

- ID: `j_sock_and_buskin`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 重新触发所有 / 打出的人头牌
- 解锁说明: 打出总共 / 300 张人头牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":300,"type":"c_face_cards_played"}`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:483](<../../../game/game.lua#L483>).

<a id="j-swashbuckler"></a>

### 110. 侠盗 / Swashbuckler

- ID: `j_swashbuckler`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 将拥有的所有其他 / 小丑牌的总售价 / 添加至倍率 / (当前为+[其他小丑售价总和]倍率)
- 解锁说明: 总共卖出 / 20 张小丑牌 / ([当前存档累计值])张
- 解锁条件原型: `{"extra":20,"type":"c_jokers_sold"}`.
- 原型参数: `{"mult":1}`.
- 来源: [原型:484](<../../../game/game.lua#L484>).

<a id="j-troubadour"></a>

### 111. 游吟诗人 / Troubadour

- ID: `j_troubadour`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: +2 手牌上限 / 每回合出牌次数-1
- 解锁说明: 连续赢得 5 回合 / 且每回合只使用 / 一次出牌次数
- 解锁条件原型: `{"extra":5,"type":"round_win"}`.
- 原型参数: `{"extra":{"h_plays":-1,"h_size":2}}`.
- 来源: [原型:485](<../../../game/game.lua#L485>).

<a id="j-certificate"></a>

### 112. 证书 / Certificate

- ID: `j_certificate`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 回合开始时 / 随机添加一张 / 带随机蜡封的牌 / 到手牌中
- 解锁说明: 拥有一张 / 带金色蜡封的 / 黄金牌
- 解锁条件原型: `{"type":"double_gold"}`.
- 来源: [原型:486](<../../../game/game.lua#L486>).

<a id="j-smeared"></a>

### 113. 模糊小丑 / Smeared Joker

- ID: `j_smeared`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 红桃和方片 / 视作同一花色, / 黑桃和梅花 / 也视作同一花色
- 解锁说明: 在你的牌组中 / 至少拥有 3 / 万能牌
- 解锁条件原型: `{"extra":{"count":3,"e_key":"m_wild","enhancement":"Wild Card"},"type":"modify_deck"}`.
- 来源: [原型:487](<../../../game/game.lua#L487>).

<a id="j-throwback"></a>

### 114. 回溯 / Throwback

- ID: `j_throwback`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 本赛局内每跳过一次 / 盲注,获得 X0.25 倍率 / (当前为 X[当前乘倍率] 倍率)
- 解锁说明: 从主菜单中选择继续 / 游玩已保存的局
- 解锁条件原型: `{"type":"continue_game"}`.
- 原型参数: `{"extra":0.25}`.
- 来源: [原型:488](<../../../game/game.lua#L488>).

<a id="j-hanging-chad"></a>

### 115. 未断选票 / Hanging Chad

- ID: `j_hanging_chad`.
- 基价: $4.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 打出的牌中 / 第一张计分牌 / 额外触发 2 次
- 解锁说明: 用高牌 / 打赢 Boss 盲注
- 解锁条件原型: `{"extra":"High Card","type":"round_win"}`.
- 原型参数: `{"extra":2}`.
- 来源: [原型:489](<../../../game/game.lua#L489>).

<a id="j-rough-gem"></a>

### 116. 璞玉 / Rough Gem

- ID: `j_rough_gem`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 打出的 / 方块花色牌 / 在计分时给予 $1
- 解锁说明: 在你的牌组中 / 拥有至少 30 张 / 带有方片花色的卡牌
- 解锁条件原型: `{"extra":{"count":30,"suit":"Diamonds"},"type":"modify_deck"}`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:490](<../../../game/game.lua#L490>).

<a id="j-bloodstone"></a>

### 117. 血石 / Bloodstone

- ID: `j_bloodstone`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 打出的 / 红桃花色牌 / 在计分时有[概率倍率 normal, 默认 1]/2 几率 / 给予 X1.5 倍率
- 解锁说明: 在你的牌组中 / 拥有至少 30 张 / 带有红桃花色的卡牌
- 解锁条件原型: `{"extra":{"count":30,"suit":"Hearts"},"type":"modify_deck"}`.
- 原型参数: `{"extra":{"Xmult":1.5,"odds":2}}`.
- 来源: [原型:491](<../../../game/game.lua#L491>).

<a id="j-arrowhead"></a>

### 118. 箭头 / Arrowhead

- ID: `j_arrowhead`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 打出的 / 黑桃花色牌 / 在计分时给予+50 筹码
- 解锁说明: 在你的牌组中 / 拥有至少 30 张 / 带有黑桃花色的卡牌
- 解锁条件原型: `{"extra":{"count":30,"suit":"Spades"},"type":"modify_deck"}`.
- 原型参数: `{"extra":50}`.
- 来源: [原型:492](<../../../game/game.lua#L492>).

<a id="j-onyx-agate"></a>

### 119. 缟玛瑙 / Onyx Agate

- ID: `j_onyx_agate`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 打出的 / 梅花花色牌 / 在计分时给予+7 倍率
- 解锁说明: 在你的牌组中 / 拥有至少 30 张 / 带有梅花花色的卡牌
- 解锁条件原型: `{"extra":{"count":30,"suit":"Clubs"},"type":"modify_deck"}`.
- 原型参数: `{"extra":7}`.
- 来源: [原型:493](<../../../game/game.lua#L493>).

<a id="j-glass"></a>

### 120. 玻璃小丑 / Glass Joker

- ID: `j_glass`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: false.
- 效果: 每摧毁一张 / 玻璃牌 / 这张小丑获得 X0.75 倍率 / (当前为 X[当前乘倍率]倍率)
- 解锁说明: 在你的牌组中 / 拥有 5 张 / 玻璃牌
- 解锁条件原型: `{"extra":{"count":5,"e_key":"m_glass","enhancement":"Glass Card"},"type":"modify_deck"}`.
- 入池增强门槛: `m_glass`.
- 原型参数: `{"Xmult":1,"extra":0.75}`.
- 来源: [原型:494](<../../../game/game.lua#L494>).

<a id="j-ring-master"></a>

### 121. 马戏团长 / Showman

- ID: `j_ring_master`.
- 基价: $5.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 小丑牌,塔罗牌,星球牌 / 和幻灵牌可以同时 / 出现复数张
- 解锁说明: 达到底注 / 等级 4
- 解锁条件原型: `{"ante":4,"type":"ante_up"}`.
- 来源: [原型:496](<../../../game/game.lua#L496>).

<a id="j-flower-pot"></a>

### 122. 花盆 / Flower Pot

- ID: `j_flower_pot`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果打出的牌型中,包含 / 方片,梅花, / 红桃,黑桃牌各一张, / 则 X3 倍率
- 解锁说明: 达到底注 / 等级 8
- 解锁条件原型: `{"ante":8,"type":"ante_up"}`.
- 原型参数: `{"extra":3}`.
- 来源: [原型:497](<../../../game/game.lua#L497>).

<a id="j-blueprint"></a>

### 123. 蓝图 / Blueprint

- ID: `j_blueprint`.
- 基价: $10.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 复制 / 右侧小丑牌的能力
- 解锁说明: 赢一局
- 解锁条件原型: `{"type":"win_custom"}`.
- 来源: [原型:498](<../../../game/game.lua#L498>).

<a id="j-wee"></a>

### 124. 小小丑 / Wee Joker

- ID: `j_wee`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: false.
- 新档初始解锁: false.
- 效果: 每有一张打出的 2 计分时 / 这张小丑牌获得 / +8 筹码 / (当前为+[当前筹码]筹码)
- 解锁说明: 在 18 回合 / 或更少回合内赢得一局
- 解锁条件原型: `{"n_rounds":18,"type":"win"}`.
- 原型参数: `{"extra":{"chip_mod":8,"chips":0}}`.
- 来源: [原型:499](<../../../game/game.lua#L499>).

<a id="j-merry-andy"></a>

### 125. 快乐安迪 / Merry Andy

- ID: `j_merry_andy`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 每回合 / 弃牌次数+3 / 手牌上限-1
- 解锁说明: 在 12 回合 / 或更少回合内赢得一局
- 解锁条件原型: `{"n_rounds":12,"type":"win"}`.
- 原型参数: `{"d_size":3,"h_size":-1}`.
- 来源: [原型:500](<../../../game/game.lua#L500>).

<a id="j-oops"></a>

### 126. 六六大顺 / Oops! All 6s

- ID: `j_oops`.
- 基价: $4.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 将所有以数字标注出的 / 几率翻倍 / (例如:1/3 几率 -> 2/3 几率)
- 解锁说明: 在一次出牌中 / 获得至少 / 10000 筹码
- 解锁条件原型: `{"chips":10000,"type":"chip_score"}`.
- 来源: [原型:501](<../../../game/game.lua#L501>).

<a id="j-idol"></a>

### 127. 偶像 / The Idol

- ID: `j_idol`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 每张打出的[本回合目标花色][本回合目标点数] / 在计分时 / 给予 X2 倍率 / 每回合卡牌都会变动
- 解锁说明: 在一次出牌中 / 获得至少 / 1000000 筹码
- 解锁条件原型: `{"chips":1000000,"type":"chip_score"}`.
- 原型参数: `{"extra":2}`.
- 来源: [原型:502](<../../../game/game.lua#L502>).

<a id="j-seeing-double"></a>

### 128. 重影 / Seeing Double

- ID: `j_seeing_double`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果打出的牌中,包含 / 一张计分的梅花牌和 / 一张计分的任何其他花色牌 / 则 X2 倍率
- 解锁说明: 打出一手 / 包含 / 四张梅花 7 的牌
- 解锁条件原型: `{"extra":"four 7 of Clubs","type":"hand_contents"}`.
- 原型参数: `{"extra":2}`.
- 来源: [原型:503](<../../../game/game.lua#L503>).

<a id="j-matador"></a>

### 129. 斗牛士 / Matador

- ID: `j_matador`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果出牌触发了 / Boss 盲注的限制条件 / 获得 $8
- 解锁说明: 不使用弃牌且 / 只用一次出牌 / 打赢 Boss 盲注
- 解锁条件原型: `{"type":"round_win"}`.
- 原型参数: `{"extra":8}`.
- 来源: [原型:504](<../../../game/game.lua#L504>).

<a id="j-hit-the-road"></a>

### 130. 上路吧杰克 / Hit the Road

- ID: `j_hit_the_road`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 本回合中,每弃掉一张 / J 牌 / 这张小丑牌获得 X0.5 倍率 / (当前为 X[本回合当前乘倍率]倍率)
- 解锁说明: 一次弃掉 / 5 张 J
- 解锁条件原型: `{"type":"discard_custom"}`.
- 原型参数: `{"extra":0.5}`.
- 来源: [原型:505](<../../../game/game.lua#L505>).

<a id="j-duo"></a>

### 131. 二重奏 / The Duo

- ID: `j_duo`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果打出的牌中 / 包含对子 / X2 倍率
- 解锁说明: 赢一局 / 且不打出 / 对子
- 解锁条件原型: `{"extra":"Pair","type":"win_no_hand"}`.
- 原型参数: `{"Xmult":2,"type":"Pair"}`.
- 来源: [原型:506](<../../../game/game.lua#L506>).

<a id="j-trio"></a>

### 132. 三重奏 / The Trio

- ID: `j_trio`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果打出的牌中 / 包含三条 / X3 倍率
- 解锁说明: 赢一局 / 且不打出 / 三条
- 解锁条件原型: `{"extra":"Three of a Kind","type":"win_no_hand"}`.
- 原型参数: `{"Xmult":3,"type":"Three of a Kind"}`.
- 来源: [原型:507](<../../../game/game.lua#L507>).

<a id="j-family"></a>

### 133. 一家人 / The Family

- ID: `j_family`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果打出的牌中 / 包含四条 / X4 倍率
- 解锁说明: 赢一局 / 且不打出 / 四条
- 解锁条件原型: `{"extra":"Four of a Kind","type":"win_no_hand"}`.
- 原型参数: `{"Xmult":4,"type":"Four of a Kind"}`.
- 来源: [原型:508](<../../../game/game.lua#L508>).

<a id="j-order"></a>

### 134. 秩序 / The Order

- ID: `j_order`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果打出的牌中 / 包含顺子 / X3 倍率
- 解锁说明: 赢一局 / 且不打出 / 顺子
- 解锁条件原型: `{"extra":"Straight","type":"win_no_hand"}`.
- 原型参数: `{"Xmult":3,"type":"Straight"}`.
- 来源: [原型:509](<../../../game/game.lua#L509>).

<a id="j-tribe"></a>

### 135. 部落 / The Tribe

- ID: `j_tribe`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果打出的牌中 / 包含同花 / X2 倍率
- 解锁说明: 赢一局 / 且不打出 / 同花
- 解锁条件原型: `{"extra":"Flush","type":"win_no_hand"}`.
- 原型参数: `{"Xmult":2,"type":"Flush"}`.
- 来源: [原型:510](<../../../game/game.lua#L510>).

<a id="j-stuntman"></a>

### 136. 特技演员 / Stuntman

- ID: `j_stuntman`.
- 基价: $7.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: +250 筹码 / 手牌上限-2
- 解锁说明: 在一次出牌中 / 获得至少 / 100000000 筹码
- 解锁条件原型: `{"chips":100000000,"type":"chip_score"}`.
- 原型参数: `{"extra":{"chip_mod":250,"h_size":2}}`.
- 来源: [原型:512](<../../../game/game.lua#L512>).

<a id="j-invisible"></a>

### 137. 隐形小丑 / Invisible Joker

- ID: `j_invisible`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: false; 可永恒: false; 可易腐: true.
- 新档初始解锁: false.
- 效果: 经过 2 个回合后 / 售出此卡牌可以 / 随机复制一张小丑牌 / (当前为[已持有回合数]/2)
- 解锁说明: 赢一局 / 且从未拥有超过 / 4 张小丑牌
- 解锁条件原型: `{"type":"win_custom"}`.
- 原型参数: `{"extra":2}`.
- 来源: [原型:513](<../../../game/game.lua#L513>).

<a id="j-brainstorm"></a>

### 138. 头脑风暴 / Brainstorm

- ID: `j_brainstorm`.
- 基价: $10.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 复制最左边的 / 小丑牌的能力
- 解锁说明: 弃掉一手 / 皇家同花顺
- 解锁条件原型: `{"type":"discard_custom"}`.
- 来源: [原型:514](<../../../game/game.lua#L514>).

<a id="j-satellite"></a>

### 139. 卫星 / Satellite

- ID: `j_satellite`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 本赛局每使用过一种 / 星球牌,每回合结束时 / 可得到 $1 / (当前 $[已使用不同星球种数])
- 解锁说明: 有 $400 / 或更多
- 解锁条件原型: `{"extra":400,"type":"money"}`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:515](<../../../game/game.lua#L515>).

<a id="j-shoot-the-moon"></a>

### 140. 射月 / Shoot the Moon

- ID: `j_shoot_the_moon`.
- 基价: $5.
- 稀有度: 普通 Common.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 留在手牌中的 / 每一张 Q / 给予+13 倍率
- 解锁说明: 在单个回合中 / 打出牌组里的 / 所有红桃
- 解锁条件原型: `{"type":"play_all_hearts"}`.
- 原型参数: `{"extra":13}`.
- 来源: [原型:516](<../../../game/game.lua#L516>).

<a id="j-drivers-license"></a>

### 141. 驾驶执照 / Driver's License

- ID: `j_drivers_license`.
- 基价: $7.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 如果牌组中至少有 / 16 张增强卡牌, / 则 X3 倍率 / (当前[增强牌总数])
- 解锁说明: 增强牌组里 / 16 张卡牌
- 解锁条件原型: `{"extra":{"count":16,"tally":"total"},"type":"modify_deck"}`.
- 原型参数: `{"extra":3}`.
- 来源: [原型:517](<../../../game/game.lua#L517>).

<a id="j-cartomancer"></a>

### 142. 卡牌术士 / Cartomancer

- ID: `j_cartomancer`.
- 基价: $6.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 在选择盲注时 / 生成一张塔罗牌 / (必须有空位)
- 解锁说明: 发现每张 / 塔罗牌
- 解锁条件原型: `{"tarot_count":22,"type":"discover_amount"}`.
- 来源: [原型:518](<../../../game/game.lua#L518>).

<a id="j-astronomer"></a>

### 143. 天文学家 / Astronomer

- ID: `j_astronomer`.
- 基价: $8.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 所有星球牌 / 和天体补充包 / 在商店内都免费
- 解锁说明: 发现所有 / 星球牌
- 解锁条件原型: `{"planet_count":12,"type":"discover_amount"}`.
- 来源: [原型:519](<../../../game/game.lua#L519>).

<a id="j-burnt"></a>

### 144. 烧焦小丑 / Burnt Joker

- ID: `j_burnt`.
- 基价: $8.
- 稀有度: 稀有 Rare.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 升级每回合 / 第一次被弃掉的 / 牌型的等级
- 解锁说明: 售出所有 / +50 张卡牌 / ([当前存档累计值])
- 解锁条件原型: `{"extra":50,"type":"c_cards_sold"}`.
- 原型参数: `{"extra":4,"h_size":0}`.
- 来源: [原型:520](<../../../game/game.lua#L520>).

<a id="j-bootstraps"></a>

### 145. 提靴带 / Bootstraps

- ID: `j_bootstraps`.
- 基价: $7.
- 稀有度: 罕见 Uncommon.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 每拥有 $5 / +2 倍率 / (当前为+[当前倍率]倍率)
- 解锁说明: 在你的牌组中拥有至少 / 2 张多彩小丑
- 解锁条件原型: `{"extra":{"count":2,"polychrome":true},"type":"modify_jokers"}`.
- 原型参数: `{"extra":{"dollars":5,"mult":2}}`.
- 来源: [原型:521](<../../../game/game.lua#L521>).

<a id="j-caino"></a>

### 146. 卡尼奥 / Canio

- ID: `j_caino`.
- 基价: $20.
- 稀有度: 传奇 Legendary.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 每当一张人头牌 / 被摧毁时 / 这张小丑牌获得 X1 倍率 / (当前为 X[当前乘倍率]倍率)
- 解锁说明: ?????
- 解锁条件原型: `{"extra":"","hidden":true,"type":""}`.
- 原型参数: `{"extra":1}`.
- 来源: [原型:522](<../../../game/game.lua#L522>).

<a id="j-triboulet"></a>

### 147. 特里布莱 / Triboulet

- ID: `j_triboulet`.
- 基价: $20.
- 稀有度: 传奇 Legendary.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 打出的 K 和 Q / 在计分时 / 给予 X2 倍率
- 解锁说明: ?????
- 解锁条件原型: `{"extra":"","hidden":true,"type":""}`.
- 原型参数: `{"extra":2}`.
- 来源: [原型:523](<../../../game/game.lua#L523>).

<a id="j-yorick"></a>

### 148. 约里克 / Yorick

- ID: `j_yorick`.
- 基价: $20.
- 稀有度: 传奇 Legendary.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 每弃掉 23[[距下次增长所需弃牌张数]]张牌 / 这张小丑牌获得 X1 倍率 / (当前为 X[当前乘倍率] 倍率)
- 解锁说明: ?????
- 解锁条件原型: `{"extra":"","hidden":true,"type":""}`.
- 原型参数: `{"extra":{"discards":23,"xmult":1}}`.
- 来源: [原型:524](<../../../game/game.lua#L524>).

<a id="j-chicot"></a>

### 149. 希科 / Chicot

- ID: `j_chicot`.
- 基价: $20.
- 稀有度: 传奇 Legendary.
- 可蓝图复制: false; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 所有 Boss 盲注 / 限制条件消失
- 解锁说明: ?????
- 解锁条件原型: `{"extra":"","hidden":true,"type":""}`.
- 来源: [原型:525](<../../../game/game.lua#L525>).

<a id="j-perkeo"></a>

### 150. 帕奇欧 / Perkeo

- ID: `j_perkeo`.
- 基价: $20.
- 稀有度: 传奇 Legendary.
- 可蓝图复制: true; 可永恒: true; 可易腐: true.
- 新档初始解锁: false.
- 效果: 在离开商店时 / 随机复制 1 张 / 拥有的消耗牌 / 并给那张牌负片效果
- 解锁说明: ?????
- 解锁条件原型: `{"extra":"","hidden":true,"type":""}`.
- 来源: [原型:526](<../../../game/game.lua#L526>).
