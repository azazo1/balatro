//! 一局的开局参数与存档进度: 引擎侧与游戏侧都要用的那份映射.

use std::collections::HashMap;

use balatro_engine::data::json::Json;

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

/// 存档进度表 (`snapshot.uda`) 的模板录像.
///
/// 它记的是"这个档解锁了什么", 与种子 / 牌组 / 赌注都无关. 少了它, 候选池里会多出没解锁的
/// 占位格子, 抽出来的东西整体偏 —— 所以开局必须带上.
pub const TEMPLATE: &str = "../recordings/20261003-222131-ALEEB/20261003-222131-ALEEB.replay.json";

fn template_text() -> String {
    let path = std::env::var_os("BALATRO_REPLAY_TEMPLATE")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(TEMPLATE));
    std::fs::read_to_string(&path).unwrap_or_else(|error| {
        panic!("读不到模板 {}: {error}; 请用 BALATRO_REPLAY_TEMPLATE 指定一份原始回放", path.display())
    })
}

/// 从模板录像里取出 `snapshot.uda`.
pub fn uda_from_template() -> HashMap<String, String> {
    let parsed = Json::parse(&template_text()).expect("模板能解析");
    match parsed.get("snapshot").and_then(|snapshot| snapshot.get("uda")) {
        Some(Json::Object(entries)) => entries
            .iter()
            .filter_map(|(key, value)| value.as_str().map(|flags| (key.clone(), flags.to_owned())))
            .collect(),
        other => panic!("模板的 uda 应当是个对象, 实际 {other:?}"),
    }
}

/// 模板录像的原文, 导出回放时要照抄它的 `snapshot` 与版本号.
pub fn template_raw() -> String {
    template_text()
}
