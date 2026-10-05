//! 游戏回放的离线动作与摘要校验, 不参与游戏规则计算.

use crate::agent::action;
use crate::data::json::Json;
use crate::run::digest::{digest, digest_fields};
use crate::run::{ActionError, RunState};
use crate::scoring::EvalEnv;

/// 精确保留强化与贴纸, 只移除旧录像中非扑克牌的效果名称.
fn without_effect_tail(token: &str) -> String {
    let Some((head, tail)) = token.split_once('~') else {
        return token.to_owned();
    };
    let sticker = tail.find('!').unwrap_or(tail.len());
    let name = &tail[..sticker];
    if ["bonus", "mult", "wild", "glass", "steel", "stone", "gold", "lucky"].contains(&name) {
        token.to_owned()
    } else {
        format!("{head}{}", &tail[sticker..])
    }
}

fn normalized_field(key: &str, value: &str) -> String {
    if key == "packs" {
        return value.split(',').map(|token| {
            let Some((stem, art)) = token.rsplit_once('_') else { return token.to_owned(); };
            if stem.starts_with("p_") && !art.is_empty() && art.bytes().all(|c| c.is_ascii_digit()) {
                stem.to_owned()
            } else {
                token.to_owned()
            }
        }).collect::<Vec<_>>().join(",");
    }
    if ["jokers", "consumables", "shop", "pack"].contains(&key) {
        return value.split(',').map(without_effect_tail).collect::<Vec<_>>().join(",");
    }
    value.to_owned()
}

/// 与游戏回放器采用相同的图案编号和旧效果名容忍. 不忽略金钱或计分差异.
/// 稀疏旧 fixture 只校验实际保存的字段, strict 模式额外检查引擎多出的字段.
pub fn digest_diff(want: &str, got: &str, strict: bool) -> Option<String> {
    let want = digest_fields(want);
    let got = digest_fields(got);
    let mut keys: Vec<&str> = want.iter().map(|(key, _)| key.as_str()).collect();
    if strict {
        keys.extend(got.iter().map(|(key, _)| key.as_str()));
    }
    keys.sort_unstable();
    keys.dedup();
    let mut differences = Vec::new();
    for key in keys {
        let a = want.iter().find(|(k, _)| k == key).map(|(_, v)| normalized_field(key, v));
        let b = got.iter().find(|(k, _)| k == key).map(|(_, v)| normalized_field(key, v));
        if a != b {
            differences.push(format!("{key}: engine {} | game {}", b.as_deref().unwrap_or("<missing>"), a.as_deref().unwrap_or("<missing>")));
        }
    }
    (!differences.is_empty()).then(|| differences.join(" ; "))
}

/// 仅折算真实手动操作. 未知按钮显式拒绝, 不将未知动作视为成功的空操作.
pub fn translated_action(step: &Json) -> Result<Json, ActionError> {
    let method = step.get("method").and_then(Json::as_str)
        .ok_or(ActionError::NotAllowed("动作必须包含 method"))?;
    if method == "reorder" {
        let params = step.get("params").cloned().unwrap_or(Json::Null);
        let area = params.get("area").and_then(Json::as_str);
        let order = params.get("order").cloned().unwrap_or(Json::Null);
        let key = match area {
            Some("hand") => "hand",
            Some("jokers") => "jokers",
            Some("consumeables" | "consumables") => "consumables",
            _ => return Err(ActionError::NotImplemented("未知重排区域")),
        };
        return Ok(Json::Object(vec![("method".to_owned(), Json::String("rearrange".to_owned())),
            ("params".to_owned(), Json::Object(vec![(key.to_owned(), order)]))]));
    }
    if method != "press" { return Ok(step.clone()); }
    let params = step.get("params").ok_or(ActionError::NotAllowed("按钮动作缺少参数"))?;
    let function = params.get("fn").and_then(Json::as_str).unwrap_or("");
    let area = params.get("area").and_then(Json::as_str).unwrap_or("");
    let index = params.get("index").cloned().unwrap_or(Json::Number(0.0));
    let mut fields = Vec::new();
    let translated = match (function, area) {
        ("sort_hand_value", _) => "sort_hand_value",
        ("sort_hand_suit", _) => "sort_hand_suit",
        ("skip_booster", _) => { fields.push(("skip".to_owned(), Json::Bool(true))); "pack" },
        ("use_card", "pack_cards") => {
            fields.push(("card".to_owned(), index));
            if let Some(targets) = params.get("targets") { fields.push(("targets".to_owned(), targets.clone())); }
            "pack"
        },
        ("use_card", "consumeables") => {
            fields.push(("consumable".to_owned(), index));
            if let Some(targets) = params.get("targets") { fields.push(("cards".to_owned(), targets.clone())); }
            "use"
        },
        ("sell_card", "jokers") => { fields.push(("joker".to_owned(), index)); "sell" },
        ("sell_card", "consumeables") => { fields.push(("consumable".to_owned(), index)); "sell" },
        ("buy_from_shop", "shop_jokers") => {
            fields.push(("card".to_owned(), index));
            if params.get("id").and_then(Json::as_str) == Some("buy_and_use") {
                fields.push(("use".to_owned(), Json::Bool(true)));
            }
            "buy"
        },
        _ => return Err(ActionError::NotImplemented("未知手动按钮")),
    };
    Ok(Json::Object(vec![("method".to_owned(), Json::String(translated.to_owned())),
        ("params".to_owned(), Json::Object(fields))]))
}

