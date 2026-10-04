//! 商店的标价与购买.
//!
//! 价格那部分有实机基准: ALEEB 那局第一个商店里 `j_trading` 与 `j_rocket` 各标价 6 元,
//! 两张原型的基础价也都是 6, 且都没有版本, 所以这是一次干净的对拍.
//!
//! 购买那部分照 `G.FUNCS.buy_from_shop`: 先看空位, 扣钱, 再把卡挪进持有区.

mod common;

use balatro_engine::run::shop::{ShopCard, shop_cost};
use balatro_engine::run::{ActionError, Phase};
use common::aleeb_run;

/// 造一张带价签的商店卡, 免得每个用例都写一遍全部字段.
fn shop_card(key: &str, cost: f64) -> ShopCard {
    ShopCard {
        key: key.to_owned(),
        edition: None,
        eternal: false,
        perishable: false,
        rental: false,
        enhancement: None,
        todo: None,
        cost,
    }
}

/// 开一个能买东西的局面: 到了商店, 手里有钱, 货架空着.
fn ready_to_buy(dollars: f64) -> balatro_engine::run::RunState {
    let mut run = aleeb_run();
    run.phase = Phase::Shop;
    run.dollars = dollars;
    run
}

#[test]
fn joker_prices_match_the_real_game() {
    // 实机: 0 号小丑包 (j_trading, 带永恒) 与 j_rocket 都标价 6.
    // 无版本, 无通胀, 无折扣时, 价格就是基础价向下取整后的值.
    assert_eq!(shop_cost(6.0, None, false, 0.0, 0.0), 6.0, "j_trading 与 j_rocket 的实机标价");
    // 基础价 4 的小丑在实机里也标 4.
    assert_eq!(shop_cost(4.0, None, false, 0.0, 0.0), 4.0);
}

#[test]
fn editions_and_rentals_change_the_price() {
    use balatro_engine::cards::Edition;

    // 版本加价: 闪箔 +2, 全息 +3, 多彩与负片 +5.
    assert_eq!(shop_cost(4.0, Some(Edition::Foil), false, 0.0, 0.0), 6.0);
    assert_eq!(shop_cost(4.0, Some(Edition::Holo), false, 0.0, 0.0), 7.0);
    assert_eq!(shop_cost(4.0, Some(Edition::Polychrome), false, 0.0, 0.0), 9.0);
    // 租赁一律 1 元.
    assert_eq!(shop_cost(8.0, None, true, 0.0, 0.0), 1.0);
    // 打折是乘性的, 再向下取整.
    assert_eq!(shop_cost(10.0, None, false, 0.0, 25.0), 7.0);
    // 再便宜也不低于 1.
    assert_eq!(shop_cost(1.0, None, false, 0.0, 99.0), 1.0);
}

#[test]
fn buying_moves_the_card_and_deducts_the_price() {
    let mut run = ready_to_buy(10.0);
    let card = shop_card("j_jolly", 4.0);

    assert_eq!(run.buy(&card).expect("钱够, 有空位"), 4.0);
    assert_eq!(run.dollars, 6.0, "扣掉标价");
    assert_eq!(run.jokers.len(), 1);
    assert_eq!(run.jokers[0].key, "j_jolly", "小丑进了持有区");
    assert_eq!(run.jokers[0].t_mult, 8.0, "带上原型的参数");
}

#[test]
fn buying_rejects_when_money_or_room_is_missing() {
    let card = shop_card("j_jolly", 4.0);

    let mut poor = ready_to_buy(3.0);
    assert_eq!(
        poor.buy(&card),
        Err(ActionError::NotEnoughMoney { cost: 4.0, have: 3.0 })
    );
    assert_eq!(poor.dollars, 3.0, "被拒时不动钱");
    assert!(poor.jokers.is_empty());

    // 槽位满了也要拒, 而不是悄悄塞进去.
    let mut full = ready_to_buy(99.0);
    full.base_joker_slots = 1;
    full.buy(&card).expect("第一个位置能买");
    assert_eq!(
        full.buy(&card),
        Err(ActionError::NoRoom { what: "小丑", slots: 1 })
    );
    assert_eq!(full.jokers.len(), 1);
}

