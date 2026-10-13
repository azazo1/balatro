//! 批量并行跑对局.
//!
//! 引擎里没有全局可变状态 (原型表是只读的), 每局的状态全在 [`RunState`] 里, 所以两局之间
//! 天然独立 —— 并行只需要把种子分给几个线程, 不需要锁, 也不需要每局重建什么.
//!
//! 这一层不决定"怎么玩": 调用方给一个策略 (拿 `&mut RunState` 自己走若干步),
//! 这里负责分片, 收结果与汇总.

use std::sync::Mutex;
use std::thread;

use crate::run::RunState;

/// 一局的收尾摘要.
#[derive(Clone, Debug, PartialEq)]
pub struct RunOutcome {
    pub seed: String,
    /// 走到第几底注.
    pub ante: i64,
    /// 通关了没有 (打完底注 8 的 Boss).
    pub won: bool,
    pub dollars: f64,
    /// 策略里走了多少步, 用来估这一局跑了多久.
    pub steps: usize,
}

/// 并行跑一批对局, 返回与 `seeds` 同序的结果.
///
/// `threads` 为 0 时按当前可用并行度取. `play` 会被每个线程共享调用, 所以要么是无状态的纯逻辑,
/// 要么自己管好内部同步. 它返回走了多少步 (只用来记账).
pub fn run_batch<F, S>(
    seeds: &[String],
    stake: i64,
    threads: usize,
    deck: Option<&str>,
    play: F,
    summarize: S,
) -> Vec<RunOutcome>
where
    F: Fn(&mut RunState) -> usize + Send + Sync,
    S: Fn(&RunState) -> bool + Send + Sync,
{
    let threads = if threads == 0 {
        thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
    } else {
        threads
    }
    .max(1)
    .min(seeds.len().max(1));

    // 结果按原下标放, 这样线程怎么分片都不影响返回顺序.
    let results: Mutex<Vec<Option<RunOutcome>>> = Mutex::new(vec![None; seeds.len()]);
    let next = std::sync::atomic::AtomicUsize::new(0);

    thread::scope(|scope| {
        for _ in 0..threads {
            scope.spawn(|| loop {
                let index = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                if index >= seeds.len() {
                    break;
                }
                // 每局都新建: 一局的全部状态都在 `RunState` 里, 没有需要复用的全局量.
                let mut run = RunState::new(&seeds[index], stake);
                if let Some(deck) = deck {
                    run = run.with_deck(deck);
                }
                let steps = play(&mut run);
                let won = summarize(&run);
                let outcome = RunOutcome {
                    seed: seeds[index].clone(),
                    ante: run.ante,
                    won,
                    dollars: run.dollars,
                    steps,
                };
                results.lock().expect("结果表不会中毒")[index] = Some(outcome);
            });
        }
    });

    let mut out = results.into_inner().expect("结果表不会中毒");
    out.drain(..)
        .map(|slot| slot.expect("每个下标都该被填上"))
        .collect()
}