#[derive(Debug)]
pub struct Report {
    pub matched_digests: usize,
    pub matched_refusals: usize,
    pub unverified_actions: usize,
    pub skipped_observations: usize,
    pub failure: Option<String>,
    pub expected: Option<String>,
    pub actual: Option<String>,
}

/// 校验头部带 seed/deck/stake/uda 的动作列表. 缺少摘要不代表状态已获验证.
pub fn check(header: &Json, steps: &[Json], strict: bool) -> Report {
    let mut report = Report { matched_digests: 0, matched_refusals: 0, unverified_actions: 0,
        skipped_observations: 0, failure: None, expected: None, actual: None };
    let seed = header.get("seed").and_then(Json::as_str).unwrap_or("");
    let deck = header.get("deck").and_then(Json::as_str).unwrap_or("");
    let stake = header.get("stake").and_then(Json::as_str).unwrap_or("");
    let stakes = ["WHITE", "RED", "GREEN", "BLACK", "BLUE", "PURPLE", "ORANGE", "GOLD"];
    let Some(stake) = stakes.iter().position(|name| *name == stake) else {
        report.failure = Some("缺少有效赌注".to_owned()); return report;
    };
    let deck = if deck.starts_with("b_") { deck.to_owned() } else { format!("b_{}", deck.to_lowercase()) };
    if seed.is_empty() || crate::data::catalog::Catalog::get().record(&deck).is_none() {
        report.failure = Some("缺少有效种子或支持的牌组".to_owned()); return report;
    }
    let Some(Json::Object(uda)) = header.get("uda") else {
        report.failure = Some("缺少原局解锁快照".to_owned()); return report;
    };
    let uda = uda.iter().filter_map(|(k,v)| v.as_str().map(|s| (k.clone(),s.to_owned()))).collect();
    let mut run = RunState::new(seed, stake as i64 + 1).with_deck(&deck).with_uda(uda);
    run.start_run();
    let env = EvalEnv::default();
    for (offset, step) in steps.iter().enumerate() {
        let index = step.get("source_index").and_then(Json::as_f64).map_or(offset+1, |n| n as usize);
        let method = step.get("method").and_then(Json::as_str).unwrap_or("<missing>");
        if ["notify", "menu", "continue", "endless"].contains(&method) {
            report.skipped_observations += 1;
            continue;
        }
        let translated = match translated_action(step) {
            Ok(action) => action,
            Err(error) => {
                report.failure = Some(format!("第 {index} 步 ({method}) 不能解释: {error:?}"));
                break;
            }
        };
        let outcome = if method == "reorder" {
            // 本地拖动不经过 bbcore 端点的阶段门, 对齐 manual.apply_local.
            let params = translated.get("params").expect("重排转换必定带参数");
            let reorder = if let Some(order) = params.get("hand") {
                run.rearrange_hand(&action::numbers_of(Some(order)))
            } else if let Some(order) = params.get("jokers") {
                run.rearrange_jokers(&action::numbers_of(Some(order)))
            } else {
                run.rearrange_consumables(&action::numbers_of(params.get("consumables")))
            };
            reorder.map(|()| "本地重排".to_owned())
        } else {
            action::apply(&translated, &mut run, &env)
        };
        let refused = step.get("ok").and_then(Json::as_bool) == Some(false);
        let failure = match (refused, outcome) {
            (_, Err(ActionError::NotImplemented(error))) => Some(format!("尚不支持的规则动作: {error}")),
            (true, Err(_)) => { report.matched_refusals += 1; None },
            (true, Ok(_)) => Some("游戏拒绝而 engine 接受".to_owned()),
            (false, Err(error)) => Some(format!("游戏接受而 engine 拒绝: {error:?}")),
            (false, Ok(_)) => {
                if let Some(want) = step.get("digest").and_then(Json::as_str).filter(|s| !s.starts_with("state=UNKNOWN")) {
                    let got = digest(&run);
                    let difference = digest_diff(want, &got, strict);
                    if difference.is_some() {
                        report.expected = Some(want.to_owned());
                        report.actual = Some(got);
                    } else { report.matched_digests += 1; }
                    difference
                } else { report.unverified_actions += 1; None }
            },
        };
        if let Some(failure) = failure {
            report.failure = Some(format!("第 {index} 步 ({method}): {failure}"));
            break;
        }
    }
    report
}
