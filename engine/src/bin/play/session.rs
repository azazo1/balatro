//! 一局的开局参数与存档进度: 引擎侧与游戏侧都要用的那份映射.

use std::collections::HashMap;

use balatro_engine::data::json::Json;

/// 存档进度表 (`snapshot.uda`) 的内置全解锁档.
///
/// 它记的是"这个档解锁了什么", 与种子 / 牌组 / 赌注都无关. 少了它, 候选池里会多出没解锁的
/// 占位格子, 抽出来的东西整体偏 —— 所以开局必须带上. 这份是从真实存档里取的快照, 结构与
/// 录像的 `snapshot.uda` 同构, 于是解析只有一条路径.
const UDA_ALL: &str = include_str!("../../../data/uda-all.json");

/// 赌注名转档位. 与回放文件里的 `stake` 一致.
pub fn stake_of(name: &str) -> i64 {
    for (index, candidate) in
        ["WHITE", "RED", "GREEN", "BLACK", "BLUE", "PURPLE", "ORANGE", "GOLD"]
            .iter()
            .enumerate()
    {
        if candidate.eq_ignore_ascii_case(name) {
            return index as i64 + 1;
        }
    }
    name.parse().expect("赌注要么是档位数字, 要么是 WHITE..GOLD")
}

/// 牌组名转内部键: 大小写不敏感, 自动补 `b_` 前缀.
pub fn deck_of(name: &str) -> String {
    if name.starts_with("b_") {
        name.to_owned()
    } else {
        format!("b_{}", name.to_lowercase())
    }
}

/// 内置的解锁档, 由 `--uda` 选.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Profile {
    /// 全解锁: 想跑到高底注就用这份, 候选池里没有未解锁的占位格子.
    All,
    /// 新存档: 一项都不额外解锁, 一切按原型的初始值.
    New,
}

impl Profile {
    /// 解析 `--uda` 的取值, 大小写不敏感.
    pub fn parse(name: &str) -> Profile {
        match name.to_ascii_lowercase().as_str() {
            "all" => Profile::All,
            "new" => Profile::New,
            other => {
                eprintln!("--uda 只支持 all 或 new, 收到 {other}.");
                std::process::exit(2);
            }
        }
    }

    /// 档名, 开局时打出来说明用的是哪一份.
    fn label(self) -> &'static str {
        match self {
            Profile::All => "全解锁 (内置)",
            Profile::New => "新存档 (内置, 只有原型初始就解锁的内容)",
        }
    }

    fn uda(self) -> HashMap<String, String> {
        match self {
            // 空表就是新存档: 引擎对没记过的原型按它自己的初始值算.
            Profile::New => HashMap::new(),
            Profile::All => uda_of_snapshot(UDA_ALL, "内置的全解锁档"),
        }
    }
}

/// 环境变量指定的原始录像. 没设就是 `None`.
fn template_text() -> Option<String> {
    let path = std::env::var_os("BALATRO_REPLAY_TEMPLATE").map(std::path::PathBuf::from)?;
    Some(
        std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("读不到模板 {}: {error}", path.display())),
    )
}

/// 本局用的存档进度: 给了原始录像就用录像里的, 否则用内置档.
pub fn uda_from(profile: Profile) -> HashMap<String, String> {
    let Some(text) = template_text() else {
        eprintln!("解锁档: {}", profile.label());
        return profile.uda();
    };
    eprintln!("解锁档: 取自 BALATRO_REPLAY_TEMPLATE 指的原始录像");
    uda_of_snapshot(&text, "模板录像")
}

/// 从 `{"snapshot":{"uda":{...}}}` 这个结构里取出存档进度.
fn uda_of_snapshot(text: &str, what: &str) -> HashMap<String, String> {
    let parsed = Json::parse(text).unwrap_or_else(|error| panic!("{what}解析失败: {error}"));
    match parsed.get("snapshot").and_then(|snapshot| snapshot.get("uda")) {
        Some(Json::Object(entries)) => entries
            .iter()
            .filter_map(|(key, value)| value.as_str().map(|flags| (key.clone(), flags.to_owned())))
            .collect(),
        other => panic!("{what}的 uda 应当是个对象, 实际 {other:?}"),
    }
}

/// 模板录像的原文. 导出回放时要照抄它的 `snapshot` 与版本号 —— 那是 LÖVE 自己的存档格式,
/// 引擎既造不出也不该造, 所以这一步必须有一份原始录像.
pub fn template_raw() -> String {
    template_text().unwrap_or_else(|| {
        panic!("导出回放需要一份原始录像作为模板: 用 BALATRO_REPLAY_TEMPLATE 指定一份")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_both_profiles_case_insensitively() {
        assert_eq!(Profile::parse("all"), Profile::All);
        assert_eq!(Profile::parse("NEW"), Profile::New);
    }

    #[test]
    fn new_profile_unlocks_nothing_extra() {
        assert!(Profile::New.uda().is_empty());
    }

    #[test]
    fn all_profile_carries_the_whole_unlocked_snapshot() {
        let uda = Profile::All.uda();
        assert!(uda.len() > 300, "内置档应当是一份完整快照, 实际 {} 项", uda.len());
        // 跑到高底注要靠这几张, 缺一个候选池就会少东西.
        for key in ["j_blueprint", "j_brainstorm", "j_baron", "j_mime", "j_perkeo"] {
            let flags = uda.get(key).unwrap_or_else(|| panic!("内置档缺 {key}"));
            assert!(flags.contains('u'), "{key} 在内置档里应当是解锁的");
        }
    }
}