#[test]
fn vouchers_and_consumables_go_to_their_own_places() {
    // 优惠券买下就生效, 不进持有区.
    let mut run = ready_to_buy(20.0);
    run.buy(&shop_card("v_magic_trick", 10.0)).expect("买优惠券");
    assert!(run.used_vouchers.contains("v_magic_trick"));
    assert!(run.jokers.is_empty(), "优惠券不占小丑位");

    // 塔罗进消耗槽, 也不占小丑位.
    run.buy(&shop_card("c_fool", 3.0)).expect("买塔罗");
    assert_eq!(common::consumable_keys(&run), vec!["c_fool".to_owned()]);
    assert!(run.jokers.is_empty());
}

#[test]
fn buying_is_rejected_outside_the_shop() {
    let mut run = aleeb_run();
    assert_eq!(run.phase, Phase::BlindSelect, "还没开局");
    assert!(matches!(
        run.buy(&shop_card("j_jolly", 1.0)),
        Err(ActionError::NotInPhase { .. })
    ));
}

/// 买下补充包会**当场**把它打开并进入挑牌状态, 挑完约定张数就回商店.
#[test]
fn buying_a_pack_opens_it_and_picking_returns_to_the_shop() {
    let mut run = ready_to_buy(20.0);
    assert_eq!(run.buy(&shop_card("p_arcana_normal_4", 4.0)).expect("买包"), 4.0);
    assert_eq!(run.dollars, 16.0, "扣掉标价");
    assert_eq!(run.phase, Phase::BoosterOpened, "买下那一刻就开了");

    let pack = run.open_pack.clone().expect("有包待挑");
    assert_eq!(pack.size, 3, "秘术包开三张");
    assert_eq!(pack.choices_left, 1, "秘术包挑一张");
    assert_eq!(pack.contents.len(), 3);

    let picked = run.pick_from_pack(0).expect("挑得动");
    assert_eq!(picked, pack.contents[0].key);
    assert!(run.open_pack.is_none(), "挑完就清空");
    assert_eq!(run.phase, Phase::Shop, "回到商店");
    // 塔罗与幻灵进消耗槽.
    assert_eq!(common::consumable_keys(&run), vec![picked]);
}

/// 包里挑下来的牌也消耗过随机数, 所以挑哪张都不影响后续序列.
#[test]
fn the_pack_contents_are_fixed_when_it_is_opened() {
    let mut a = ready_to_buy(20.0);
    let mut b = ready_to_buy(20.0);

    a.buy(&shop_card("p_arcana_normal_4", 4.0)).expect("买包");
    b.buy(&shop_card("p_arcana_normal_4", 4.0)).expect("买包");

    let contents_a = a.open_pack.clone().expect("有包").contents;
    let contents_b = b.open_pack.clone().expect("有包").contents;
    assert_eq!(contents_a, contents_b, "同一局面开出的内容相同");

    // 各挑不同的一张, 之后的随机数状态仍然一致.
    a.pick_from_pack(0).expect("挑得动");
    b.pick_from_pack(1).expect("挑得动");
    a.buy(&shop_card("j_jolly", 1.0)).expect("再买一张小丑");
    b.buy(&shop_card("j_jolly", 1.0)).expect("再买一张小丑");
    assert_eq!(
        a.jokers.iter().map(|j| j.key.clone()).collect::<Vec<_>>(),
        b.jokers.iter().map(|j| j.key.clone()).collect::<Vec<_>>(),
    );
}

/// 卖出价是买入价的一半向下取整, 最低一元.
#[test]
fn selling_a_joker_pays_half_its_price() {
    let mut run = ready_to_buy(10.0);
    run.buy(&shop_card("j_jolly", 5.0)).expect("买下");
    assert_eq!(run.dollars, 5.0);

    assert_eq!(run.sell_joker(0).expect("卖掉"), 2.0, "5 的一半向下取整");
    assert_eq!(run.dollars, 7.0, "钱回到手里");
    assert!(run.jokers.is_empty(), "卖掉的从持有区消失");

    // 基础价 1 的小丑卖不出 0 元, 至少给 1.
    let mut cheap = ready_to_buy(10.0);
    cheap.buy(&shop_card("j_jolly", 1.0)).expect("买下");
    assert_eq!(cheap.sell_joker(0).expect("卖掉"), 1.0);

    // 下标越界要拒.
    assert_eq!(run.sell_joker(9), Err(ActionError::BadIndex(9)));
}

