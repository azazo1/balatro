//! 候选池与商店货架, 与真游戏的回放对拍.
//!
//! 期望值取自 `recordings/20261003-224812-ALEEB/` 的 digest: 选完小盲注, 结算进商店之后是
//! `shop=j_trading!e,j_rocket vouchers=v_magic_trick packs=p_buffoon_normal_1,p_arcana_normal_4`.
//! 这份测试先只锁优惠券那一路.

use std::collections::HashMap;

use balatro_engine::run::{RunState, voucher_pick_index};

/// 存档进度快照, 格式与回放文件 `snapshot.uda` 的值相同.
const UDA_TSV: &str = include_str!("data/aleeb-uda.tsv");

fn aleeb_uda() -> HashMap<String, String> {
    let mut uda = HashMap::new();
    for line in UDA_TSV.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        if let Some((key, flags)) = line.split_once('\t') {
            uda.insert(key.to_owned(), flags.to_owned());
        }
    }
    assert!(uda.len() > 300, "存档进度快照看起来不完整");
    uda
}

fn aleeb_run() -> RunState {
    // 种子 ALEEB, 等离子牌组, 黄金赌注 (stake 8).
    RunState::new("ALEEB", 8).with_uda(aleeb_uda())
}

#[test]
fn aleeb_first_voucher_matches_replay() {
    let mut run = aleeb_run();
    assert_eq!(
        run.next_voucher_key(),
        "v_magic_trick",
        "第一张优惠券与回放 digest 的 vouchers=v_magic_trick 不一致"
    );
}

#[test]
fn voucher_pool_keeps_unavailable_slots() {
    let mut run = aleeb_run();
    let (pool, pool_key, index) = voucher_pick_index(&mut run);

    // 池子与起始池等长, 被筛掉的位置留着占位, 不是删掉.
    assert_eq!(pool.len(), 32, "优惠券原型共 32 个");
    assert_eq!(pool_key, "Voucher1", "池键末尾拼当前底注");

    // 第一次抽到的正好是占位, 所以要按 _resample2 重抽一次才拿到券,
    // 最终结果由上面那个测试锁定.
    assert_eq!(pool[index], "UNAVAILABLE");

    // 有前置条件但前置没兑换过的, 不该进池 (它的位置留成占位).
    assert!(!pool.contains(&"v_overstock_plus".to_owned()));

    // 没解锁的同样只留占位.
    assert!(!pool.contains(&"v_observatory".to_owned()));
    assert!(pool.contains(&"UNAVAILABLE".to_owned()));
}
