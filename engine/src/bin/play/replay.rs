//! 把这局导出成**游戏能回放**的文件, 供逐步对拍.
//!
//! 结构对齐真实录像: 除了 `run` / `actions` / `result` / `source`, 其余字段 (含 `snapshot` 与
//! 版本号) 原样取自模板 —— 那是 LOVE 自己的存档格式, 引擎既造不出也不该造.
//!
//! 每一步都带**引擎预测的摘要** (`digest`). 游戏重放时会拿它逐步核对, 对不上就停下并指出哪一项
//! 不同, 所以这份文件同时是交给游戏的断言集. 摘要是"这一步做完之后"的状态, 取早取晚都会让游戏在
//! 正确的地方报不一致.

use balatro_engine::data::json::Json;
use balatro_engine::run::RunState;
use balatro_engine::run::digest::digest;

use crate::session;

/// 这一局的开局参数. 与回放文件里 `run` 段的字段一一对应.
pub struct RunSpec {
    pub seed: String,
    pub deck: String,
    pub stake: String,
}

/// 拼一条动作记录: 动作本身 + 这一步**之后**引擎给出的 digest.
///
/// `digest` 是回放器拿去逐步核对的字符串, 所以它必须是"这一步做完之后"的状态 ——
/// 取早一步或晚一步都会让游戏在正确的地方报"状态不一致".
pub fn record_of(step: &Json, run: &RunState, wall: f64) -> String {
    let method = step.get("method").and_then(Json::as_str).unwrap_or("?");
    let mut parts = vec![format!("\"method\":{}", quote(method))];
    if let Some(params) = step.get("params") {
        parts.push(format!("\"params\":{}", json_of(params)));
    }
    parts.push(format!("\"digest\":{}", quote(&digest(run))));
    parts.push(format!("\"wall\":{wall}"));
    parts.push("\"ok\":true".to_owned());
    format!("{{{}}}", parts.join(","))
}

/// 拼出整份回放文件, 结构对齐真实录像.
///
/// `snapshot` 与版本号这类字段**原样取自模板**: 那是 LÖVE 自己的存档格式, 引擎既造不出也不该造.
/// 只覆盖 `run` (这局的开局参数), `actions` (agent 打的每一步) 与 `result`.
pub fn render(spec: &RunSpec, records: &[String], won: bool) -> String {
    let parsed = Json::parse(&session::template_raw()).expect("模板能解析");
    let Json::Object(entries) = parsed else {
        panic!("模板顶层应当是个对象");
    };

    let mut fields: Vec<String> = Vec::new();
    for (key, value) in entries {
        match key.as_str() {
            "run" | "actions" | "result" | "recorded_at" | "source" => continue,
            // 快照里的 `settings` 要改一项, 不能整段照抄.
            "snapshot" => fields.push(format!("{}:{}", quote(&key), snapshot_of(&value))),
            _ => fields.push(format!("{}:{}", quote(&key), json_of(&value))),
        }
    }
    fields.push(format!(
        "\"run\":{{\"deck\":{},\"stake\":{},\"seed\":{},\"seeded\":true,\"resumed\":false,\
         \"deck_key\":{},\"tutorial\":false}}",
        quote(&spec.deck.to_uppercase()),
        quote(&spec.stake.to_uppercase()),
        quote(&spec.seed),
        quote(&session::deck_of(&spec.deck)),
    ));
    // 标 `agent-played` 而不是 `engine-generated`: 这两者的区别是**谁做的决定**.
    // `engine-generated` 是引擎里那套写死的贪心策略自己跑的; 这一份的每一步都是 agent
    // 看过局面之后选的. 混成一个标记就分不出产物的来源了.
    fields.push(format!("\"source\":{}", quote("agent-played")));
    fields.push(format!("\"result\":{{\"reason\":\"engine\",\"won\":{won}}}"));
    fields.push(format!("\"actions\":[{}]", records.join(",\n")));
    format!("{{{}}}", fields.join(",\n"))
}

/// 快照照抄, 但把 `settings.GAMESPEED` 换成 4.
///
/// 回放开始时会用这里的 `settings` 覆盖游戏当前设置 (见 `mods/bbreplay/replay/snapshot.lua`
/// 的 `SETTING_KEYS` 与 `M.apply`), 所以**存档里改成 4 也没用** —— 只要这份快照写着 1,
/// 回放就还是 1 倍速. 模板来自一局正常速度的录像, 于是它记的就是 1.
///
/// 一局回放有几十上百步, 每一步都等完整动画就太慢了; 而倍率只影响动画快慢, 不改变任何状态,
/// 逐步比对的摘要因此不受影响. 所以这里明确写成 4.
fn snapshot_of(value: &Json) -> String {
    const GAMESPEED: f64 = 4.0;
    let Json::Object(entries) = value else {
        panic!("模板的 snapshot 应当是个对象");
    };
    let mut fields: Vec<String> = Vec::new();
    for (key, item) in entries {
        if key != "settings" {
            fields.push(format!("{}:{}", quote(key), json_of(item)));
            continue;
        }
        let Json::Object(settings) = item else {
            panic!("模板的 snapshot.settings 应当是个对象");
        };
        let mut inner: Vec<String> = Vec::new();
        let mut seen = false;
        for (name, setting) in settings {
            if name == "GAMESPEED" {
                seen = true;
                inner.push(format!("{}:{}", quote(name), GAMESPEED as i64));
            } else {
                inner.push(format!("{}:{}", quote(name), json_of(setting)));
            }
        }
        if !seen {
            inner.push(format!("{}:{}", quote("GAMESPEED"), GAMESPEED as i64));
        }
        fields.push(format!("{}:{{{}}}", quote(key), inner.join(",")));
    }
    format!("{{{}}}", fields.join(","))
}

pub(crate) fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", control as u32)),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

/// 把解析出来的 JSON 再写回去 (模板的字段原样带上).
fn json_of(value: &Json) -> String {
    match value {
        Json::Null => "null".to_owned(),
        Json::Bool(flag) => flag.to_string(),
        Json::Number(number) => {
            if number.fract() == 0.0 && number.abs() < 1e15 {
                format!("{}", *number as i64)
            } else {
                format!("{number}")
            }
        }
        Json::String(text) => quote(text),
        Json::Array(items) => format!(
            "[{}]",
            items.iter().map(json_of).collect::<Vec<_>>().join(",")
        ),
        Json::Object(entries) => format!(
            "{{{}}}",
            entries
                .iter()
                .map(|(key, value)| format!("{}:{}", quote(key), json_of(value)))
                .collect::<Vec<_>>()
                .join(",")
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoted_json_round_trips_control_characters() {
        let mut text: String = (0u8..32).map(char::from).collect();
        text.push_str("\\\"中文");
        let decoded = Json::parse(&quote(&text)).unwrap();
        assert_eq!(decoded.as_str(), Some(text.as_str()));
    }

    #[test]
    fn exported_result_keeps_the_engine_win_flag() {
        let spec = RunSpec { seed: "4AH77J5E".to_owned(), deck: "PLASMA".to_owned(), stake: "GOLD".to_owned() };
        for won in [false, true] {
            let file = Json::parse(&render(&spec, &[], won)).unwrap();
            assert_eq!(file.get("result").unwrap().get("won").and_then(Json::as_bool), Some(won));
        }
    }
}