/// 卖消耗牌走另一条, 价钱按原型的基础价算.
///
/// 消耗牌目前只记原型键, 没记住买入价, 所以这里用"正好按基础价买进来"的情形 —— 那样两边一致.
#[test]
fn selling_a_consumable_pays_half_its_base_cost() {
    let mut run = ready_to_buy(20.0);
    // 愚者的基础价是 3, 卖掉得 1.
    run.buy(&shop_card("c_fool", 3.0)).expect("买塔罗");
    assert_eq!(common::consumable_keys(&run), vec!["c_fool".to_owned()]);
    assert_eq!(run.sell_consumable(0).expect("卖掉"), 1.0);
    assert!(run.consumables.is_empty());
}

/// 重抽越抽越贵, 免费重抽那一档既不花钱也不涨价.
#[test]
fn reroll_costs_grow_with_each_use() {
    let mut run = ready_to_buy(30.0);
    assert_eq!(run.reroll_cost(), 5.0, "基础价");
    assert_eq!(run.pay_for_reroll().expect("抽一次"), 5.0);
    assert_eq!(run.dollars, 25.0);
    assert_eq!(run.reroll_cost(), 6.0, "每抽一次涨一元");

    assert_eq!(run.pay_for_reroll().expect("再抽"), 6.0);
    assert_eq!(run.dollars, 19.0);

    // 混沌小丑给的免费重抽.
    run.free_rerolls = 1;
    assert_eq!(run.reroll_cost(), 0.0, "免费");
    assert_eq!(run.pay_for_reroll().expect("免费抽"), 0.0);
    assert_eq!(run.dollars, 19.0, "不花钱");
    assert_eq!(run.rerolls, 2, "免费那次不累计涨价");
    assert_eq!(run.reroll_cost(), 7.0, "免费次数用完之后接着涨");

    // 钱不够要拒.
    let mut poor = ready_to_buy(4.0);
    assert_eq!(
        poor.pay_for_reroll(),
        Err(ActionError::NotEnoughMoney { cost: 5.0, have: 4.0 })
    );
    assert_eq!(poor.dollars, 4.0, "被拒时不动钱");
}

/// 挑牌也要看持有区有没有空位.
#[test]
fn picking_from_a_pack_rejects_bad_input() {
    let mut run = ready_to_buy(20.0);
    run.buy(&shop_card("p_arcana_normal_4", 4.0)).expect("买包");

    assert_eq!(
        run.pick_from_pack(99),
        Err(ActionError::BadIndex(99)),
        "包里的下标越界"
    );
    assert_eq!(run.phase, Phase::BoosterOpened, "被拒时还在挑牌");

    // 消耗槽**满了也照样取得出来**: 游戏那边包里的牌是用 `emplace` 放的, 不查槽位
    // (与珀克奥的负片复制品同一个机制), 所以会出现"3 张挤在 2 格里".
    // 整局对拍的记录里第 48 步就是这样 —— 原来这里断言"要拒", 那是引擎自己加的限制.
    run.base_consumable_slots = 0;
    assert!(
        run.pick_from_pack(0).is_ok(),
        "包里的牌不看槽位, 取出来放得下"
    );
}

