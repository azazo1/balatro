//! 把一条 agent 动作施加到一局上.
//!
//! 动作的写法与内置 agent 的工具参数一致 (见 [`crate::agent::prompt`] 里那份命令说明), 也
//! 与本仓库的录像 / 回放文件一致 —— 这样同一份动作记录既能驱动引擎, 也能交给游戏回放对拍.
//!
//! 单独成模块而不是写在命令行工具里, 有两个原因:
//!
//! 1. 命令行工具要**薄**: 它只负责解析参数与打印局面, 语义留在这里, 便于测试.
//! 2. 参数键必须两边一致 (`pack` 用单数 `card`, 而 `play` 用复数 `cards`), 同一条记录在两边
//!    解释成不同的意思就是灾难. 集中一处才不会分叉.

use crate::data::json::Json;
use crate::run::{ActionError, Phase, RunState};
use crate::scoring::EvalEnv;

pub fn numbers_of(value: Option<&Json>) -> Vec<usize> {
    match value {
        Some(Json::Array(items)) => items
            .iter()
            .filter_map(|item| item.as_f64().map(|n| n as usize))
            .collect(),
        _ => Vec::new(),
    }
}

pub fn amount(params: Option<&Json>, field: &str) -> Option<f64> {
    params.and_then(|p| p.get(field)).and_then(Json::as_f64)
}

/// 施加一条动作. 与 `tests/dump_replay.rs` 里那个 `apply_step` 是同一套语义 ——
/// 这里刻意保持一致的参数键 (`pack` 用单数 `card`, 与 `play` 的复数 `cards` 不同),
/// 否则同一条记录在两边会解释成不同的意思.
pub fn apply(step: &Json, run: &mut RunState, env: &EvalEnv) -> Result<String, ActionError> {
    let method = step.get("method").and_then(Json::as_str).expect("有 method");
    let back = run.back_effect();
    let params = step.get("params");
    let cards = numbers_of(params.and_then(|p| p.get("cards")));
    match method {
        "start" => {
            run.start_run();
            Ok("开局".to_owned())
        }
        "select" => run.select_blind().map(|()| "选了这个盲注".to_owned()),
        "skip" => run.skip_blind().map(|tag| format!("跳过盲注, 拿到标签 {tag}")),
        "reroll_boss" => run.reroll_boss().map(|cost| format!("重掷 Boss, 花了 {cost}")),
        "discard" => run
            .discard(&cards)
            .map(|()| format!("弃掉 {cards:?}")),
        "play" => run.play(&cards, env, back).map(|result| {
            // 把牌型与筹码/倍率的分项都打出来 —— agent 靠这个才能"学会"这一手为什么是这个分,
            // 而不是只看一个总数去猜.
            format!(
                "打 {cards:?} -> {:.0} 分 | 牌型 {:?} | 筹码 {:.0} 倍率 {:.1} (基础 {:.0}/{:.1}, 计分牌 {:?})",
                result.total,
                result.hand,
                result.chips,
                result.mult,
                result.base_chips,
                result.base_mult,
                result.scoring_cards
            )
        }),
        "rearrange" => {
            if let Some(order) = params.and_then(|p| p.get("hand")) {
                run.rearrange_hand(&numbers_of(Some(order)))
                    .map(|()| "重排手牌".to_owned())
            } else if let Some(order) = params.and_then(|p| p.get("jokers")) {
                run.rearrange_jokers(&numbers_of(Some(order)))
                    .map(|()| "重排小丑".to_owned())
            } else {
                let order = params.and_then(|p| p.get("consumables"));
                run.rearrange_consumables(&numbers_of(order))
                    .map(|()| "重排消耗牌".to_owned())
            }
        }
        "sort_hand_suit" => {
            run.sort_hand_by_suit();
            Ok("按花色排手牌".to_owned())
        }
        "sort_hand_value" => {
            run.sort_hand_by_value();
            Ok("按点数排手牌".to_owned())
        }
        "cash_out" => run.cash_out().map(|gained| format!("结算, 进账 {gained}")),
        "next_round" => run.next_round().map(|()| "离开商店".to_owned()),
        "reroll" => run.reroll_shop().map(|cost| format!("重抽货架, 花了 {cost}")),
        "buy" => {
            let Some(shop) = run.shop.as_ref() else {
                return Err(ActionError::NotInPhase {
                    expected: Phase::Shop,
                    actual: run.phase,
                });
            };
            // 三种目标: `card` (小丑 / 消耗牌那一格), `voucher`, `pack`.
            let picked = if let Some(slot) = amount(params, "voucher") {
                shop.voucher
                    .clone()
                    .or_else(|| shop.extra_voucher.clone())
                    .ok_or(ActionError::BadIndex(slot as usize))
            } else if let Some(slot) = amount(params, "pack") {
                shop.packs
                    .get(slot as usize)
                    .cloned()
                    .ok_or(ActionError::BadIndex(slot as usize))
            } else {
                let slot = amount(params, "card").unwrap_or(0.0) as usize;
                shop.jokers
                    .get(slot)
                    .cloned()
                    .ok_or(ActionError::BadIndex(slot))
            }?;
            let _ = method;
            run.buy(&picked)
                .map(|cost| format!("买下 {} (花了 {cost})", picked.key))
        }
        "sell" => {
            if let Some(slot) = amount(params, "joker") {
                run.sell_joker(slot as usize)
                    .map(|gain| format!("卖掉小丑, 回收 {gain}"))
            } else {
                let slot = amount(params, "consumable").unwrap_or(0.0) as usize;
                run.sell_consumable(slot)
                    .map(|gain| format!("卖掉消耗牌, 回收 {gain}"))
            }
        }
        "use" => {
            let slot = amount(params, "consumable").unwrap_or(0.0) as usize;
            let targets = numbers_of(params.and_then(|p| p.get("cards")));
            run.use_consumable(slot, &targets)
                .map(|()| format!("用掉第 {slot} 张消耗牌 (目标 {targets:?})"))
        }
        "pack" => {
            if params.and_then(|p| p.get("skip")).and_then(Json::as_bool) == Some(true) {
                return run.skip_pack().map(|()| "跳过这个包".to_owned());
            }
            let slot = amount(params, "card").unwrap_or(0.0) as usize;
            let targets = numbers_of(params.and_then(|p| p.get("targets")));
            // `bbcore` 的 `pack` 端点是"取出来并**立即使用**", 所以这里走同一条:
            // 塔罗改的是手牌, 而关包会把整手牌收回牌堆, 所以顺序反了那两张就改不到.
            run.take_and_use_from_pack(slot, &targets)
                .map(|key| format!("从包里取走并使用 {key}"))
        }
        _ => Err(ActionError::NotImplemented("这个动作")),
    }
}

