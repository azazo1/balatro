# 挑战目录

版本: 1.0.1o. 共 20 项. [总索引](<../README.md>). 这里记录完整初始条件和禁用项, 自定义规则的实际含义见 [牌组与挑战机制](<../mechanics/run-modifiers.md>).

## 1. 煎蛋卷 / The Omelette

- ID: `c_omelette_1`.

### rules

```json
{"custom":[{"id":"no_reward"},{"id":"no_extra_hand_money"},{"id":"no_interest"}],"modifiers":[]}
```

### jokers

```json
[{"id":"j_egg"},{"id":"j_egg"},{"id":"j_egg"},{"id":"j_egg"},{"id":"j_egg"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[{"id":"v_seed_money"},{"id":"v_money_tree"},{"id":"j_to_the_moon"},{"id":"j_rocket"},{"id":"j_golden"},{"id":"j_satellite"}],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:64](<../../../game/challenges.lua#L64>).

## 2. 15分钟都市 / 15 Minute City

- ID: `c_city_1`.

### rules

```json
{"custom":[],"modifiers":[]}
```

### jokers

```json
[{"eternal":true,"id":"j_ride_the_bus"},{"eternal":true,"id":"j_shortcut"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"cards":[{"r":"4","s":"D"},{"r":"5","s":"D"},{"r":"6","s":"D"},{"r":"7","s":"D"},{"r":"8","s":"D"},{"r":"9","s":"D"},{"r":"T","s":"D"},{"r":"J","s":"D"},{"r":"Q","s":"D"},{"r":"K","s":"D"},{"r":"J","s":"D"},{"r":"Q","s":"D"},{"r":"K","s":"D"},{"r":"4","s":"C"},{"r":"5","s":"C"},{"r":"6","s":"C"},{"r":"7","s":"C"},{"r":"8","s":"C"},{"r":"9","s":"C"},{"r":"T","s":"C"},{"r":"J","s":"C"},{"r":"Q","s":"C"},{"r":"K","s":"C"},{"r":"J","s":"C"},{"r":"Q","s":"C"},{"r":"K","s":"C"},{"r":"4","s":"H"},{"r":"5","s":"H"},{"r":"6","s":"H"},{"r":"7","s":"H"},{"r":"8","s":"H"},{"r":"9","s":"H"},{"r":"T","s":"H"},{"r":"J","s":"H"},{"r":"Q","s":"H"},{"r":"K","s":"H"},{"r":"J","s":"H"},{"r":"Q","s":"H"},{"r":"K","s":"H"},{"r":"4","s":"S"},{"r":"5","s":"S"},{"r":"6","s":"S"},{"r":"7","s":"S"},{"r":"8","s":"S"},{"r":"9","s":"S"},{"r":"T","s":"S"},{"r":"J","s":"S"},{"r":"Q","s":"S"},{"r":"K","s":"S"},{"r":"J","s":"S"},{"r":"Q","s":"S"},{"r":"K","s":"S"}],"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:105](<../../../game/challenges.lua#L105>).

## 3. 富者愈富 / Rich get Richer

- ID: `c_rich_1`.

### rules

```json
{"custom":[{"id":"chips_dollar_cap"}],"modifiers":[{"id":"dollars","value":100}]}
```

### jokers

```json
[]
```

### consumeables

```json
[]
```

### vouchers

```json
[{"id":"v_seed_money"},{"id":"v_money_tree"}]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:135](<../../../game/challenges.lua#L135>).

## 4. 刀锋之上 / On a Knife's Edge

- ID: `c_knife_1`.

### rules

```json
{"custom":[],"modifiers":[]}
```

### jokers

```json
[{"eternal":true,"id":"j_ceremonial","pinned":true}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:166](<../../../game/challenges.lua#L166>).

## 5. X光视界 / X-ray Vision

- ID: `c_xray_1`.

### rules

```json
{"custom":[{"id":"flipped_cards","value":4}],"modifiers":[]}
```

### jokers

```json
[]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:194](<../../../game/challenges.lua#L194>).

## 6. 疯狂世界 / Mad World

- ID: `c_mad_world_1`.

### rules

```json
{"custom":[{"id":"no_extra_hand_money"},{"id":"no_interest"}],"modifiers":[]}
```

### jokers

```json
[{"edition":"negative","eternal":true,"id":"j_pareidolia"},{"eternal":true,"id":"j_business"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"cards":[{"r":"2","s":"D"},{"r":"3","s":"D"},{"r":"4","s":"D"},{"r":"5","s":"D"},{"r":"6","s":"D"},{"r":"7","s":"D"},{"r":"8","s":"D"},{"r":"9","s":"D"},{"r":"2","s":"C"},{"r":"3","s":"C"},{"r":"4","s":"C"},{"r":"5","s":"C"},{"r":"6","s":"C"},{"r":"7","s":"C"},{"r":"8","s":"C"},{"r":"9","s":"C"},{"r":"2","s":"H"},{"r":"3","s":"H"},{"r":"4","s":"H"},{"r":"5","s":"H"},{"r":"6","s":"H"},{"r":"7","s":"H"},{"r":"8","s":"H"},{"r":"9","s":"H"},{"r":"2","s":"S"},{"r":"3","s":"S"},{"r":"4","s":"S"},{"r":"5","s":"S"},{"r":"6","s":"S"},{"r":"7","s":"S"},{"r":"8","s":"S"},{"r":"9","s":"S"}],"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[{"id":"bl_plant","type":"blind"}],"banned_tags":[]}
```

来源: [挑战原型:222](<../../../game/challenges.lua#L222>).

## 7. 奢侈税 / Luxury Tax

- ID: `c_luxury_1`.

### rules

```json
{"custom":[{"id":"minus_hand_size_per_X_dollar","value":5}],"modifiers":[{"id":"hand_size","value":10}]}
```

### jokers

```json
[]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:255](<../../../game/challenges.lua#L255>).

## 8. 不腐之物 / Non-Perishable

- ID: `c_non_perishable_1`.

### rules

```json
{"custom":[{"id":"all_eternal"}],"modifiers":[]}
```

### jokers

```json
[]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[{"id":"j_gros_michel"},{"id":"j_ice_cream"},{"id":"j_cavendish"},{"id":"j_turtle_bean"},{"id":"j_ramen"},{"id":"j_diet_cola"},{"id":"j_selzer"},{"id":"j_popcorn"},{"id":"j_mr_bones"},{"id":"j_invisible"},{"id":"j_luchador"}],"banned_other":[{"id":"bl_final_leaf","type":"blind"}],"banned_tags":[]}
```

来源: [挑战原型:284](<../../../game/challenges.lua#L284>).

## 9. 美杜莎 / Medusa

- ID: `c_medusa_1`.

### rules

```json
{"custom":[],"modifiers":[]}
```

### jokers

```json
[{"eternal":true,"id":"j_marble"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"cards":[{"r":"2","s":"D"},{"r":"3","s":"D"},{"r":"4","s":"D"},{"r":"5","s":"D"},{"r":"6","s":"D"},{"r":"7","s":"D"},{"r":"8","s":"D"},{"r":"9","s":"D"},{"r":"T","s":"D"},{"e":"m_stone","r":"J","s":"D"},{"e":"m_stone","r":"Q","s":"D"},{"e":"m_stone","r":"K","s":"D"},{"r":"A","s":"D"},{"r":"2","s":"C"},{"r":"3","s":"C"},{"r":"4","s":"C"},{"r":"5","s":"C"},{"r":"6","s":"C"},{"r":"7","s":"C"},{"r":"8","s":"C"},{"r":"9","s":"C"},{"r":"T","s":"C"},{"e":"m_stone","r":"J","s":"C"},{"e":"m_stone","r":"Q","s":"C"},{"e":"m_stone","r":"K","s":"C"},{"r":"A","s":"C"},{"r":"2","s":"H"},{"r":"3","s":"H"},{"r":"4","s":"H"},{"r":"5","s":"H"},{"r":"6","s":"H"},{"r":"7","s":"H"},{"r":"8","s":"H"},{"r":"9","s":"H"},{"r":"T","s":"H"},{"e":"m_stone","r":"J","s":"H"},{"e":"m_stone","r":"Q","s":"H"},{"e":"m_stone","r":"K","s":"H"},{"r":"A","s":"H"},{"r":"2","s":"S"},{"r":"3","s":"S"},{"r":"4","s":"S"},{"r":"5","s":"S"},{"r":"6","s":"S"},{"r":"7","s":"S"},{"r":"8","s":"S"},{"r":"9","s":"S"},{"r":"T","s":"S"},{"e":"m_stone","r":"J","s":"S"},{"e":"m_stone","r":"Q","s":"S"},{"e":"m_stone","r":"K","s":"S"},{"r":"A","s":"S"}],"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:324](<../../../game/challenges.lua#L324>).

## 10. 孤注一掷 / Double or Nothing

- ID: `c_double_nothing_1`.

### rules

```json
{"custom":[{"id":"debuff_played_cards"}],"modifiers":[]}
```

### jokers

```json
[]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"cards":[{"g":"Red","r":"2","s":"D"},{"g":"Red","r":"3","s":"D"},{"g":"Red","r":"4","s":"D"},{"g":"Red","r":"5","s":"D"},{"g":"Red","r":"6","s":"D"},{"g":"Red","r":"7","s":"D"},{"g":"Red","r":"8","s":"D"},{"g":"Red","r":"9","s":"D"},{"g":"Red","r":"T","s":"D"},{"g":"Red","r":"J","s":"D"},{"g":"Red","r":"Q","s":"D"},{"g":"Red","r":"K","s":"D"},{"g":"Red","r":"A","s":"D"},{"g":"Red","r":"2","s":"C"},{"g":"Red","r":"3","s":"C"},{"g":"Red","r":"4","s":"C"},{"g":"Red","r":"5","s":"C"},{"g":"Red","r":"6","s":"C"},{"g":"Red","r":"7","s":"C"},{"g":"Red","r":"8","s":"C"},{"g":"Red","r":"9","s":"C"},{"g":"Red","r":"T","s":"C"},{"g":"Red","r":"J","s":"C"},{"g":"Red","r":"Q","s":"C"},{"g":"Red","r":"K","s":"C"},{"g":"Red","r":"A","s":"C"},{"g":"Red","r":"2","s":"H"},{"g":"Red","r":"3","s":"H"},{"g":"Red","r":"4","s":"H"},{"g":"Red","r":"5","s":"H"},{"g":"Red","r":"6","s":"H"},{"g":"Red","r":"7","s":"H"},{"g":"Red","r":"8","s":"H"},{"g":"Red","r":"9","s":"H"},{"g":"Red","r":"T","s":"H"},{"g":"Red","r":"J","s":"H"},{"g":"Red","r":"Q","s":"H"},{"g":"Red","r":"K","s":"H"},{"g":"Red","r":"A","s":"H"},{"g":"Red","r":"2","s":"S"},{"g":"Red","r":"3","s":"S"},{"g":"Red","r":"4","s":"S"},{"g":"Red","r":"5","s":"S"},{"g":"Red","r":"6","s":"S"},{"g":"Red","r":"7","s":"S"},{"g":"Red","r":"8","s":"S"},{"g":"Red","r":"9","s":"S"},{"g":"Red","r":"T","s":"S"},{"g":"Red","r":"J","s":"S"},{"g":"Red","r":"Q","s":"S"},{"g":"Red","r":"K","s":"S"},{"g":"Red","r":"A","s":"S"}],"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:353](<../../../game/challenges.lua#L353>).

## 11. 角色固化 / Typecast

- ID: `c_typecast_1`.

### rules

```json
{"custom":[{"id":"set_eternal_ante","value":4},{"id":"set_joker_slots_ante","value":4}],"modifiers":[]}
```

### jokers

```json
[]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[{"id":"bl_final_leaf","type":"blind"}],"banned_tags":[]}
```

来源: [挑战原型:382](<../../../game/challenges.lua#L382>).

## 12. 通货膨胀 / Inflation

- ID: `c_inflation_1`.

### rules

```json
{"custom":[{"id":"inflation"}],"modifiers":[]}
```

### jokers

```json
[{"id":"j_credit_card"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[{"id":"v_clearance_sale"},{"id":"v_liquidation"}],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:412](<../../../game/challenges.lua#L412>).

## 13. 布莱姆·扑克 / Bram Poker

- ID: `c_bram_poker_1`.

### rules

```json
{"custom":[{"id":"no_shop_jokers"}],"modifiers":[]}
```

### jokers

```json
[{"eternal":true,"id":"j_vampire"}]
```

### consumeables

```json
[{"id":"c_empress"},{"id":"c_emperor"}]
```

### vouchers

```json
[{"id":"v_magic_trick"},{"id":"v_illusion"}]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:443](<../../../game/challenges.lua#L443>).

## 14. 易碎品 / Fragile

- ID: `c_fragile_1`.

### rules

```json
{"custom":[],"modifiers":[]}
```

### jokers

```json
[{"edition":"negative","eternal":true,"id":"j_oops"},{"edition":"negative","eternal":true,"id":"j_oops"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"cards":[{"e":"m_glass","r":"2","s":"D"},{"e":"m_glass","r":"3","s":"D"},{"e":"m_glass","r":"4","s":"D"},{"e":"m_glass","r":"5","s":"D"},{"e":"m_glass","r":"6","s":"D"},{"e":"m_glass","r":"7","s":"D"},{"e":"m_glass","r":"8","s":"D"},{"e":"m_glass","r":"9","s":"D"},{"e":"m_glass","r":"T","s":"D"},{"e":"m_glass","r":"J","s":"D"},{"e":"m_glass","r":"Q","s":"D"},{"e":"m_glass","r":"K","s":"D"},{"e":"m_glass","r":"A","s":"D"},{"e":"m_glass","r":"2","s":"C"},{"e":"m_glass","r":"3","s":"C"},{"e":"m_glass","r":"4","s":"C"},{"e":"m_glass","r":"5","s":"C"},{"e":"m_glass","r":"6","s":"C"},{"e":"m_glass","r":"7","s":"C"},{"e":"m_glass","r":"8","s":"C"},{"e":"m_glass","r":"9","s":"C"},{"e":"m_glass","r":"T","s":"C"},{"e":"m_glass","r":"J","s":"C"},{"e":"m_glass","r":"Q","s":"C"},{"e":"m_glass","r":"K","s":"C"},{"e":"m_glass","r":"A","s":"C"},{"e":"m_glass","r":"2","s":"H"},{"e":"m_glass","r":"3","s":"H"},{"e":"m_glass","r":"4","s":"H"},{"e":"m_glass","r":"5","s":"H"},{"e":"m_glass","r":"6","s":"H"},{"e":"m_glass","r":"7","s":"H"},{"e":"m_glass","r":"8","s":"H"},{"e":"m_glass","r":"9","s":"H"},{"e":"m_glass","r":"T","s":"H"},{"e":"m_glass","r":"J","s":"H"},{"e":"m_glass","r":"Q","s":"H"},{"e":"m_glass","r":"K","s":"H"},{"e":"m_glass","r":"A","s":"H"},{"e":"m_glass","r":"2","s":"S"},{"e":"m_glass","r":"3","s":"S"},{"e":"m_glass","r":"4","s":"S"},{"e":"m_glass","r":"5","s":"S"},{"e":"m_glass","r":"6","s":"S"},{"e":"m_glass","r":"7","s":"S"},{"e":"m_glass","r":"8","s":"S"},{"e":"m_glass","r":"9","s":"S"},{"e":"m_glass","r":"T","s":"S"},{"e":"m_glass","r":"J","s":"S"},{"e":"m_glass","r":"Q","s":"S"},{"e":"m_glass","r":"K","s":"S"},{"e":"m_glass","r":"A","s":"S"}],"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[{"id":"c_magician"},{"id":"c_empress"},{"id":"c_heirophant"},{"id":"c_chariot"},{"id":"c_devil"},{"id":"c_tower"},{"id":"c_lovers"},{"id":"c_incantation"},{"id":"c_grim"},{"id":"c_familiar"},{"id":"p_standard_normal_1","ids":["p_standard_normal_1","p_standard_normal_2","p_standard_normal_3","p_standard_normal_4","p_standard_jumbo_1","p_standard_jumbo_2","p_standard_mega_1","p_standard_mega_2"]},{"id":"j_marble"},{"id":"j_vampire"},{"id":"j_midas_mask"},{"id":"j_certificate"},{"id":"v_magic_trick"},{"id":"v_illusion"}],"banned_other":[],"banned_tags":[{"id":"tag_standard"}]}
```

来源: [挑战原型:476](<../../../game/challenges.lua#L476>).

## 15. 巨石 / Monolith

- ID: `c_monolith_1`.

### rules

```json
{"custom":[],"modifiers":[]}
```

### jokers

```json
[{"eternal":true,"id":"j_obelisk"},{"edition":"negative","eternal":true,"id":"j_marble"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:526](<../../../game/challenges.lua#L526>).

## 16. 点火升空 / Blast Off

- ID: `c_blast_off_1`.

### rules

```json
{"custom":[],"modifiers":[{"id":"hands","value":2},{"id":"discards","value":2},{"id":"joker_slots","value":4}]}
```

### jokers

```json
[{"eternal":true,"id":"j_constellation"},{"eternal":true,"id":"j_rocket"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[{"id":"v_planet_merchant"},{"id":"v_planet_tycoon"}]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[{"id":"v_grabber"},{"id":"v_nacho_tong"},{"id":"j_burglar"}],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:555](<../../../game/challenges.lua#L555>).

## 17. 五连抽 / Five-Card Draw

- ID: `c_five_card_1`.

### rules

```json
{"custom":[],"modifiers":[{"id":"hand_size","value":5},{"id":"joker_slots","value":7},{"id":"discards","value":6}]}
```

### jokers

```json
[{"id":"j_card_sharp"},{"id":"j_joker"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[{"id":"j_juggler"},{"id":"j_troubadour"},{"id":"j_turtle_bean"}],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:592](<../../../game/challenges.lua#L592>).

## 18. 金针 / Golden Needle

- ID: `c_golden_needle_1`.

### rules

```json
{"custom":[{"id":"discard_cost","value":1}],"modifiers":[{"id":"hands","value":1},{"id":"discards","value":6},{"id":"dollars","value":10}]}
```

### jokers

```json
[{"id":"j_credit_card"}]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[{"id":"v_grabber"},{"id":"v_nacho_tong"},{"id":"j_burglar"}],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:627](<../../../game/challenges.lua#L627>).

## 19. 残酷 / Cruelty

- ID: `c_cruelty_1`.

### rules

```json
{"custom":[{"id":"no_reward_specific","value":"Small"},{"id":"no_reward_specific","value":"Big"}],"modifiers":[{"id":"joker_slots","value":3}]}
```

### jokers

```json
[]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[],"banned_other":[],"banned_tags":[]}
```

来源: [挑战原型:662](<../../../game/challenges.lua#L662>).

## 20. 无小丑 / Jokerless

- ID: `c_jokerless_1`.

### rules

```json
{"custom":[{"id":"no_shop_jokers"}],"modifiers":[{"id":"joker_slots","value":0}]}
```

### jokers

```json
[]
```

### consumeables

```json
[]
```

### vouchers

```json
[]
```

### deck

```json
{"type":"Challenge Deck"}
```

### restrictions

```json
{"banned_cards":[{"id":"c_judgement"},{"id":"c_wraith"},{"id":"c_soul"},{"id":"v_antimatter"},{"id":"p_buffoon_normal_1","ids":["p_buffoon_normal_1","p_buffoon_normal_2","p_buffoon_jumbo_1","p_buffoon_mega_1"]}],"banned_other":[{"id":"bl_final_acorn","type":"blind"},{"id":"bl_final_heart","type":"blind"},{"id":"bl_final_leaf","type":"blind"}],"banned_tags":[{"id":"tag_rare"},{"id":"tag_uncommon"},{"id":"tag_holo"},{"id":"tag_polychrome"},{"id":"tag_negative"},{"id":"tag_foil"},{"id":"tag_buffoon"},{"id":"tag_top_up"}]}
```

来源: [挑战原型:692](<../../../game/challenges.lua#L692>).