/// 进商店会铺一次货架, 而重抽只换小丑那两格.
///
/// 卡包不动这一点很重要: 游戏里 `reroll_shop` 只清 `G.shop_jokers`, 如果把卡包也重抽了,
/// 后面所有随机数都会偏.
#[test]
fn cash_out_stocks_the_shelf_and_reroll_only_touches_jokers() {
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = aleeb_run();
    run.start();
    run.discard(&[5, 6, 7]).expect("弃三张");
    run.play(
        &[5, 4, 3, 2, 0],
        &EvalEnv::default(),
        BackEffect::Plasma,
    )
    .expect("出顺子");
    run.cash_out().expect("这一回合在结算");

    let before = run.shop.clone().expect("进商店就铺好了货架");
    assert_eq!(before.jokers.len(), 2, "两格小丑");
    assert_eq!(before.packs.len(), 2, "两个补充包");

    // 优惠券那一格摆的是开局就算好的那张, 键与 `shop_vouchers` 一致.
    let voucher = before.voucher.clone().expect("开局抽了券, 货架上有");
    assert_eq!(run.shop_vouchers, vec![voucher.key.clone()]);
    assert_eq!(voucher.cost, 10.0, "券的原型基础价是 10");

    run.reroll_shop().expect("重抽");
    let after = run.shop.clone().expect("还在商店");

    assert_ne!(
        after.jokers[0].key, before.jokers[0].key,
        "重抽之后小丑换了"
    );
    assert_eq!(
        after.packs.iter().map(|c| c.key.clone()).collect::<Vec<_>>(),
        before.packs.iter().map(|c| c.key.clone()).collect::<Vec<_>>(),
        "卡包不该被重抽"
    );
    assert_eq!(
        after.voucher.map(|c| c.key),
        Some(voucher.key),
        "优惠券也不该被重抽"
    );
    assert_eq!(run.rerolls, 1, "记了一次");
}

/// 信用卡把"能欠多少"推开 20 元, 买进来就生效, 卖掉就恢复.
///
/// 判据不是"钱够不够"而是 `cost > dollars - bankrupt_at`: 默认 `bankrupt_at` 是 0,
/// 也就是一分钱都不能欠; 持卡之后它变成 -20, 于是能欠到 -20.
#[test]
fn credit_card_allows_going_into_debt() {
    let mut run = ready_to_buy(10.0);

    // 没有信用卡时, 钱不够就是买不了.
    assert!(matches!(
        run.buy(&shop_card("j_jolly", 25.0)),
        Err(ActionError::NotEnoughMoney { .. })
    ));

    // 买下信用卡 (基础价 1 元).
    run.buy(&shop_card("j_credit_card", 1.0)).expect("买信用卡");
    assert_eq!(run.dollars, 9.0);
    assert_eq!(run.bankrupt_at, -20.0, "破产线被推开");

    // 现在 9 元也能买 25 元的东西.
    assert_eq!(run.buy(&shop_card("j_jolly", 25.0)).expect("能欠"), 25.0);
    assert_eq!(run.dollars, -16.0, "欠了 16 元");

    // 但欠过头仍然要拒: -16 再欠 10 就超过 -20 了.
    assert!(
        matches!(
            run.buy(&shop_card("j_jolly", 10.0)),
            Err(ActionError::NotEnoughMoney { .. })
        ),
        "超过破产线就不能再买"
    );
    assert_eq!(run.dollars, -16.0, "被拒时不动钱");

    // 把信用卡卖掉, 破产线收回去.
    let card_index = run
        .jokers
        .iter()
        .position(|j| j.key == "j_credit_card")
        .expect("信用卡还在手上");
    run.sell_joker(card_index).expect("卖掉信用卡");
    assert_eq!(run.bankrupt_at, 0.0, "破产线恢复");
    assert!(matches!(
        run.buy(&shop_card("j_jolly", 1.0)),
        Err(ActionError::NotEnoughMoney { .. })
    ));
}

/// 重抽也走同一条判据.
#[test]
fn reroll_respects_the_debt_limit_too() {
    let mut run = ready_to_buy(1.0);
    // 重抽要 5 元, 现在只有 1 元.
    assert!(matches!(
        run.reroll_shop(),
        Err(ActionError::NotEnoughMoney { cost: 5.0, have: 1.0 })
    ));

    // 持卡之后能欠着抽.
    run.jokers
        .push(balatro_engine::jokers::Joker::new("j_credit_card").expect("有这张"));
    run.bankrupt_at = -20.0;
    assert_eq!(run.reroll_shop().expect("能欠着抽"), 5.0);
    assert_eq!(run.dollars, -4.0);
}

