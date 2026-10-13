//! 调试模式下的出牌预览: 在状态副本上试出一手, 不写历史, 不动真实随机状态.
//!
//! 计分明细直接取引擎 `ScoreResult::steps`, 与真正出牌走同一条路径, 因此预览的数字与提交后一致
//! (幸运牌这类掷骰效果按当前随机状态预测, 属于调试模式的上帝视角).
use engine::{agent::{action, summary}, data::knowledge, scoring::{EvalEnv, ScoreKind, ScoreSource}};
use serde_json::{Value, json};
use crate::{error::{Error, Result}, session::Session, view};

pub fn preview(session: &Session, cards: &[usize]) -> Result<Value> {
    if !session.debug { return Err(Error::refused("请先开启调试模式")); }
    let source = session.state();
    let mut run = source.clone();
    let back = run.back_effect();
    let result = match run.play(cards, &EvalEnv::default(), back) {
        Ok(result) => result,
        // 不合法的选择是预览的常态 (例如通灵要求五张), 作为结果返回而不是请求错误.
        Err(error) => return Ok(json!({"revision":session.revision,"cards":cards,"error":action::explain(&error, source)})),
    };
    // 与 RunState::play 一致: 蓝铃锁定的牌自动带上, 按手牌从左到右计分.
    let mut played: Vec<usize> = cards.to_vec();
    for (index, card) in source.hand.iter().enumerate() {
        if card.forced_selection && !played.contains(&index) { played.push(index); }
    }
    played.sort_unstable();
    played.dedup();

    // 引擎只记小丑的键. 同名小丑按从左到右分配: 下一次取不小于上一次位置的那张, 取不到就回到最左.
    let mut joker_cursor = 0usize;
    let steps: Vec<Value> = result.steps.iter().map(|step| {
        let from = match &step.source {
            ScoreSource::Card { index, .. } => {
                joker_cursor = 0;
                let hand = played.get(*index).copied();
                json!({"kind":"card","hand":hand,"name":hand.map(|i|summary::playing_card(&source.hand[i]))})
            }
            ScoreSource::Held { card } => {
                joker_cursor = 0;
                let hand = source.hand.iter().enumerate()
                    .position(|(i, c)| c.card == *card && !played.contains(&i));
                json!({"kind":"held","hand":hand,"name":hand.map_or_else(||"留手牌".to_owned(),|i|format!("留手{}",summary::playing_card(&source.hand[i])))})
            }
            ScoreSource::Joker { key } => {
                let candidates: Vec<usize> = source.jokers.iter().enumerate()
                    .filter(|(_, j)| &j.key == key).map(|(i, _)| i).collect();
                let pick = candidates.iter().copied().find(|&i| i >= joker_cursor).or(candidates.first().copied());
                if let Some(index) = pick { joker_cursor = index; }
                json!({"kind":"joker","joker":pick,"name":knowledge::describe(key).map_or(key.as_str(),|(name,_)|name)})
            }
            ScoreSource::Stage { name } => json!({"kind":"stage","name":name}),
        };
        let kind = match step.kind {
            ScoreKind::Chips => "chips", ScoreKind::Mult => "mult", ScoreKind::XMult => "xmult",
            ScoreKind::Dollars => "dollars", ScoreKind::Reshape => "reshape",
        };
        json!({"source":from,"kind":kind,"amount":step.amount,"chips":step.chips,"mult":step.mult})
    }).collect();

    tracing::debug!(cards = ?played, total = result.total, steps = steps.len(), "出牌预览");
    Ok(json!({
        "revision":session.revision,"cards":played,
        "hand":summary::hand_zh(result.hand),"level":source.hands.get(result.hand).level,
        "base_chips":result.base_chips,"base_mult":result.base_mult,
        "chips":result.chips,"mult":result.mult,"total":result.total,"blocked":result.blocked,"dollars":result.dollars,
        "scoring":result.scoring_cards.iter().filter_map(|i|played.get(*i)).collect::<Vec<_>>(),
        "played":played.iter().map(|&i|view::playing(&source.hand[i],i,true)).collect::<Vec<_>>(),
        "steps":steps,
        "round_chips":source.chips,"target":source.blind.as_ref().map(|b|b.chips),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Event, Opening};
    use engine::run::digest::digest;

    fn play(cards: Value) -> Event {
        Event::Action { action: serde_json::from_value(json!({"method":"play","params":{"cards":cards}})).unwrap() }
    }

    #[test]
    fn preview_matches_real_play_and_leaves_session_untouched() {
        let mut s = Session::new(Opening { seed:"ALEEB".into(),deck:"RED".into(),stake:1,profile:"all".into() }).unwrap();
        s.commit(0, Event::Action { action: serde_json::from_value(json!({"method":"select"})).unwrap() }).unwrap();
        assert!(preview(&s, &[0, 1]).is_err(), "正常模式不能预览");
        s.set_debug(1, true).unwrap();
        let (before, rng, nodes) = (digest(s.state()), format!("{:?}", s.state().rng), s.nodes.len());
        let p = preview(&s, &[0, 1, 2]).unwrap();
        assert!(p.get("error").is_none(), "{p}");
        assert_eq!(digest(s.state()), before);
        assert_eq!(format!("{:?}", s.state().rng), rng);
        assert_eq!((s.revision, s.nodes.len()), (2, nodes));
        // 每一步的来源都要能落到界面元素上.
        for step in p["steps"].as_array().unwrap() {
            let src = &step["source"];
            match src["kind"].as_str().unwrap() {
                "card" => assert!([0, 1, 2].contains(&src["hand"].as_u64().unwrap())),
                "joker" => assert!(src["joker"].is_u64()),
                _ => {}
            }
        }
        s.commit(2, play(json!([0, 1, 2]))).unwrap();
        let total = p["total"].as_f64().unwrap();
        let head = s.nodes[s.current].note.lines().next().unwrap().to_owned();
        assert!(head.ends_with(&format!("= {}", summary::number(total))), "预览 {total} 与实际 {head} 不一致");
        assert!(preview(&s, &[0, 1, 2, 3, 4, 5]).unwrap()["error"].is_string());
    }
}
