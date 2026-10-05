//! 优惠券买下之后的效果.
//!
//! 券不进持有区, 买下的那一刻就改规则. 这里验的是"记下买了哪张券"之外的那一半 ——
//! 只记不施加的话, 券就是白买的.

mod common;

use balatro_engine::run::shop::ShopCard;
use balatro_engine::run::{Phase, RunState};

/// 造一张带价签的券.
fn voucher(key: &str) -> ShopCard {
    ShopCard {
        key: key.to_owned(),
        edition: None,
        eternal: false,
        perishable: false,
        rental: false,
        couponed: false,
        enhancement: None,
        todo: None,
        // 券的价签不影响它买下之后的效果, 给个买得起的数就行.
        cost: 10.0,
    }
}

fn ready() -> RunState {
    let mut run = common::aleeb_run();
    run.phase = Phase::Shop;
    run.dollars = 100.0;
    run
}

#[test]
fn buying_a_voucher_changes_the_rules() {
    // 抓手: 每回合多一次出牌.
    let mut run = ready();
    let hands = run.hands_per_round;
    run.buy(&voucher("v_grabber")).expect("买下");
    assert_eq!(run.hands_per_round, hands + 1, "抓手多加一次出牌");
    assert!(run.used_vouchers.contains("v_grabber"), "也记下了买过哪张");

    // 常弃常新: 每回合多一次弃牌.
    let mut run = ready();
    let discards = run.discards_per_round;
    run.buy(&voucher("v_wasteful")).expect("买下");
    assert_eq!(run.discards_per_round, discards + 1);

    // 油漆刷: 手牌上限加一.
    let mut run = ready();
    let hand = run.hand_size();
    run.buy(&voucher("v_paint_brush")).expect("买下");
    assert_eq!(run.hand_size(), hand + 1);

    // 水晶球: 多一个消耗牌格子.
    let mut run = ready();
    run.buy(&voucher("v_crystal_ball")).expect("买下");
    assert_eq!(run.base_consumable_slots, 3);

    // 反物质: 多一个小丑格子.
    let mut run = ready();
    run.buy(&voucher("v_antimatter")).expect("买下");
    assert_eq!(run.base_joker_slots, 6);

    // 清仓特卖: 折扣 25%.
    let mut run = ready();
    run.buy(&voucher("v_clearance_sale")).expect("买下");
    assert_eq!(run.discount_percent, 25.0);

    // 种子基金: 利息本金上限提到 50.
    let mut run = ready();
    run.buy(&voucher("v_seed_money")).expect("买下");
    assert_eq!(run.interest_cap, 50.0);

    // 多次重掷: 重抽基准价从 5 降到 3.
    let mut run = ready();
    run.buy(&voucher("v_reroll_surplus")).expect("买下");
    assert_eq!(run.reroll_base_cost, 3.0);
}

/// 空白券什么都不做 (它只是反物质的前置) —— 别"顺手"给它加个小丑格子.
#[test]
fn blank_voucher_does_nothing_but_is_recorded() {
    let mut run = ready();
    let before = (
        run.base_joker_slots,
        run.hand_size(),
        run.hands_per_round,
        run.discards_per_round,
    );
    run.buy(&voucher("v_blank")).expect("买下");
    assert_eq!(
        (
            run.base_joker_slots,
            run.hand_size(),
            run.hands_per_round,
            run.discards_per_round
        ),
        before,
        "空白券不改任何东西"
    );
    assert!(run.used_vouchers.contains("v_blank"));
}

/// 改权重的券会让商店换货: 塔罗商人把塔罗的权重提到 `4 x 2.4`.
#[test]
fn rate_vouchers_change_the_shop_rates() {
    use balatro_engine::run::voucher::rates_of;

    let mut run = ready();
    assert_eq!(rates_of(&run).tarot, 4.0, "默认塔罗权重是 4");

    run.buy(&voucher("v_tarot_merchant")).expect("买下");
    let rates = rates_of(&run);
    assert!(
        (rates.tarot - 9.6).abs() < 1e-9,
        "塔罗商人把权重提到 9.6, 实际 {}",
        rates.tarot
    );

    // 星球商人改的是另一项.
    let mut run = ready();
    run.buy(&voucher("v_planet_merchant")).expect("买下");
    let rates = rates_of(&run);
    assert!((rates.planet - 9.6).abs() < 1e-9, "星球权重");
    assert_eq!(rates.tarot, 4.0, "塔罗那条不动");

    // 魔术: 商店开始卖扑克牌.
    let mut run = ready();
    assert_eq!(rates_of(&run).playing_card, 0.0, "默认不卖扑克牌");
    run.buy(&voucher("v_magic_trick")).expect("买下");
    assert_eq!(rates_of(&run).playing_card, 4.0);

    // 打磨: 出版本的频率从 1 提到 2.
    let mut run = ready();
    assert_eq!(run.edition_rate, 1.0);
    run.buy(&voucher("v_hone")).expect("买下");
    assert_eq!(run.edition_rate, 2.0);
}

/// 库存过剩让货架多摆一件, 而且**买完之后铺的货**才体现出来.
#[test]
fn overstock_adds_a_shelf_slot() {
    let mut run = ready();
    assert_eq!(run.shop_size_bonus, 0);

    run.buy(&voucher("v_overstock_norm")).expect("买下");
    assert_eq!(run.shop_size_bonus, 1);

    let shop = balatro_engine::run::shop::Shop::restock(&mut run);
    assert_eq!(shop.jokers.len(), 3, "默认两件加一件");

    // 再买一次加强版: 一共三件.
    let mut run = ready();
    run.buy(&voucher("v_overstock_norm")).expect("买下");
    run.buy(&voucher("v_overstock_plus")).expect("买下");
    let shop = balatro_engine::run::shop::Shop::restock(&mut run);
    assert_eq!(shop.jokers.len(), 4);
}

/// 象形文字把底注拉回一级, 代价是少一次出牌.
#[test]
fn hieroglyph_trades_a_hand_for_an_ante() {
    let mut run = ready();
    run.ante = 3;
    let hands = run.hands_per_round;
    run.buy(&voucher("v_hieroglyph")).expect("买下");
    assert_eq!(run.ante, 2, "底注回退一级");
    assert_eq!(run.hands_per_round, hands - 1, "少一次出牌");

    // 岩画同理, 代价换成弃牌.
    let mut run = ready();
    run.ante = 3;
    let discards = run.discards_per_round;
    run.buy(&voucher("v_petroglyph")).expect("买下");
    assert_eq!(run.ante, 2);
    assert_eq!(run.discards_per_round, discards - 1, "少一次弃牌");
}