/// 代金券标签让这一轮的商店免费: 买什么都不花钱, 卖掉也换不回钱.
///
/// 它是"这一轮商店"的效果, 所以每次进商店时按持有列表重算一次 —— 不然会一路免费下去.
#[test]
fn coupon_tag_makes_the_shop_free() {
    let mut run = ready_to_buy(10.0);
    run.tags.push("tag_coupon".to_owned());
    // 进商店那一步会把它打开.
    run.phase = Phase::RoundEval;
    run.round_eval = Some(balatro_engine::run::RoundEval::default());
    run.cash_out().expect("这一回合在结算");
    assert!(run.shop_free, "进商店时标记上");

    let before = run.dollars;
    let paid = run.buy(&shop_card("j_jolly", 5.0)).expect("买下");
    assert_eq!(paid, 0.0, "免费就拿 0 元");
    assert_eq!(run.dollars, before, "钱没动");
    assert_eq!(
        run.jokers.last().expect("有张小丑").cost,
        0.0,
        "买入价记 0, 卖掉也换不回钱"
    );

    // 下一轮商店不再免费.
    run.tags.retain(|t| t != "tag_coupon");
    run.phase = Phase::RoundEval;
    run.round_eval = Some(balatro_engine::run::RoundEval::default());
    run.cash_out().expect("这一回合在结算");
    assert!(!run.shop_free, "标签用掉之后就没了");
}

/// D6 标签让这一轮的商店重抽免费.
#[test]
fn d6_tag_makes_the_first_shop_reroll_free() {
    let mut run = ready_to_buy(10.0);
    run.tags.push("tag_d_six".to_owned());
    run.phase = Phase::RoundEval;
    run.round_eval = Some(balatro_engine::run::RoundEval::default());
    run.cash_out().expect("这一回合在结算");
    assert!(run.free_reroll, "进商店时标记上");
    assert_eq!(run.reroll_cost(), 0.0, "重抽不要钱");

    let before = run.dollars;
    assert_eq!(run.pay_for_reroll().expect("重抽"), 0.0);
    assert_eq!(run.dollars, before, "钱没动");
    // 重抽本身还是记账的, 所以之后的涨价计数照走.
    assert_eq!(run.rerolls, 1);
}

/// 改上限的那几张小丑: 进场生效, **卖掉要撤回来**.
///
/// 进场与离场是成对的, 少写一边就会越攒越多 —— 所以这里每一张都买了再卖,
/// 确认买之前和卖之后的数值一致.
#[test]
fn limit_changing_jokers_apply_on_gain_and_undo_on_loss() {
    for key in ["j_juggler", "j_drunkard", "j_merry_andy"] {
        let mut run = ready_to_buy(50.0);
        let (hand_before, discards_before) = (run.hand_size(), run.discards_per_round);

        run.buy(&shop_card(key, 5.0)).expect("买下");
        let (hand_after, discards_after) = (run.hand_size(), run.discards_per_round);
        assert_ne!(
            (hand_after, discards_after),
            (hand_before, discards_before),
            "{key} 买进来该改点什么"
        );

        run.sell_joker(0).expect("卖掉");
        assert_eq!(
            (run.hand_size(), run.discards_per_round),
            (hand_before, discards_before),
            "{key} 卖掉之后要回到原样"
        );
    }

    // 各自改哪一项, 逐个确认.
    let mut run = ready_to_buy(50.0);
    let hand = run.hand_size();
    run.buy(&shop_card("j_juggler", 5.0)).expect("买下");
    assert_eq!(run.hand_size(), hand + 1, "杂耍师: 手牌加一");
    assert_eq!(run.discards_per_round, 2, "弃牌不动 (黄金赌注本来两次)");

    let mut run = ready_to_buy(50.0);
    let discards = run.discards_per_round;
    run.buy(&shop_card("j_drunkard", 5.0)).expect("买下");
    assert_eq!(run.discards_per_round, discards + 1, "醉汉: 弃牌加一");

    let mut run = ready_to_buy(50.0);
    let (hand, discards) = (run.hand_size(), run.discards_per_round);
    run.buy(&shop_card("j_merry_andy", 5.0)).expect("买下");
    assert_eq!(run.hand_size(), hand - 1, "快乐安迪: 手牌减一");
    assert_eq!(run.discards_per_round, discards + 3, "弃牌加三");
}