/// 把一个动作错误翻译成"该怎么办".
///
/// 引擎的 `ActionError` 是给实现者看的 (变体名 + 期望/实际的阶段), 而调用它的是个要**接着做决定**
/// 的 agent: 它需要知道"这个阶段允许哪些动作". 比如 `NoDiscardsLeft` 光看名字只会让人以为
/// 参数写错了, 实际是"这一回合的弃牌次数已经用光, 该出牌了".
pub fn explain(error: &ActionError, run: &RunState) -> String {
    let allowed = match run.phase {
        Phase::BlindSelect => "select | skip | reroll_boss",
        Phase::SelectingHand => "play | discard | rearrange | sort_hand_suit | sort_hand_value | use",
        Phase::RoundEval => "cash_out",
        Phase::Shop => "buy | reroll | sell | use | next_round",
        Phase::BoosterOpened => "pack | sell",
        Phase::GameOver => "这一局已经结束, 没有可做的动作",
    };
    match error {
        ActionError::NoDiscardsLeft => format!(
            "这一回合的弃牌次数用光了 (还剩 {} 次出牌). 直接出牌, 或换一张牌打.",
            run.hands_left
        ),
        ActionError::NoHandsLeft => "这一回合的出牌次数用光了, 这一局到此为止.".to_owned(),
        ActionError::NotInPhase { expected, actual } => format!(
            "动作要求处在 {expected:?}, 而现在是 {actual:?}. 当前可做: {allowed}"
        ),
        ActionError::BadIndex(index) => format!(
            "下标 {index} 越界了. 手牌 {} 张 (0..{}), 小丑 {} 张 (0..{}), 消耗牌 {} 张 (0..{}).",
            run.hand.len(),
            run.hand.len().saturating_sub(1),
            run.jokers.len(),
            run.jokers.len().saturating_sub(1),
            run.consumables.len(),
            run.consumables.len().saturating_sub(1)
        ),
        ActionError::NotEnoughMoney { cost, have } => {
            format!("钱不够: 要 {cost:.0}, 只有 {have:.0}.")
        }
        ActionError::NoCards => "一张牌都没选. 出牌与弃牌都要给 `cards`, 里面是手牌下标.".to_owned(),
        ActionError::TooManyCards { limit, got } => {
            format!("一次最多选 {limit} 张, 你给了 {got} 张.")
        }
        ActionError::TooFewCards { least, got } => {
            format!("一次至少要选 {least} 张, 你给了 {got} 张.")
        }
        ActionError::NoRoom { what, slots } => {
            format!("{what}没空位了 (共 {slots} 个). 先卖一张, 或换别的动作.")
        }
        ActionError::NotAllowed(why) => format!("这一步游戏本身不允许: {why}."),
        other => format!("引擎拒绝了这条动作 ({other:?}). 当前可做: {allowed}"),
    }
}
