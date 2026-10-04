//! 八个赌注档与十五副牌组的交叉矩阵.
//!
//! # 为什么单独测这个
//!
//! 录像只覆盖两个赌注: 十七份是 GOLD (8), 一份是 WHITE (1). 而赌注恰恰改了几样
//! **会消耗随机数**的东西 —— 商店小丑的"永恒 / 易腐 / 租赁"三个掷骰都挂在赌注门槛上
//! (`stake >= 4/7/8`), 而掷骰的次数不同, 后面整条随机序列就会错位.
//!
//! 光验"参数设对了"不够: 真正的风险是**门槛有没有真的把掷骰挡住**. 所以除了逐档核对参数,
//! 这里还按档统计商店里实际出现的永恒 / 易腐 / 租赁, 确认:
//!
//! - 赌注 3 及以下: 三者一个都不该出现 (哪怕那一掷**照掷不误** —— 掷了但不生效);
//! - 赌注 4-6: 永恒可以出现, 易腐与租赁不该;
//! - 赌注 7: 永恒与易腐可以, 租赁不该;
//! - 赌注 8: 三者都可以.
//!
//! 写成"可以出现"而不是"必须出现"是因为它们都是概率 (永恒要 `poll > 0.7`), 单一系列里
//! 完全可能一次都不中; 所以"能出现"那一侧用足够多的系列去撞, "不该出现"那一侧则是硬的.

use std::collections::BTreeSet;

use balatro_engine::run::{BlindKind, Phase, RunState};
use balatro_engine::scoring::EvalEnv;

/// 十五副牌组的键.
const DECKS: [&str; 15] = [
    "b_red",
    "b_blue",
    "b_yellow",
    "b_green",
    "b_black",
    "b_magic",
    "b_nebula",
    "b_ghost",
    "b_abandoned",
    "b_checkered",
    "b_zodiac",
    "b_painted",
    "b_anaglyph",
    "b_plasma",
    "b_erratic",
];

/// 赌注档对应的那几样, 逐档照 `Game:start_run` 里的规则写一遍.
///
/// 这里**故意把规则抄一遍**而不是读引擎的字段: 读字段的话, 参数设错了也会"自己跟自己一致".
struct StakeRules {
    /// 小盲注是否不发固定奖金 (赌注 2 起).
    no_small_reward: bool,
    /// 盲注目标查哪张表 (赌注 3 起 2, 6 起 3).
    scaling: i64,
    /// 每回合弃牌次数 (基础 3, 赌注 5 起减一).
    discards: i64,
    eternals: bool,
    perishables: bool,
    rentals: bool,
}

fn rules_for(stake: i64) -> StakeRules {
    StakeRules {
        no_small_reward: stake >= 2,
        scaling: if stake >= 6 {
            3
        } else if stake >= 3 {
            2
        } else {
            1
        },
        discards: if stake >= 5 { 2 } else { 3 },
        eternals: stake >= 4,
        perishables: stake >= 7,
        rentals: stake >= 8,
    }
}

/// 八个赌注档开局后的参数都要与规则一致.
#[test]
fn every_stake_sets_the_parameters_the_game_sets() {
    for stake in 1..=8 {
        let rules = rules_for(stake);
        let run = RunState::new("STAKE", stake);
        assert_eq!(
            run.modifiers.enable_eternals_in_shop, rules.eternals,
            "赌注 {stake}: 永恒"
        );
        assert_eq!(
            run.modifiers.enable_perishables_in_shop, rules.perishables,
            "赌注 {stake}: 易腐"
        );
        assert_eq!(
            run.modifiers.enable_rentals_in_shop, rules.rentals,
            "赌注 {stake}: 租赁"
        );
        assert_eq!(run.scaling, rules.scaling, "赌注 {stake}: 难度档");
        assert_eq!(run.discards_per_round, rules.discards, "赌注 {stake}: 弃牌次数");
        assert_eq!(
            run.no_blind_reward, rules.no_small_reward,
            "赌注 {stake}: 小盲注不发奖金"
        );
        // 小盲注那一格该不该有钱, 与上面那个开关一并体现.
        assert_eq!(run.stake, stake, "赌注本身要记下来");
    }
}

