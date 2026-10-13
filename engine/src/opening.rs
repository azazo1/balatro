//! CLI 与 Web 共用的开局参数, 不依赖图形或 HTTP 库.

use std::collections::{HashMap, hash_map::RandomState};
use std::hash::{BuildHasher, Hasher};

use crate::data::{catalog::Catalog, json::Json};
use crate::run::RunState;

pub const SEED_ALPHABET: &[u8] = b"123456789ABCDEFGHIJKLMNPQRSTUVWXYZ";

pub const STAKES: [&str; 8] = [
    "WHITE", "RED", "GREEN", "BLACK", "BLUE", "PURPLE", "ORANGE", "GOLD",
];
pub const DECKS: [&str; 15] = [
    "b_red", "b_blue", "b_yellow", "b_green", "b_black", "b_magic", "b_nebula",
    "b_ghost", "b_abandoned", "b_checkered", "b_zodiac", "b_painted", "b_anaglyph",
    "b_plasma", "b_erratic",
];
const UDA_ALL: &str = include_str!("../data/uda-all.json");

pub fn stake_of(name: &str) -> Result<i64, String> {
    let stake = STAKES.iter().position(|s| s.eq_ignore_ascii_case(name))
        .map(|i| i as i64 + 1).or_else(|| name.parse().ok());
    stake.filter(|s| (1..=8).contains(s))
        .ok_or_else(|| "赌注必须是 1..8 或 WHITE..GOLD".to_owned())
}

pub fn deck_of(name: &str) -> Result<String, String> {
    let lower = name.to_ascii_lowercase();
    let key = if lower.starts_with("b_") { lower } else { format!("b_{lower}") };
    if DECKS.contains(&key.as_str()) && Catalog::get().record(&key).is_some() {
        Ok(key)
    } else {
        Err(format!("不支持的牌组: {name}"))
    }
}

pub fn profile_uda(profile: &str) -> Result<HashMap<String, String>, String> {
    match profile.to_ascii_lowercase().as_str() {
        "new" => Ok(HashMap::new()),
        "all" => {
            let parsed = Json::parse(UDA_ALL).map_err(|e| format!("内置解锁档损坏: {e}"))?;
            let Some(Json::Object(entries)) = parsed.get("snapshot").and_then(|s| s.get("uda")) else {
                return Err("内置解锁档缺少 uda".to_owned());
            };
            Ok(entries.iter().filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_owned()))).collect())
        }
        _ => Err("解锁档必须是 all 或 new".to_owned()),
    }
}

/// 保留手动种子的字节序列, 不静默改写大小写.
pub fn create(seed: &str, deck: &str, stake: i64, profile: &str) -> Result<RunState, String> {
    if seed.is_empty() || seed.len() > 128 || seed.chars().any(char::is_control) {
        return Err("种子须为 1..128 字节且不能含控制字符".to_owned());
    }
    if !(1..=8).contains(&stake) {
        return Err("赌注必须在 1..8 之间".to_owned());
    }
    let mut run = RunState::new(seed, stake).with_deck(&deck_of(deck)?).with_uda(profile_uda(profile)?);
    run.start_run();
    Ok(run)
}

/// 与游戏一致的八位种子形状, 使用标准库提供的系统熵.
pub fn generate_seed() -> String {
    let mut hasher = RandomState::new().build_hasher();
    hasher.write_u64(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64).unwrap_or(0));
    let mut state = hasher.finish() | 1;
    (0..8).map(|_| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        SEED_ALPHABET[(state % SEED_ALPHABET.len() as u64) as usize] as char
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_opening_without_exiting_the_process() {
        assert_eq!(deck_of("PLASMA").unwrap(), "b_plasma");
        assert_eq!(stake_of("gold").unwrap(), 8);
        assert!(stake_of("9").is_err());
        assert!(deck_of("unknown").is_err());
        assert!(create("", "RED", 1, "all").is_err());
        assert!(profile_uda("all").unwrap().len() > 300);
        assert!(profile_uda("new").unwrap().is_empty());
        let seed = generate_seed();
        assert_eq!(seed.len(), 8);
        assert!(seed.bytes().all(|b| b"123456789ABCDEFGHIJKLMNPQRSTUVWXYZ".contains(&b)));
    }
}
