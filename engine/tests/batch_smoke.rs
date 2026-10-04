//! 批量跑一票随机对局, 看引擎在长跑里会不会崩或卡住.
//!
//! 它不断言"打得好不好", 只要求: 每局都能结束, 步数有限, 状态自洽.

use balatro_engine::batch::run_batch;
use balatro_engine::run::{Phase, RunState};
use balatro_engine::scoring::{BackEffect, EvalEnv};

/// 随手打: 能出就出, 能买就买 (买最便宜的), 走不动就停.
fn play_along(run: &mut RunState) -> usize {
    // 开局那一步不能少 —— 少了它牌堆是空的, 一出手就报 `NoCards`.
    run.start_run();
    let mut steps = 0;
    for _ in 0..400 {
        match run.phase {
            Phase::GameOver => break,
            Phase::BlindSelect => run.select_blind(),
            Phase::SelectingHand => {
                let cards: Vec<usize> = (0..run.hand.len().min(5)).collect();
                if run
                    .play(&cards, &EvalEnv::default(), BackEffect::Plain)
                    .is_err()
                {
                    break;
                }
            }
            Phase::RoundEval => {
                let _ = run.cash_out();
            }
            Phase::Shop => {
                // 买得起就买第一件, 买不起就走.
                let bought = run
                    .shop
                    .as_ref()
                    .and_then(|shop| shop.jokers.first().cloned())
                    .map(|card| run.buy(&card).is_ok())
                    .unwrap_or(false);
                if !bought || steps % 3 == 0 {
                    run.next_round().expect("这一回合有商店");
                }
            }
            Phase::BoosterOpened => {
                if run.pick_from_pack(0).is_err() {
                    run.next_round().expect("这一回合有商店");
                }
            }
        }
        steps += 1;
    }
    steps
}

#[test]
fn a_hundred_random_runs_all_finish() {
    let seeds: Vec<String> = (0..100).map(|i| format!("SMOKE{i:03}")).collect();
    let out = run_batch(&seeds, 8, 8, None, play_along, |run: &RunState| run.won);

    assert_eq!(out.len(), 100, "每局都要有结果");
    for entry in &out {
        assert!(entry.steps > 0, "{} 一步都没走", entry.seed);
        assert!(entry.steps < 400, "{} 走满上限还没停, 可能卡住", entry.seed);
        assert!(
            entry.ante >= 1 && entry.ante <= 9,
            "{} 走到了底注 {}",
            entry.seed,
            entry.ante
        );
    }
    // 这里**不**断言"打过多少关": 上面那个机器人是随手打 (每手取前五张), 走多远全看运气.
    // 量过一遍: 一百局里第一个盲注 (目标 300) 的得分中位数是 183, 最高 700 ——
    // 也就是能过小盲注的本来就只有十几局, 而"进第二底注"还要连过三个盲注 (Boss 目标 600 起).
    // 曾经断言过"至少一局进第二底注", 那是把"能不能打好"混进了"会不会崩"里, 两种随机会让它
    // 偶尔红一次, 于是变成一条不可信的测试.
    //
    // 改成钉住**流程确实在往前走**: 平均步数要明显多于"一步不动", 且底注与回合都在合法范围.
    let best = out.iter().map(|entry| entry.ante).max().unwrap_or(0);
    let avg_steps: usize = out.iter().map(|entry| entry.steps).sum::<usize>() / out.len();
    println!(
        "一百局: 最远底注 {}, 平均 {} 步, 通关 {} 局",
        best,
        avg_steps,
        out.iter().filter(|entry| entry.won).count()
    );
    assert!(
        avg_steps >= 5,
        "平均只有 {avg_steps} 步, 连一手牌都没打出去, 流程可疑"
    );
}