/// 各档的盲注目标分数要与"查哪张表"对得上 —— 同一个底注, 档越高目标越大.
///
/// 要挑**底注 2** 看: 三张表的第一项都是 300, 所以底注 1 看不出档的差别
/// (第一版就是拿底注 1 去比, 断言写错了值, 反而以为是引擎不对).
#[test]
fn blind_targets_grow_with_the_scaling_table() {
    let target = |stake: i64| -> f64 {
        let mut run = RunState::new("STAKE", stake);
        run.start_run();
        run.ante = 2;
        run.blind_on_deck = BlindKind::Big;
        run.select_blind().expect("在选盲注阶段");
        run.blind.as_ref().expect("有盲注").chips
    };
    // 底注 2 的基准值: 档 1 是 800, 档 2 是 900, 档 3 是 1000; 大盲注再乘 1.5.
    assert_eq!(target(1), 1200.0, "档 1: 800 x1.5");
    assert_eq!(target(3), 1350.0, "档 2: 900 x1.5");
    assert_eq!(target(6), 1500.0, "档 3: 1000 x1.5");
    // 同一个档内的赌注之间不该有差别 (档是按 3 与 6 划的).
    assert_eq!(target(2), target(1), "赌注 2 与 1 同档");
    assert_eq!(target(5), target(3), "赌注 5 与 3 同档");
    assert_eq!(target(8), target(6), "赌注 8 与 6 同档");
}

/// 八档 x 十五副牌组各跑一局, 都要能走完而不崩, 且状态自洽.
///
/// 这一条铺的是"广度": 每一格都真的走一遍流程 (选盲注, 出牌, 结算, 商店, 下一个盲注),
/// 而不是只把参数读出来看一眼.
#[test]
fn every_stake_times_every_deck_runs_without_falling_over() {
    let env = EvalEnv::default();
    let mut played = 0usize;
    let mut farthest = 0i64;

    for stake in 1..=8 {
        for deck in DECKS {
            for seed in 0..3 {
                let name = format!("M{stake}{seed}");
                let mut run = RunState::new(&name, stake).with_deck(deck);
                run.start_run();
                let back = run.back_effect();
                let mut steps = 0;
                for _ in 0..300 {
                    match run.phase {
                        Phase::GameOver => break,
                        Phase::BlindSelect => {
                run.select_blind().expect("在选盲注阶段");
            }
                        Phase::SelectingHand => {
                            let cards: Vec<usize> = (0..run.hand.len().min(5)).collect();
                            if run.play(&cards, &env, back).is_err() {
                                break;
                            }
                        }
                        Phase::RoundEval => {
                            if run.cash_out().is_err() {
                                break;
                            }
                        }
                        Phase::Shop => {
                            if run.next_round().is_err() {
                                break;
                            }
                        }
                        Phase::BoosterOpened => {
                            if run.pick_from_pack(0).is_err() {
                                break;
                            }
                        }
                    }
                    steps += 1;

                    // 每一步之后状态都该自洽 —— 这些是"不变量", 不是"策略好不好的评价".
                    assert!(
                        run.hand.len() <= run.hand_size(),
                        "赌注 {stake} / {deck}: 手牌 {} 超过了上限 {}",
                        run.hand.len(),
                        run.hand_size()
                    );
                    assert!(
                        run.hands_left >= 0 && run.discards_left >= 0,
                        "赌注 {stake} / {deck}: 次数变成负数了"
                    );
                    assert!(
                        run.jokers.len() <= run.joker_capacity(),
                        "赌注 {stake} / {deck}: 小丑 {} 超过了槽位 {}",
                        run.jokers.len(),
                        run.joker_capacity()
                    );
                    assert!(
                        run.dollars.is_finite(),
                        "赌注 {stake} / {deck}: 钱变成了 {}",
                        run.dollars
                    );
                    assert!(
                        run.chips.is_finite() && run.chips >= 0.0,
                        "赌注 {stake} / {deck}: 本回合筹码变成了 {}",
                        run.chips
                    );
                }
                assert!(steps > 0, "赌注 {stake} / {deck} / {name}: 一步都没走");
                played += 1;
                farthest = farthest.max(run.ante);
            }
        }
    }
    assert_eq!(played, 8 * 15 * 3, "每一格都要跑到");
    println!("矩阵: {played} 局, 最远底注 {farthest}");
}

