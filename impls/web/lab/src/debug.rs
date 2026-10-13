//! 白名单状态修改, 先验证全部字段再写入副本.
use std::collections::BTreeMap;
use engine::run::RunState;
use crate::error::{Error, Result};

pub fn values(run: &RunState) -> BTreeMap<String, f64> {
    BTreeMap::from([
        ("dollars".into(), run.dollars), ("chips".into(), run.chips),
        ("hands_left".into(), run.hands_left as f64),
        ("discards_left".into(), run.discards_left as f64),
        ("hands_per_round".into(), run.hands_per_round as f64),
        ("discards_per_round".into(), run.discards_per_round as f64),
        ("hand_size_bonus".into(), run.hand_size_bonus as f64),
        ("base_joker_slots".into(), run.base_joker_slots as f64),
        ("base_consumable_slots".into(), run.base_consumable_slots as f64),
    ])
}

pub fn apply(run: &mut RunState, changes: &BTreeMap<String, f64>) -> Result<String> {
    if changes.is_empty() { return Err(Error::bad("请指定要修改的字段")); }
    for (key, &value) in changes {
        let (min, max, integer) = match key.as_str() {
            "dollars" => (-1e12, 1e12, false),
            "chips" => (0.0, 1e300, false),
            "hands_left" | "discards_left" | "hands_per_round" | "discards_per_round" => (0.0, 999.0, true),
            "base_joker_slots" | "base_consumable_slots" => (0.0, 100.0, true),
            "hand_size_bonus" => (-7.0, 100.0, true),
            _ => return Err(Error::bad(format!("不可修改的字段: {key}"))),
        };
        if !value.is_finite() || value < min || value > max || (integer && value.fract() != 0.0) {
            return Err(Error::bad(format!("{key} 必须在 {min}..{max} 范围内{}", if integer { "且为整数" } else { "" })));
        }
    }
    let old = values(run);
    for (key, &value) in changes {
        match key.as_str() {
            "dollars" => run.dollars = value,
            "chips" => run.chips = value,
            "hands_left" => run.hands_left = value as i64,
            "discards_left" => run.discards_left = value as i64,
            "hands_per_round" => run.hands_per_round = value as i64,
            "discards_per_round" => run.discards_per_round = value as i64,
            "hand_size_bonus" => run.hand_size_bonus = value as i64,
            "base_joker_slots" => run.base_joker_slots = value as usize,
            "base_consumable_slots" => run.base_consumable_slots = value as usize,
            _ => unreachable!("已经验证修改字段"),
        }
    }
    Ok(changes.iter().map(|(k, v)| format!("{k}: {} -> {v}", old[k])).collect::<Vec<_>>().join("\n"))
}
