//! 动作适配层必须与游戏端点使用相同参数语义.

use balatro_engine::agent::action;
use balatro_engine::data::json::Json;
use balatro_engine::run::consumable::Consumable;
use balatro_engine::run::shop::{Shop, ShopCard};
use balatro_engine::run::{Phase, RunState};
use balatro_engine::scoring::{EvalEnv, PokerHand};

fn shop_card(key: &str) -> ShopCard {
    ShopCard { sort_id: 0, key: key.to_owned(), cost: 3.0, edition: None, eternal: false,
        perishable: false, rental: false, couponed: false, enhancement: None, todo: None }
}

fn in_shop() -> RunState {
    let mut run = RunState::new("ACTIONPARITY", 1);
    run.start_run();
    run.phase = Phase::Shop;
    run.dollars = 50.0;
    let mut card = shop_card("c_mercury");
    card.cost = 3.0;
    run.shop = Some(Shop {
        jokers: vec![card],
        vouchers: vec![shop_card("v_grabber"), shop_card("v_wasteful")],
        packs: Vec::new(),
    });
    run
}

#[test]
fn buy_and_use_bypasses_full_consumable_slots() {
    for method in [r#"{"method":"buy","params":{"card":0,"use":true}}"#,
                   r#"{"method":"buy_and_use","params":{"card":0}}"#] {
        let mut run = in_shop();
        run.consumables = vec![Consumable::plain("c_sun"), Consumable::plain("c_moon")];
        let before = run.hands.get(PokerHand::Pair).level;
        action::apply(&Json::parse(method).unwrap(), &mut run, &EvalEnv::default()).unwrap();
        assert_eq!(run.consumables.len(), 2);
        assert_eq!(run.hands.get(PokerHand::Pair).level, before + 1);
        assert_eq!(run.dollars, 47.0);
        assert!(run.shop.as_ref().unwrap().jokers.is_empty());
    }
}

#[test]
fn voucher_index_selects_the_second_voucher() {
    let mut run = in_shop();
    let before = run.discards_per_round;
    action::apply(&Json::parse(r#"{"method":"buy","params":{"voucher":1}}"#).unwrap(),
        &mut run, &EvalEnv::default()).unwrap();
    assert_eq!(run.discards_per_round, before + 1);
    assert!(run.used_vouchers.contains("v_wasteful"));
    assert!(!run.used_vouchers.contains("v_grabber"));
}

#[test]
fn voucher_index_can_address_the_third_offer_then_compacts() {
    let mut run = in_shop();
    run.shop.as_mut().unwrap().vouchers = vec![
        shop_card("v_blank"), shop_card("v_grabber"), shop_card("v_wasteful"),
    ];
    let step = Json::parse(r#"{"method":"buy","params":{"voucher":2}}"#).unwrap();
    action::apply(&step, &mut run, &EvalEnv::default()).unwrap();
    assert_eq!(run.shop.as_ref().unwrap().vouchers.len(), 2);
    assert_eq!(run.dollars, 47.0);
    let first = Json::parse(r#"{"method":"buy","params":{"voucher":0}}"#).unwrap();
    action::apply(&first, &mut run, &EvalEnv::default()).unwrap();
    action::apply(&first, &mut run, &EvalEnv::default()).unwrap();
    assert!(run.shop.as_ref().unwrap().vouchers.is_empty());
    let before = run.dollars;
    assert!(action::apply(&first, &mut run, &EvalEnv::default()).is_err());
    assert_eq!(run.dollars, before);
}

#[test]
fn missing_or_ambiguous_buy_target_is_rejected_without_mutation() {
    for params in ["{}", r#"{"card":0,"voucher":0}"#, r#"{"voucher":5}"#, r#"{"voucher":0,"use":true}"#] {
        let mut run = in_shop();
        let action = Json::parse(&format!(r#"{{"method":"buy","params":{params}}}"#)).unwrap();
        let dollars = run.dollars;
        assert!(action::apply(&action, &mut run, &EvalEnv::default()).is_err());
        assert_eq!(run.dollars, dollars);
        assert_eq!(run.shop.as_ref().unwrap().jokers.len(), 1);
        assert!(run.used_vouchers.is_empty());
    }
}

#[test]
fn rearranging_obeys_the_endpoint_phase_and_single_area_guards() {
    let empty_jokers = Json::parse(r#"{"method":"rearrange","params":{"jokers":[]}}"#).unwrap();
    for phase in [Phase::BlindSelect, Phase::RoundEval, Phase::GameOver] {
        let mut run = in_shop();
        run.phase = phase;
        assert!(action::apply(&empty_jokers, &mut run, &EvalEnv::default()).is_err());
        assert_eq!(run.phase, phase);
    }
    for params in ["{}", r#"{"jokers":[],"consumables":[]}"#, r#"{"hand":[]}"#] {
        let mut run = in_shop();
        let step = Json::parse(&format!(r#"{{"method":"rearrange","params":{params}}}"#)).unwrap();
        assert!(action::apply(&step, &mut run, &EvalEnv::default()).is_err());
    }
    let mut run = in_shop();
    action::apply(&empty_jokers, &mut run, &EvalEnv::default()).unwrap();
}

#[test]
fn malformed_or_unknown_action_is_an_error_not_a_silent_success() {
    let mut run = in_shop();
    for value in ["{}", r#"{"method":"not_a_method"}"#] {
        assert!(action::apply(&Json::parse(value).unwrap(), &mut run, &EvalEnv::default()).is_err());
    }
}