/// 商店里那三个标记要**由赌注门槛挡住**, 而不是"掷了就会中".
///
/// 它的做法是按档跑很多个种子, 把商店里出现过的标记收集起来. 断言分两类:
/// "不该出现"的一侧是硬的 (闸门没关严会立刻抓到), "该出现"的一侧只看有没有撞到过一次
/// (它们是概率, 少一次不说明有问题, 但一个都没有就很可疑了).
#[test]
fn shop_flags_are_gated_by_the_stake() {
    // 每个赌注跑这么多局, 每局都把整条商店看一遍 (底注 1 那一底足够).
    const RUNS: usize = 40;

    for stake in 1..=8 {
        let rules = rules_for(stake);
        let mut seen_eternal = false;
        let mut seen_perishable = false;
        let mut seen_rental = false;

        for index in 0..RUNS {
            let seed = format!("S{stake}N{index}");
            let mut run = RunState::new(&seed, stake);
            run.start_run();
            let back = run.back_effect();
            // 走到第一个商店就够: 货架是在 `cash_out` 里铺的.
            let env = EvalEnv::default();
            for _ in 0..60 {
                match run.phase {
                    Phase::GameOver => break,
                    Phase::BlindSelect => {
                run.select_blind().expect("在选盲注阶段");
            }
                    Phase::SelectingHand => {
                        // 目标压到 1, 出一张就过 —— 这里只关心商店, 不关心打得好不好.
                        if let Some(blind) = run.blind.as_mut() {
                            blind.chips = 1.0;
                        }
                        let cards: Vec<usize> = (0..run.hand.len().min(1)).collect();
                        if cards.is_empty() || run.play(&cards, &env, back).is_err() {
                            break;
                        }
                    }
                    Phase::RoundEval => {
                        if run.cash_out().is_err() {
                            break;
                        }
                    }
                    Phase::Shop => break,
                    Phase::BoosterOpened => break,
                }
            }
            let Some(shop) = run.shop.as_ref() else {
                continue;
            };
            for card in &shop.jokers {
                seen_eternal |= card.eternal;
                seen_perishable |= card.perishable;
                seen_rental |= card.rental;
            }
        }

        // 闸门: 没开就不该出现.
        assert!(
            !seen_eternal || rules.eternals,
            "赌注 {stake} 没开永恒, 商店里却出现了"
        );
        assert!(
            !seen_perishable || rules.perishables,
            "赌注 {stake} 没开易腐, 商店里却出现了"
        );
        assert!(
            !seen_rental || rules.rentals,
            "赌注 {stake} 没开租赁, 商店里却出现了"
        );
        println!(
            "赌注 {stake}: 永恒 {} 易腐 {} 租赁 {} (该开: {}/{}/{})",
            seen_eternal, seen_perishable, seen_rental,
            rules.eternals, rules.perishables, rules.rentals
        );
    }

    // 反过来确认这些标记**真的会出现** (否则上面那几条断言等于没测: 一个恒假的集合
    // 当然不会被"闸门"抓到). 只看赌注 8 —— 那一档三个都开着.
    let mut any = BTreeSet::new();
    for index in 0..RUNS {
        let seed = format!("S8N{index}");
        let mut run = RunState::new(&seed, 8);
        run.start_run();
        let back = run.back_effect();
        let env = EvalEnv::default();
        for _ in 0..60 {
            match run.phase {
                Phase::GameOver => break,
                Phase::BlindSelect => {
                run.select_blind().expect("在选盲注阶段");
            }
                Phase::SelectingHand => {
                    if let Some(blind) = run.blind.as_mut() {
                        blind.chips = 1.0;
                    }
                    let cards: Vec<usize> = (0..run.hand.len().min(1)).collect();
                    if cards.is_empty() || run.play(&cards, &env, back).is_err() {
                        break;
                    }
                }
                Phase::RoundEval => {
                    if run.cash_out().is_err() {
                        break;
                    }
                }
                Phase::Shop => break,
                Phase::BoosterOpened => break,
            }
        }
        if let Some(shop) = run.shop.as_ref() {
            for card in &shop.jokers {
                let mut flags = String::new();
                if card.eternal {
                    flags.push('e');
                }
                if card.perishable {
                    flags.push('p');
                }
                if card.rental {
                    flags.push('r');
                }
                if !flags.is_empty() {
                    any.insert(flags);
                }
            }
        }
    }
    assert!(
        any.iter().any(|flags| flags.contains('e')),
        "赌注 8 这么多局里一次永恒都没抽到, 那一掷可能根本没掷"
    );
    println!("赌注 8 抽到过的标记: {any:?}");
}