/// 特技演员与游吟诗人也改回合次数 (进场生效, 卖掉撤销).
///
/// 这两张的代价与收益都体现在次数上: 特技演员手牌 -2 换 +250 筹码, 游吟诗人出牌 -1 换手牌 +2.
#[test]
fn stuntman_and_troubadour_change_the_limits() {
    for key in ["j_stuntman", "j_troubadour"] {
        let mut run = ready_to_buy(50.0);
        let before = (run.hand_size(), run.hands_per_round);

        run.buy(&shop_card(key, 5.0)).expect("买下");
        assert_ne!(
            (run.hand_size(), run.hands_per_round),
            before,
            "{key} 买进来该改点什么"
        );

        run.sell_joker(0).expect("卖掉");
        assert_eq!(
            (run.hand_size(), run.hands_per_round),
            before,
            "{key} 卖掉之后要回到原样"
        );
    }

    // 各自的数值.
    let mut run = ready_to_buy(50.0);
    let (hand, hands) = (run.hand_size(), run.hands_per_round);
    run.buy(&shop_card("j_stuntman", 5.0)).expect("买下");
    assert_eq!(run.hand_size(), hand - 2, "特技演员: 手牌减二");
    assert_eq!(run.hands_per_round, hands, "出牌次数不动");

    let mut run = ready_to_buy(50.0);
    let (hand, hands) = (run.hand_size(), run.hands_per_round);
    run.buy(&shop_card("j_troubadour", 5.0)).expect("买下");
    assert_eq!(run.hand_size(), hand + 2, "游吟诗人: 手牌加二");
    assert_eq!(run.hands_per_round, hands - 1, "出牌次数减一");
}


/// 天文学家: 行星牌与天体包在他手里**不要钱**.
#[test]
fn astronomer_makes_planets_and_celestial_packs_free() {
    use balatro_engine::jokers::Joker;

    let spend = |with_astronomer: bool, key: &str, cost: f64| -> f64 {
        let mut run = ready_to_buy(20.0);
        if with_astronomer {
            run.jokers.push(Joker::new("j_astronomer").expect("有这张"));
        }
        let before = run.dollars;
        run.buy(&shop_card(key, cost)).expect("能买");
        before - run.dollars
    };

    // 行星牌: 有他就免费.
    assert_eq!(spend(true, "c_mercury", 3.0), 0.0, "行星牌免费");
    assert_eq!(spend(false, "c_mercury", 3.0), 3.0, "没他就照价");

    // 天体包同理, 而别的包照样收钱.
    assert_eq!(spend(true, "p_celestial_normal_1", 4.0), 0.0, "天体包免费");
    assert_eq!(spend(true, "p_arcana_normal_1", 4.0), 4.0, "别的包照价");

    // 塔罗不在他的范围内.
    assert_eq!(spend(true, "c_fool", 3.0), 3.0, "塔罗照价");
}

/// 摔角手: 把它**卖掉**就禁用当前的 Boss 盲注.
#[test]
fn luchador_disables_the_boss_when_sold() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, Phase};

    let mut run = ready_to_buy(20.0);
    run.boss_key = Some("bl_water".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_luchador").expect("有这张"));
    assert!(
        !run.blind.as_ref().expect("有盲注").disabled,
        "卖掉之前没禁用"
    );

    run.phase = Phase::Shop;
    run.sell_joker(0).expect("能卖");
    assert!(
        run.blind.as_ref().expect("有盲注").disabled,
        "卖掉摔角手之后 Boss 就被禁用了"
    );
}

/// 七上八下: 所有概率翻倍 —— 游戏是整张表乘二, 引擎里对应 `probability_scale`.
///
/// 概率判定散在好几处 (大麦克的烂掉、血石的掷骰...), 所以这里验的是**那个量本身**,
/// 而不是去统计"多掷几次能不能撞上" —— 后者不稳定, 也没法当回归测试.
#[test]
fn oops_all_sixes_doubles_and_undoes_the_probability_scale() {
    use balatro_engine::run::Phase;

    let mut run = ready_to_buy(20.0);
    assert_eq!(run.probability_scale, 1.0, "平时是正常概率");

    run.buy(&shop_card("j_oops", 4.0)).expect("能买");
    assert_eq!(run.probability_scale, 2.0, "拿到之后概率翻倍");

    run.phase = Phase::Shop;
    run.sell_joker(0).expect("能卖");
    assert_eq!(run.probability_scale, 1.0, "卖掉之后还回去");
}

