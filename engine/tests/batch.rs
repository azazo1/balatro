//! 批量并行跑对局.

use balatro_engine::batch::{RunOutcome, run_batch};
use balatro_engine::run::RunState;
use balatro_engine::scoring::{BackEffect, EvalEnv};

/// 一个最小策略: 一路"选盲注 - 出一手 - 结算"直到打不动.
///
/// 它不需要打得好, 只要能走若干步并消耗随机数 —— 这样并行与串行才有可比性.
fn play_along(run: &mut RunState) -> usize {
    let mut steps = 0;
    for _ in 0..60 {
        if run.phase == balatro_engine::run::Phase::GameOver {
            break;
        }
        match run.phase {
            balatro_engine::run::Phase::BlindSelect => {
                run.select_blind().expect("在选盲注阶段");
            }
            balatro_engine::run::Phase::SelectingHand => {
                let cards: Vec<usize> = (0..run.hand.len().min(5)).collect();
                if run
                    .play(&cards, &EvalEnv::default(), BackEffect::Plain)
                    .is_err()
                {
                    break;
                }
            }
            balatro_engine::run::Phase::RoundEval => {
                let _ = run.cash_out();
            }
            balatro_engine::run::Phase::Shop => {
                run.next_round().expect("这一回合有商店");
            }
            _ => break,
        }
        steps += 1;
    }
    steps
}

fn summarize(run: &RunState) -> bool {
    run.won
}

#[test]
fn batch_matches_running_them_one_by_one() {
    let seeds: Vec<String> = (0..24).map(|i| format!("SEED{i:02}")).collect();

    // 并行.
    let parallel: Vec<RunOutcome> = run_batch(&seeds, 8, 4, None, play_along, summarize);

    // 串行, 逐个跑一遍.
    let serial: Vec<RunOutcome> = seeds
        .iter()
        .map(|seed| {
            let mut run = RunState::new(seed, 8);
            let steps = play_along(&mut run);
            RunOutcome {
                seed: seed.clone(),
                ante: run.ante,
                won: run.won,
                dollars: run.dollars,
                steps,
            }
        })
        .collect();

    assert_eq!(parallel.len(), serial.len(), "每条种子一条结果");
    assert_eq!(parallel, serial, "并行的结果必须与串行逐个跑一模一样");
}

/// 线程数不该影响结果 —— 引擎里没有全局可变状态, 所以分几片都一样.
#[test]
fn thread_count_does_not_change_the_results() {
    let seeds: Vec<String> = (0..16).map(|i| format!("T{i:03}")).collect();

    let one = run_batch(&seeds, 8, 1, None, play_along, summarize);
    let many = run_batch(&seeds, 8, 8, None, play_along, summarize);
    assert_eq!(one, many, "线程数不同, 结果不该不同");
}

/// 顺序按输入的种子来, 与线程怎么分片无关.
#[test]
fn results_keep_the_input_order() {
    let seeds: Vec<String> = vec!["ZZZ".into(), "AAA".into(), "MMM".into()];
    let out = run_batch(&seeds, 8, 3, None, play_along, summarize);
    let got: Vec<&str> = out.iter().map(|entry| entry.seed.as_str()).collect();
    assert_eq!(got, vec!["ZZZ", "AAA", "MMM"]);
}

/// 带着牌组参数跑: 蓝色牌组的"出牌次数 +1"应当体现出来.
///
/// 注意它加的是**出牌次数**而不是手牌上限 —— 手牌上限归镣铐那类改.
#[test]
fn batch_can_apply_a_deck() {
    let seeds: Vec<String> = (0..8).map(|i| format!("D{i}")).collect();
    let out = run_batch(&seeds, 8, 2, Some("b_blue"), play_along, |run: &RunState| {
        run.hands_per_round == 5
    });
    assert!(
        out.iter().all(|entry| entry.won),
        "每局的出牌次数都该是五次"
    );
}
