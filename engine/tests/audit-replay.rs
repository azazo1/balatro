//! 回放校验只容忍游戏自身容忍的显示差异, 不能吞掉规则差异.

use balatro_engine::data::json::Json;
use balatro_engine::replay::{check, digest_diff, translated_action};

#[test]
fn booster_art_and_old_effect_names_are_display_only() {
    let old = "state=SHOP money=5 hand=S_3~bonus jokers=j_jolly~type mult!e consumables=c_sun~suit conversion shop= packs=p_buffoon_normal_1";
    let current = "state=SHOP money=5 hand=S_3~bonus jokers=j_jolly!e consumables=c_sun shop= packs=p_buffoon_normal_2";
    assert!(digest_diff(old, current, true).is_none());
    assert!(digest_diff(old, &current.replace("money=5", "money=6"), true).is_some());
    assert!(digest_diff(old, &current.replace("j_jolly!e", "j_jolly"), true).is_some());
    assert!(digest_diff(old, &current.replace("S_3~bonus", "S_3~mult"), true).is_some());
    assert!(digest_diff(old, &current.replace("buffoon_normal", "buffoon_jumbo"), true).is_some());
}

#[test]
fn strict_comparison_detects_extra_fields_but_sparse_mode_does_not() {
    assert!(digest_diff("money=3", "money=3 hand=S_2", false).is_none());
    assert!(digest_diff("money=3", "money=3 hand=S_2", true).is_some());
    assert!(digest_diff("money=3 hand=", "money=3", false).is_some());
}

#[test]
fn manual_use_maps_targets_to_the_actual_consumable_cards_parameter() {
    let step = Json::parse(r#"{"method":"press","params":{"fn":"use_card","area":"consumeables","index":1,"targets":[2,4]}}"#).unwrap();
    let translated = translated_action(&step).unwrap();
    assert_eq!(translated.get("method").and_then(Json::as_str), Some("use"));
    let params = translated.get("params").unwrap();
    assert_eq!(params.get("cards").unwrap(), &Json::Array(vec![Json::Number(2.0), Json::Number(4.0)]));
    assert_eq!(params.get("consumable").and_then(Json::as_f64), Some(1.0));
}

#[test]
fn local_drag_and_endpoint_rearrange_have_different_phase_gates() {
    let header = Json::parse(r#"{"seed":"REORDER","deck":"RED","stake":"WHITE","uda":{}}"#).unwrap();
    let steps = [
        Json::parse(r#"{"method":"reorder","params":{"area":"jokers","order":[]},"ok":true}"#).unwrap(),
        Json::parse(r#"{"method":"rearrange","params":{"jokers":[]},"ok":false}"#).unwrap(),
    ];
    let report = check(&header, &steps, false);
    assert!(report.failure.is_none(), "{:?}", report.failure);
    assert_eq!(report.unverified_actions, 1);
    assert_eq!(report.matched_refusals, 1);
}

#[test]
fn local_reorder_and_unknown_buttons_do_not_become_silent_noops() {
    let step = Json::parse(r#"{"method":"reorder","params":{"area":"jokers","order":[1,0]}}"#).unwrap();
    let translated = translated_action(&step).unwrap();
    assert_eq!(translated.get("method").and_then(Json::as_str), Some("rearrange"));
    assert!(translated.get("params").unwrap().get("jokers").is_some());
    let unknown = Json::parse(r#"{"method":"press","params":{"fn":"unknown","area":"jokers"}}"#).unwrap();
    assert!(translated_action(&unknown).is_err());
}