/// 闪光: 在商店里每重掷一次涨 2 点倍率.
#[test]
fn flash_card_grows_with_every_shop_reroll() {
    use balatro_engine::jokers::Joker;

    let mut run = ready_to_buy(50.0);
    run.jokers.push(Joker::new("j_flash").expect("有这张"));
    assert_eq!(run.jokers[0].mult, 0.0, "刚开始是 0");

    run.reroll_shop().expect("能重掷");
    assert_eq!(run.jokers[0].mult, 2.0, "重掷一次涨 2");
    run.reroll_shop().expect("能重掷");
    assert_eq!(run.jokers[0].mult, 4.0, "再重掷一次涨到 4");

    // 没在商店里重掷不算 —— 这里只是把状态摆回出牌阶段, 倍率不该被清掉.
    assert_eq!(run.jokers[0].mult, 4.0, "倍率是攒出来的, 不会自己掉");
}

/// 商店里的**扑克牌**买下来要进**牌堆**, 不是小丑区, 也不是消耗区.
///
/// # 这条为什么必须有
///
/// 引擎原来只把货架上的东西分成"消耗牌"与"其余"两类, 于是买扑克牌会被当成小丑去查原型表,
/// 直接抛 `UnknownCard`. 而这是**开着魔法把戏券 / 幻象券时每一局都会遇到的操作**
/// (那两张券让商店的扑克牌格有货), 而且魔法把戏券**开局就是解锁的** ——
/// 也就是说这是一条"一买就崩"的路, 只是十九份录像里恰好没人买过.
///
/// 落点照游戏: `if c1.ability.set == 'Default' or c1.ability.set == 'Enhanced' then ... G.deck:emplace(c1)`.
#[test]
fn buying_a_playing_card_puts_it_into_the_deck() {
    let mut run = ready_to_buy(99.0);
    let deck_before = run.deck.len();
    let jokers_before = run.jokers.len();
    let consumables_before = run.consumables.len();

    run.buy(&shop_card("C_T", 1.0))
        .expect("扑克牌要能买下来 (以前这条路会抛 UnknownCard)");

    assert_eq!(run.deck.len(), deck_before + 1, "牌堆多一张");
    assert_eq!(run.jokers.len(), jokers_before, "不该进小丑区");
    assert_eq!(run.consumables.len(), consumables_before, "不该进消耗区");
    assert_eq!(run.dollars, 98.0, "该扣钱");

    // 进的是**牌堆底** (下标 0 = 游戏的下标 1), 因为牌堆是"插头部, 抽尾部".
    assert_eq!(
        run.deck[0].card.key(),
        "C_T",
        "买来的牌该落在牌堆底 (下标 0)"
    );
    // 新的牌要拿一个**新的建牌序号**, 否则它插进牌堆后的相对次序会跟游戏不同.
    assert!(
        run.deck[0].card.sort_id > 0,
        "买来的牌该有自己的建牌序号, 现在是 {}",
        run.deck[0].card.sort_id
    );
}

/// 买来的扑克牌要**带着它的强化与版本**, 不能把这两项丢在半路上.
///
/// 货架那张牌的两项是铺货时掷好的 (`create_card_for_shop`), 买下来只是把它挪进牌堆 ——
/// 中途重新掷一次或者直接丢掉, 那张牌就"少了它该有的样子", 而且不报错.
#[test]
fn a_bought_playing_card_keeps_its_enhancement_and_edition() {
    use balatro_engine::cards::Edition;

    let mut run = ready_to_buy(99.0);
    let mut card = shop_card("C_6", 1.0);
    card.enhancement = balatro_engine::cards::Enhancement::from_key("m_mult");
    card.edition = Some(Edition::Foil);
    run.buy(&card).expect("能买下来");

    assert_eq!(
        run.deck[0].enhancement,
        balatro_engine::cards::Enhancement::from_key("m_mult"),
        "强化要在买下来之后还在"
    );
    assert_eq!(run.deck[0].edition, Some(Edition::Foil), "版本要在买下来之后还在");
}
