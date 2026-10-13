//! 动态被动的回归只通过实际进出场与 Boss 回调切换状态.
mod common;

use balatro_engine::cards::Edition;
use balatro_engine::jokers::Joker;
use balatro_engine::run::{BlindKind, Phase, RunState};
use balatro_engine::run::shop::{Shop, ShopCard};
use balatro_engine::scoring::{BackEffect, EvalEnv};

fn card(key: &str, cost: f64) -> ShopCard {
    ShopCard { sort_id: 0, key: key.into(), edition: None, eternal: false, perishable: false,
        rental: false, couponed: false, enhancement: None, todo: None, cost }
}

fn ready(seed: &str) -> RunState {
    let mut run = RunState::new(seed, 1);
    run.start_run();
    run.dollars = 100.0;
    run
}

fn stock(run: &mut RunState, free: bool) {
    run.shop = Some(Shop { jokers: vec![card("c_mercury", if free { 0.0 } else { 3.0 }), card("c_fool", 3.0)],
        vouchers: Vec::new(),
        packs: vec![card("p_celestial_normal_1", if free { 0.0 } else { 4.0 })] });
}

fn assert_prices(run: &RunState, free: bool) {
    let shop = run.shop.as_ref().unwrap();
    assert_eq!(shop.jokers[0].cost, if free { 0.0 } else { 3.0 });
    assert_eq!(shop.packs[0].cost, if free { 0.0 } else { 4.0 });
    assert_eq!(shop.jokers[1].cost, 3.0);
}

fn heart(run: &mut RunState) {
    run.blind_on_deck = BlindKind::Boss;
    run.boss_key = Some("bl_final_heart".into());
    common::place_blind(run);
    run.blind.as_mut().unwrap().chips = 1e12;
    run.hands_left = 20;
}

fn play_one(run: &mut RunState) {
    run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
}

#[test]
fn multiple_chaos_reset_each_active_body_not_copied_targets() {
    let mut run = ready("chaos-count");
    for key in ["j_blueprint", "j_chaos", "j_chaos"] {
        run.add_joker(Joker::new(key).unwrap());
    }
    common::place_blind(&mut run);
    assert_eq!(run.free_rerolls, 2);
    // 已使用次数只影响当前回合, 下一盲注恢复每张本体的一次.
    run.phase = Phase::Shop;
    run.pay_for_reroll().unwrap();
    assert_eq!(run.free_rerolls, 1);
    common::place_blind(&mut run);
    assert_eq!(run.free_rerolls, 2);
}

#[test]
fn spent_chaos_loss_clamps_current_and_new_gain_starts_at_one() {
    let mut run = ready("chaos-spent");
    run.phase = Phase::Shop;
    let slot = run.add_joker(Joker::new("j_chaos").unwrap());
    assert_eq!(run.pay_for_reroll().unwrap(), 0.0);
    assert_eq!(run.free_rerolls, 0);
    run.sell_joker(slot).unwrap();
    assert_eq!(run.free_rerolls, 0);
    run.add_joker(Joker::new("j_chaos").unwrap());
    assert_eq!(run.free_rerolls, 1);
}

#[test]
fn chaos_debuff_and_restoration_apply_once_per_transition() {
    let mut run = ready("chaos-heart");
    run.add_joker(Joker::new("j_chaos").unwrap());
    heart(&mut run);
    assert!(run.jokers[0].debuffed);
    assert_eq!(run.free_rerolls, 0);
    // 唯一候选再次被选中时先恢复再削弱, 不可累积多撤销一次.
    play_one(&mut run);
    assert!(run.jokers[0].debuffed);
    assert_eq!(run.free_rerolls, 0);
    run.add_joker(Joker::new("j_chicot").unwrap());
    assert!(!run.jokers[0].debuffed);
    assert_eq!(run.free_rerolls, 1);
}

#[test]
fn astronomer_prices_follow_membership_after_gain_and_loss() {
    let mut run = ready("astronomer-members");
    run.phase = Phase::Shop;
    stock(&mut run, false);
    run.buy(&card("j_astronomer", 8.0)).unwrap();
    assert_prices(&run, true);
    run.add_joker(Joker::new("j_astronomer").unwrap());
    run.sell_joker(0).unwrap();
    assert_prices(&run, true);
    run.sell_joker(0).unwrap();
    assert_prices(&run, false);
}

#[test]
fn astronomer_prices_refresh_after_heart_debuff_and_restore() {
    let mut run = ready("astronomer-heart");
    run.add_joker(Joker::new("j_astronomer").unwrap());
    stock(&mut run, true);
    heart(&mut run);
    assert!(run.jokers[0].debuffed);
    assert_prices(&run, false);
    run.add_joker(Joker::new("j_chicot").unwrap());
    assert!(!run.jokers[0].debuffed);
    assert_prices(&run, true);
}

#[test]
fn discard_passives_clamp_remaining_but_reverse_full_round_default() {
    for (key, delta) in [("j_drunkard", 1), ("j_merry_andy", 3)] {
        let mut run = ready(key);
        run.add_joker(Joker::new(key).unwrap());
        run.add_joker(Joker::new("j_joker").unwrap());
        heart(&mut run);
        // 两张有效候选轮流被选, 先走到目标小丑处于有效的稳定局面.
        if run.jokers[0].debuffed { play_one(&mut run); }
        assert!(!run.jokers[0].debuffed);
        assert_eq!(run.discards_per_round, 3 + delta);
        run.discards_left = 0;
        play_one(&mut run);
        assert!(run.jokers[0].debuffed);
        assert_eq!(run.discards_left, 0, "{key}");
        assert_eq!(run.discards_per_round, 3, "{key}");
        play_one(&mut run);
        assert!(!run.jokers[0].debuffed);
        assert_eq!(run.discards_left, delta, "{key}");
        assert_eq!(run.discards_per_round, 3 + delta, "{key}");
    }
}

#[test]
fn negative_slot_survives_debuff_and_recovers_without_double_increment() {
    let mut run = ready("negative-heart");
    let mut joker = Joker::new("j_joker").unwrap();
    joker.edition = Some(Edition::Negative);
    run.add_joker(joker);
    assert_eq!(run.joker_capacity(), 6);
    heart(&mut run);
    assert!(run.jokers[0].debuffed);
    assert_eq!(run.joker_capacity(), 6);
    play_one(&mut run);
    assert_eq!(run.joker_capacity(), 6);
    run.add_joker(Joker::new("j_chicot").unwrap());
    assert!(!run.jokers[0].debuffed);
    assert_eq!(run.joker_capacity(), 6);
}

#[test]
fn heart_hand_size_increase_refills_only_the_final_stable_target() {
    // 游戏先进入 SELECTING_HAND 才运行 drawn_to_hand, 之后 CardArea.handle_card_limit
    // 在上限变大时补牌. 降低上限则不丢弃现有手牌.
    let mut run = ready("stuntman-heart");
    run.add_joker(Joker::new("j_stuntman").unwrap());
    heart(&mut run);
    assert!(run.jokers[0].debuffed);
    assert_eq!(run.hand_size(), 8);
    assert_eq!(run.hand.len(), 8);
    let mut juggler = ready("juggler-heart");
    juggler.add_joker(Joker::new("j_juggler").unwrap());
    heart(&mut juggler);
    assert_eq!(juggler.hand_size(), 8);
    assert_eq!(juggler.hand.len(), 9);
    juggler.add_joker(Joker::new("j_chicot").unwrap());
    assert_eq!(juggler.hand_size(), 9);
    assert_eq!(juggler.hand.len(), 9);
}
