//! 快照与回滚.
//!
//! 要验证的是回滚之后的重算结果与原路一致 —— 否则"退回来换一条"就没有意义了.

use std::collections::HashMap;

use balatro_engine::run::{RunState, ShopRates, Timeline, create_card_for_shop, get_pack};

const UDA_TSV: &str = include_str!("data/aleeb-uda.tsv");

fn aleeb_run() -> RunState {
    let mut uda = HashMap::new();
    for line in UDA_TSV.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        if let Some((key, flags)) = line.split_once('\t') {
            uda.insert(key.to_owned(), flags.to_owned());
        }
    }
    RunState::new("ALEEB", 8).with_uda(uda)
}

/// 走一遍第一个商店的货架, 返回 (小丑, 卡包). 顺序与真游戏一致.
fn run_first_shop(run: &mut RunState) -> (Vec<String>, Vec<String>) {
    let rates = ShopRates::default();
    let jokers = (0..2)
        .map(|_| {
            let card = create_card_for_shop(run, &rates);
            let mut token = card.key.clone();
            if card.eternal {
                token.push_str("!e");
            }
            if card.rental {
                token.push_str("!r");
            }
            token
        })
        .collect();
    // 优惠券那一格用的是开局算好的值, 但这一次抽签照样推进随机状态.
    let _ = run.next_voucher_key();
    let packs = (0..2).map(|_| get_pack(run, "shop_pack")).collect();
    (jokers, packs)
}

#[test]
fn a_restored_run_reproduces_an_untouched_run() {
    // 不碰快照, 一路跑出来的结果.
    let mut pristine = aleeb_run();
    let expected = run_first_shop(&mut pristine);

    // 从同一个开局出发, 先做点别的事把状态推乱, 再回滚, 然后跑同一条路.
    let mut run = aleeb_run();
    let base = run.snapshot("开局");

    run.next_voucher_key();
    run.next_voucher_key();
    let _ = get_pack(&mut run, "shop_pack");
    run.ante = 5;
    run.used_vouchers.insert("v_blank".to_owned());

    run.restore(&base);
    assert_eq!(run.ante, 1, "回滚应当把底注也带回来");
    assert!(run.used_vouchers.is_empty(), "回滚应当清掉之后记下的优惠券");

    let actual = run_first_shop(&mut run);
    assert_eq!(actual, expected, "回滚后重跑的结果应当与没走过岔路的一致");
}

#[test]
fn one_snapshot_can_be_used_for_several_branches() {
    let mut run = aleeb_run();
    let base = run.snapshot("开局");

    // 分支一: 直接看货架.
    let first = run_first_shop(&mut run);

    // 分支二: 先抽两次优惠券再回滚, 再从同一点出发看货架.
    run.restore(&base);
    run.next_voucher_key();
    run.next_voucher_key();
    run.restore(&base);
    let second = run_first_shop(&mut run);

    assert_eq!(first, second, "同一份快照可以用多次, 互不影响");
}

#[test]
fn timeline_steps_back_and_forks() {
    let mut run = aleeb_run();
    let mut timeline = Timeline::new();
    assert!(!timeline.step_back(&mut run), "空时间线退不回去");

    timeline.record(&run, "开局");
    let voucher = run.next_voucher_key();

    timeline.record(&run, "抽过优惠券");
    let _ = get_pack(&mut run, "shop_pack");
    assert_eq!(timeline.len(), 2);

    // fork_at: 回到"抽过优惠券"那一刻继续走, 但不动时间线.
    assert!(timeline.fork_at(&mut run, 1));
    let after_pack = get_pack(&mut run, "shop_pack");
    assert_eq!(timeline.len(), 2, "fork_at 不动时间线");

    // rewind_to: 回到同一个点重做一次, 结果应当一样, 并丢掉它之后的点.
    assert!(timeline.rewind_to(&mut run, 1));
    let again = get_pack(&mut run, "shop_pack");
    assert_eq!(after_pack, again, "退回同一点重做, 结果应当一致");
    assert_eq!(timeline.len(), 2, "rewind_to 保留目标点本身");

    // 再退回开局: 优惠券应当能抽出同一张.
    assert!(timeline.rewind_to(&mut run, 0));
    assert_eq!(run.next_voucher_key(), voucher);
    assert_eq!(timeline.len(), 1);

    // step_back 弹出最后一个点.
    assert!(timeline.step_back(&mut run));
    assert!(timeline.is_empty());
}

#[test]
fn snapshot_size_is_reported() {
    let run = aleeb_run();
    let size = run.size_hint();
    assert!(size.uda_entries > 300, "存档进度表是快照里最大的一块");
    assert_eq!(size.tracked_entries, 0, "新开局还没记任何东西");
}
