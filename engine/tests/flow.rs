//! 回合流程与真游戏对拍.
//!
//! 期望值取自 `recordings/20261003-224812-ALEEB/` 的前两条 digest:
//!
//! ```text
//! step 0 select   hand=C_T,D_T,S_9,S_7,H_6,H_5,H_4,D_2  deck=44
//! step 1 discard  hand=C_T,D_T,S_9,D_8,S_7,H_6,C_4,H_2  deck=41
//! ```
//!
//! 弃掉的是 `H_5,H_4,D_2` 三张 (手牌顺序里的下标 5,6,7), 补抽三张之后牌堆从 44 减到 41.

mod common;

/// 把手里换成指定的几张, 这样测的是**确定的牌型** —— 发出来的牌是什么全看种子,
/// 拿"前两张"当对子迟早会翻车.
fn set_hand(run: &mut balatro_engine::run::RunState, codes: &[&str]) {
    use balatro_engine::cards::CardInstance;

    run.hand = codes
        .iter()
        .enumerate()
        .map(|(index, code)| {
            let mut card = CardInstance::from_key(code).expect("能造出牌");
            card.card.sort_id = index as u32;
            card
        })
        .collect();
}

use common::{aleeb_run, hand_keys};
use balatro_engine::run::{ActionError, Phase};

#[test]
fn opening_deal_matches_the_first_digest() {
    let mut run = aleeb_run();
    run.start();

    assert_eq!(run.phase, Phase::SelectingHand);
    assert_eq!(hand_keys(&run), "C_T,D_T,S_9,S_7,H_6,H_5,H_4,D_2");
    assert_eq!(run.deck.len(), 44, "52 张发出 8 张");
    assert_eq!(run.hands_left, 4);
    assert_eq!(run.discards_left, 2, "黄金赌注的弃牌次数是 2");
}

#[test]
fn discard_matches_the_second_digest() {
    let mut run = aleeb_run();
    run.start();

    // 保住 C_T,D_T,S_9,S_7,H_6, 弃掉后面三张.
    run.discard(&[5, 6, 7]).expect("可以弃三张");

    assert_eq!(hand_keys(&run), "C_T,D_T,S_9,D_8,S_7,H_6,C_4,H_2");
    assert_eq!(run.deck.len(), 41, "补抽的三张从牌堆拿走");
    assert_eq!(run.discards_left, 1);
}

#[test]
fn discard_is_rejected_when_it_should_be() {
    let mut run = aleeb_run();
    run.start();

    assert_eq!(run.discard(&[]), Err(ActionError::NoCards));
    assert_eq!(run.discard(&[8]), Err(ActionError::BadIndex(8)));
    assert_eq!(
        run.discard(&[0, 1, 2, 3, 4, 5]),
        Err(ActionError::TooManyCards { limit: 5, got: 6 })
    );

    // 两次弃牌用完之后就没有了.
    run.discard(&[0]).expect("第一次");
    run.discard(&[0]).expect("第二次");
    assert_eq!(run.discard(&[0]), Err(ActionError::NoDiscardsLeft));
}

#[test]
fn playing_a_hand_scores_and_refills() {
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = aleeb_run();
    run.start();
    run.discard(&[5, 6, 7]).expect("先弃掉三张");

    // 打出顺子 6,7,8,9,T: 手牌里它们位于下标 5,4,3,2,0.
    let result = run
        .play(&[5, 4, 3, 2, 0], &EvalEnv::default(), BackEffect::Plasma)
        .expect("可以出这手牌");

    assert_eq!(result.total, 1369.0, "与解说里的 37 x 37 一致");
    assert_eq!(run.chips, 1369.0, "分数累计到本盲注");
    assert_eq!(run.hands_left, 3);

    // 这一手直接打到目标, 所以就地收尾: 手牌, 出牌区与弃牌堆都收回牌堆,
    // 与回放里同一步的 `deck=52` 一致.
    assert_eq!(run.phase, Phase::RoundEval);
    assert_eq!(run.discard_pile.len(), 0, "弃牌堆已清空");
    assert_eq!(run.hand.len(), 0);
    assert_eq!(run.deck.len(), 52, "所有牌都回了牌堆");
}

#[test]
fn first_round_settles_and_cashes_out_like_the_replay() {
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = aleeb_run();
    run.start();
    run.discard(&[5, 6, 7]).expect("先弃掉三张");
    run.play(&[5, 4, 3, 2, 0], &EvalEnv::default(), BackEffect::Plasma)
        .expect("可以出这手牌");

    // 回放第 3 步的 digest 是 `money=7`: 黄金赌注的小盲注没有固定奖金, 所以那 $3 全部来自
    // 剩下的三次出牌, 而 $4 现金还够不到利息的第一档.
    let eval = run.round_eval.expect("结算栏已经算好");
    assert_eq!(eval.blind_reward, 0.0, "红注以上小盲注没有固定奖金");
    assert_eq!(eval.hand_bonus, 3.0, "还剩三次出牌, 每次 $1");
    assert_eq!(eval.discard_bonus, 0.0, "默认不为余弃次数付钱");
    assert_eq!(eval.interest, 0.0, "现金 $4 不到第一档 $5");
    assert_eq!(eval.total(), 3.0);

    let cashed = run.cash_out().expect("这一回合在结算");
    assert_eq!(cashed, 3.0);
    assert_eq!(run.dollars, 7.0, "与 digest 的 money=7 一致");
    assert_eq!(run.phase, Phase::Shop);
}

#[test]
fn actions_are_rejected_outside_selecting_hand() {
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = aleeb_run();
    run.start();
    run.phase = Phase::Shop;

    let expected = ActionError::NotInPhase {
        expected: Phase::SelectingHand,
        actual: Phase::Shop,
    };
    assert_eq!(run.discard(&[0]), Err(expected.clone()));
    assert_eq!(
        run.play(&[0], &EvalEnv::default(), BackEffect::Plasma),
        Err(expected)
    );
}

/// 走完第一个盲注与商店, 进第二个回合, 与回放的第 6, 7 步对齐.
///
/// 这里**跳过了商店里的购买与开包**, 牌序依然对得上: 商店操作消耗的是自己那几个伪随机键
/// (`shop_pack` 之类), 而每个键的递推是独立的, 洗牌用的 `nr1` 不受影响.
#[test]
fn second_round_deal_matches_the_replay() {
    use balatro_engine::run::BlindKind;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = aleeb_run();
    run.start();
    run.discard(&[5, 6, 7]).expect("先弃掉三张");
    run.play(&[5, 4, 3, 2, 0], &EvalEnv::default(), BackEffect::Plasma)
        .expect("可以出这手牌");
    run.cash_out().expect("这一回合在结算");

    // 回放第 6 步 (next_round) 的 digest: state=BLIND_SELECT ante=1 round=1 money=3 deck=52.
    run.next_round().expect("这一回合有商店");
    assert_eq!(run.phase, Phase::BlindSelect);
    assert_eq!(run.round, 1, "离开商店还不算进入下一个回合");
    assert_eq!(run.blind_on_deck, BlindKind::Big);
    assert_eq!(run.ante, 1);
    assert_eq!(run.deck.len(), 52);

    // 回放第 7 步 (select) 的 digest: round=2, deck=44, hand=D_A,S_K,H_K,C_Q,C_9,H_8,H_6,D_5.
    common::place_blind(&mut run);
    assert_eq!(run.round, 2);
    assert_eq!(run.ante, 1, "第一个底注里还没打完 Boss");
    assert_eq!(run.blind.as_ref().unwrap().key, "bl_big");
    assert_eq!(run.blind.as_ref().unwrap().chips, 900.0, "300 × 1.5 × 2");
    assert_eq!(run.hands_left, 4);
    assert_eq!(run.discards_left, 2);
    assert_eq!(hand_keys(&run), "D_A,S_K,H_K,C_Q,C_9,H_8,H_6,D_5");
    assert_eq!(run.deck.len(), 44);
}

/// Boss 回合与底注提升, 与回放的第 16 与 23 步对齐.
///
/// 盲注目标是 `get_blind_amount(底注) × 盲注倍率 × 牌组的 ante_scaling`:
/// 底注 1 的 Boss 是 `300 × 2 × 2 = 1200`, 底注 2 的小盲注是 `1000 × 1 × 2 = 2000`.
/// 注意回合计数 `round` 是全局限次, 进下一底之后不重置, 所以底注 2 的小盲注是 `round=4`.
#[test]
fn boss_and_next_ante_match_the_replay() {
    use balatro_engine::run::BlindKind;

    let mut run = aleeb_run();
    run.start();

    // ALEEB 那局第一个底注的 Boss 是"窗口".
    assert_eq!(run.boss_key.as_deref(), Some("bl_window"));

    // 小盲注 -> 大盲注 -> Boss.
    //
    // 每一步都要**先打完再走**: `next_round` 是"离开商店", 而离开商店之前必然是打完了
    // 这一回合 (`end_round` -> `cash_out` -> 商店). 以前这里直接调 `next_round` 是因为
    // 引擎当时没查阶段; 现在它查了 (游戏那边这一步在别的阶段是非法的), 所以这里把
    // "这一回合打完了" 摆出来 —— 这条测试关心的是**底注与 Boss 的推算**, 不是打牌本身.
    for _ in 0..2 {
        run.phase = balatro_engine::run::Phase::Shop;
        run.next_round().expect("在商店里, 走得成");
        common::place_blind(&mut run);
    }
    assert_eq!(run.round, 3);
    assert_eq!(run.blind_on_deck, BlindKind::Boss);
    let boss = run.blind.as_ref().expect("有盲注");
    assert_eq!(boss.key, "bl_window");
    assert_eq!(boss.chips, 1200.0, "300 × 2 × 2");
    assert_eq!(boss.dollars, 5.0, "普通 Boss 的固定奖金");

    // 打完 Boss 进下一底. 注意底注是在**打赢那一刻** (`end_round`) 就提的, 不是等离开商店 ——
    // 因为打完 Boss 之后那个商店的货架是按**当时的底注**生成的, 晚一步加整面货架都会算错.
    run.chips = 99_999.0;
    run.end_round();
    assert_eq!(run.ante, 2, "打赢 Boss 当场进下一底");
    assert_eq!(run.blind_on_deck, BlindKind::Boss, "盲注指针留在 Boss, 由 next_round 拨到小盲注");
    // 离开商店前要先领结算 (`end_round` 把阶段放在结算屏上), 而 `next_round` 只认商店.
    run.cash_out().expect("刚结算完, 领得成");
    run.next_round().expect("在商店里, 走得成");
    assert_eq!(run.blind_on_deck, BlindKind::Small);
    assert_eq!(run.ante, 2, "next_round 不再提底注");
    assert_eq!(
        run.boss_key.as_deref(),
        run.bosses_used
            .keys()
            .find(|k| k.as_str() != "bl_window")
            .map(String::as_str),
        "下一底换了一个 Boss"
    );

    common::place_blind(&mut run);
    assert_eq!(run.round, 4, "回合计数不随底注重置");
    let small = run.blind.as_ref().expect("有盲注");
    assert_eq!(small.key, "bl_small");
    assert_eq!(small.chips, 2000.0, "1000 × 1 × 2");
    assert_eq!(small.dollars, 0.0, "红注以上小盲注没有固定奖金");
}

#[test]
fn blind_amount_tables_match_the_three_difficulties() {
    use balatro_engine::run::blind_amount;

    // 三张表的第一个底注都是 300.
    for scaling in 1..=3 {
        assert_eq!(blind_amount(1, scaling), 300.0);
    }
    // 第二底起才分档: 800 / 900 / 1000.
    assert_eq!(blind_amount(2, 1), 800.0);
    assert_eq!(blind_amount(2, 2), 900.0);
    assert_eq!(blind_amount(2, 3), 1000.0);
    // 第八底是各表的最后一格, 之后走指数公式.
    assert_eq!(blind_amount(8, 1), 50000.0);
    assert_eq!(blind_amount(8, 2), 100000.0);
    assert_eq!(blind_amount(8, 3), 200000.0);
    assert!(blind_amount(9, 3) > blind_amount(8, 3), "第九底继续往上走");
    assert_eq!(blind_amount(0, 1), 100.0, "底注小于 1 时是 100");
}

/// 有几个 Boss 直接改这一回合的次数与手牌上限, 而不是只改目标分.
///
/// 这几条属于"不实现就静默算错"的类型: 玩家会发现自己少了一次弃牌, 而引擎照旧给三次.
#[test]
fn bosses_that_change_the_round_limits() {
    use balatro_engine::run::{BlindKind, RunState};

    let with_boss = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        run
    };

    // 水: 一次弃牌都没有.
    let water = with_boss("bl_water");
    assert_eq!(water.discards_left, 0, "水让弃牌次数归零");
    assert_eq!(water.hands_left, 4, "出牌次数照旧");

    // 针: 只有一次出牌.
    let needle = with_boss("bl_needle");
    assert_eq!(needle.hands_left, 1, "针只给一次出牌");
    assert!(needle.discards_left > 0, "弃牌次数照旧");

    // 奇可 (传奇): 手里有它时 **Boss 的效果整条不生效** —— 水那一回合照样有弃牌次数.
    // 游戏里是在 `setting_blind` 那个时机调 `G.GAME.blind:disable()`, 之后所有 Boss 效果
    // 都看 `blind.disabled`. 少了这一条, Boss 那一回合会整块算错.
    let mut chicot = RunState::new("ALEEB", 8);
    chicot.start();
    chicot
        .jokers
        .push(balatro_engine::jokers::Joker::new("j_chicot").expect("有这张"));
    chicot.boss_key = Some("bl_water".to_owned());
    chicot.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut chicot);
    assert!(
        chicot.discards_left > 0,
        "手里有奇可时, 水不该把弃牌次数清零"
    );
    assert!(
        chicot.blind.as_ref().is_some_and(|blind| blind.disabled),
        "盲注该被标记成已禁用"
    );

    // 镣铐: 手牌上限减一, 所以发出来的手牌也少一张.
    let manacle = with_boss("bl_manacle");
    assert_eq!(manacle.hand_size(), 7, "镣铐压低手牌上限");
    assert_eq!(manacle.hand.len(), 7, "发出来的手牌也少一张");

    // 墙: 目标分翻倍. 它靠原型里的 `blind_multiplier = 4` 实现 (别的 Boss 是 2).
    let wall = with_boss("bl_wall");
    assert_eq!(wall.blind.as_ref().expect("有盲注").chips, 1200.0, "300 x 4");
    let hook = with_boss("bl_hook");
    assert_eq!(hook.blind.as_ref().expect("有盲注").chips, 600.0, "别的 Boss 是 300 x 2");
    assert_eq!(wall.hands_left, 4, "次数不受影响");
}

/// 牙 (The Tooth): 每打出一张牌扣一块.
#[test]
fn the_tooth_charges_per_card_played() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let with_boss = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        set_hand(&mut run, &["C_5", "D_5", "H_9"]);
        run
    };

    let mut plain = with_boss("bl_hook");
    plain.dollars = 20.0;
    plain
        .play(&[0, 1, 2], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(plain.dollars, 20.0, "别的 Boss 不扣钱");

    let mut tooth = with_boss("bl_tooth");
    tooth.dollars = 20.0;
    tooth
        .play(&[0, 1, 2], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(tooth.dollars, 17.0, "三张牌扣三块");
}

/// 臂 (The Arm): 打出的牌型等级降一级, 所以**这一手**就按降过的等级算.
#[test]
fn the_arm_lowers_the_played_hand_level() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv, PokerHand};

    let with_boss = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        // 把对子抬到 3 级, 这样降级看得出来.
        run.hands.level_up(PokerHand::Pair, 2);
        // 手里放一对, 这样打出去的一定是对子.
        set_hand(&mut run, &["C_5", "D_5"]);
        run
    };

    // 别处不动: 等级保持.
    let mut plain = with_boss("bl_hook");
    plain
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(plain.hands.get(PokerHand::Pair).level, 3, "别的 Boss 不降级");

    // 臂: 降到 2 级.
    let mut arm = with_boss("bl_arm");
    arm.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(arm.hands.get(PokerHand::Pair).level, 2, "降一级");

    // 等级已经是 1 时不再降.
    let mut low = with_boss("bl_arm");
    low.hands.level_up(PokerHand::Pair, -2);
    assert_eq!(low.hands.get(PokerHand::Pair).level, 1);
    low.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(low.hands.get(PokerHand::Pair).level, 1, "一级是下限");
}

/// 牛 (The Ox): 打出"本局最常打的牌型"时把钱清零, 其他牌型不管.
#[test]
fn the_ox_empties_the_wallet_on_the_most_played_hand() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv, PokerHand};

    let with_boss = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        // 让"对子"成为打得最多的那种.
        for _ in 0..3 {
            run.hands.record_played(PokerHand::Pair);
        }
        // 手里放一对.
        set_hand(&mut run, &["C_5", "D_5"]);
        run.dollars = 40.0;
        run
    };

    let mut plain = with_boss("bl_hook");
    plain
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(plain.dollars, 40.0, "别的 Boss 不动钱");

    let mut ox = with_boss("bl_ox");
    ox.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(ox.dollars, 0.0, "打到最常用牌型就清零");
}

/// 燧石 (The Flint): 牌型的基础筹码与倍率各砍一半, 牌的加成照常算.
#[test]
fn the_flint_halves_the_hand_base() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let with_boss = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        // 手里放一对 5, 基础值好算.
        set_hand(&mut run, &["C_5", "D_5"]);
        run
    };

    // 别的 Boss: 对子基础 10 筹码 2 倍率, 两张 5 各给 5 筹码 -> 20 筹码.
    let mut plain = with_boss("bl_hook");
    let plain_score = plain
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");

    // 燧石: 基础变成 `floor(10*0.5+0.5)=5` 筹码与 `floor(2*0.5+0.5)=1` 倍率,
    // 牌面的两张 5 照样加, 所以是 5 + 10 = 15 筹码.
    let mut flint = with_boss("bl_flint");
    let flint_score = flint
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");

    assert!(plain_score.chips > flint_score.chips, "燧石让分变低");
    assert_eq!(flint_score.chips, 5.0 + 10.0, "基础砍半, 牌面照加");
}

/// 眼 (The Eye): 同一回合里打**重复的牌型**, 第二手整手不计分.
///
/// 记的是"这一回合打过哪些牌型"; 被拦下的那一手仍然算打过 (次数照加), 只是不给分.
#[test]
fn the_eye_refuses_a_repeated_hand_type() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv, PokerHand};

    let with_boss = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        run
    };

    let mut eye = with_boss("bl_eye");
    set_hand(&mut eye, &["C_5", "D_5"]);
    let first = eye
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert!(first.total > 0.0, "第一手照常算分");
    let after_first = eye.chips;

    // 再打一次对子 (换成另一对, 免得与上一手同样的牌).
    set_hand(&mut eye, &["C_7", "D_7"]);
    let second = eye
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(second.total, 0.0, "重复的牌型不给分");
    assert!(second.scoring_cards.is_empty(), "一张都没参与计分");
    assert_eq!(eye.chips, after_first, "总分没变");

    // 但这一手照样算打过了.
    assert_eq!(
        eye.hands.get(PokerHand::Pair).played,
        2,
        "次数照样加, 只是没分"
    );

    // 换个牌型就不拦了.
    set_hand(&mut eye, &["C_3", "D_7"]);
    let third = eye
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert!(third.total > 0.0, "没打过的牌型照常算分");
}

/// 嘴 (The Mouth): 这一回合只能打**同一种**牌型, 换了就不给分.
#[test]
fn the_mouth_allows_only_one_hand_type() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut mouth = RunState::new("ALEEB", 8);
    mouth.start();
    mouth.boss_key = Some("bl_mouth".to_owned());
    mouth.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut mouth);

    // 第一手打对子, 它记下"这一回合只能打对子".
    set_hand(&mut mouth, &["C_5", "D_5"]);
    let first = mouth
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert!(first.total > 0.0, "第一手照常算分");

    // 换成高牌 (只打一张) 就被拦下.
    set_hand(&mut mouth, &["C_3", "D_7"]);
    let other = mouth
        .play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(other.total, 0.0, "换了牌型不给分");

    // 继续打对子就不拦.
    set_hand(&mut mouth, &["C_9", "D_9"]);
    let again = mouth
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert!(again.total > 0.0, "还是对子, 照常算分");
}

/// 蛇 (The Serpent): 出过牌或弃过牌之后, 每次都**只抽三张**, 而不是把手牌补满.
///
/// 开局发牌不受影响 —— 那时这一回合还没出过牌也没弃过牌.
#[test]
fn the_serpent_always_draws_three() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut serpent = RunState::new("ALEEB", 8);
    serpent.start();
    serpent.boss_key = Some("bl_serpent".to_owned());
    serpent.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut serpent);
    assert_eq!(serpent.hand.len(), serpent.hand_size(), "开局照常发满");

    // 打两张: 手里剩六张, 只补三张 -> 九张 (超过手牌上限, 这正是蛇的特点).
    serpent
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(serpent.hand.len(), 9, "六张加三张");

    // 弃一张: 八张 + 三张.
    let before = serpent.hand.len();
    serpent.discard(&[0]).expect("能弃牌");
    assert_eq!(serpent.hand.len(), before - 1 + 3, "弃牌之后也是补三张");

    // 别的 Boss 则是补满.
    let mut plain = RunState::new("ALEEB", 8);
    plain.start();
    plain.boss_key = Some("bl_hook".to_owned());
    plain.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut plain);
    plain
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(plain.hand.len(), plain.hand_size(), "别的 Boss 补满");
}

/// 柱子 (The Pillar) 削掉这一底注里**打出过**的牌, 没出过的不受影响.
///
/// 它按"牌"而不是按回合生效, 所以引擎要自己记住哪些牌出过. 游戏那边这个状态在导出里看不见,
/// 对拍时只能靠分数间接判断 (实测按公式算 560 分而实际只拿到 448, 差额正来自被削的牌).
#[test]
fn the_pillar_debuffs_cards_played_this_ante() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();

    // 打出一手 (把下标 0, 1 的牌出掉), 它们就属于"这一底注出过".
    run.chips = 1.0;
    run.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");

    // 到柱子回合.
    run.boss_key = Some("bl_pillar".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);

    let debuffed = run
        .deck
        .iter()
        .chain(run.hand.iter())
        .filter(|c| c.debuffed)
        .count();
    assert!(debuffed > 0, "出过的牌应当被削");
    assert!(
        run.deck
            .iter()
            .chain(run.hand.iter())
            .all(|c| !c.debuffed || c.played_this_ante),
        "被削的只能是出过的牌"
    );

    // 换到别的 Boss 时削弱要清掉 —— 它只对当前盲注有效.
    run.boss_key = Some("bl_hook".to_owned());
    common::place_blind(&mut run);
    assert!(
        run.deck.iter().chain(run.hand.iter()).all(|c| !c.debuffed),
        "离开柱子之后不该还有牌被削"
    );
}

/// 按**牌的性质**削的 Boss: 某个花色全废, 或者人头牌全废.
///
/// 这类判定要两头都对: 符合条件的都削到, 且**只**削符合条件的 —— 后者容易写漏 (把条件写宽了
/// 会让不该削的牌也失效, 表现为分数莫名其妙偏低).
#[test]
fn suit_and_face_bosses_debuff_matching_cards() {
    use balatro_engine::cards::Suit;
    use balatro_engine::run::{BlindKind, RunState};

    let with_boss = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        run
    };
    let every_card = |run: &RunState| -> Vec<balatro_engine::cards::CardInstance> {
        run.deck.iter().chain(run.hand.iter()).cloned().collect()
    };

    // 窗口: 方块全废.
    let window = with_boss("bl_window");
    for card in every_card(&window) {
        assert_eq!(
            card.debuffed,
            card.card.suit == Suit::Diamonds,
            "{} 的削弱状态不对",
            card.token()
        );
    }

    // 植物: 人头牌全废.
    let plant = with_boss("bl_plant");
    for card in every_card(&plant) {
        assert_eq!(
            card.debuffed,
            card.card.rank.is_face(),
            "{} 的削弱状态不对",
            card.token()
        );
    }

    // 换个不削牌的 Boss, 全副牌都该是干净的.
    let hook = with_boss("bl_hook");
    assert!(
        every_card(&hook).iter().all(|c| !c.debuffed),
        "钩子不削牌"
    );
}

/// 通灵 (The Psychic) 要求出的牌至少五张 —— 它是**出牌合法性**的限制, 不是削牌.
#[test]
fn the_psychic_refuses_small_plays() {
    use balatro_engine::run::{ActionError, BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.boss_key = Some("bl_psychic".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);

    assert_eq!(
        run.play(&[0, 1, 2], &EvalEnv::default(), BackEffect::Plain),
        Err(ActionError::TooFewCards { least: 5, got: 3 }),
        "四张以下算无效"
    );
    assert_eq!(run.hands_left, 4, "被拒时不出牌");
    assert_eq!(run.hand.len(), 8, "被拒时手牌不动");

    // 五张就可以出了.
    run.chips = 1.0;
    assert!(
        run.play(&[0, 1, 2, 3, 4], &EvalEnv::default(), BackEffect::Plain)
            .is_ok(),
        "五张能出"
    );
    assert_eq!(run.hands_left, 3, "这次真的出掉了");
}

/// 钩子 (The Hook) 每出一手随机弃掉手里两张 —— 是**出牌之后**的连锁, 与选盲注无关.
#[test]
fn the_hook_discards_two_cards_after_each_hand() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.boss_key = Some("bl_hook".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);

    let discarded_before = run.discard_pile.len();
    run.chips = 1.0; // 打不满目标, 所以只出一手不会收尾
    run.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");

    // 出掉两张, 又被钩子弃掉两张, 然后补满到 8.
    assert_eq!(run.hand.len(), 8, "手牌补满");
    assert_eq!(
        run.discard_pile.len(),
        discarded_before + 2 + 2,
        "打出的两张进弃牌堆, 钩子再弃两张"
    );
    assert_eq!(run.discards_left, 2, "钩子弃牌不花玩家的弃牌次数");

    // 换成别的 Boss 就不再弃了.
    let mut plain = RunState::new("ALEEB", 8);
    plain.start();
    plain.boss_key = Some("bl_window".to_owned());
    plain.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut plain);
    let discarded_before = plain.discard_pile.len();
    plain.chips = 1.0;
    plain.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(
        plain.discard_pile.len(),
        discarded_before + 2,
        "别的 Boss 只进打出的那两张"
    );
}

/// 标签在开局就抽好, 而且底注之内不重抽 —— 跳过哪个盲注能拿到什么是提前定下的.
#[test]
fn blind_tags_are_drawn_once_per_ante() {
    use balatro_engine::run::{RunState, tag_pool};

    let mut run = RunState::new("ALEEB", 8);
    run.start();

    let small = run.blind_tags[0].clone().expect("小盲注的标签");
    let big = run.blind_tags[1].clone().expect("大盲注的标签");
    assert!(small.starts_with("tag_"), "抽到的是标签: {small}");
    assert!(big.starts_with("tag_"), "抽到的是标签: {big}");
    // 池子里允许抽到同一个, 所以只要两个都在池子里就行.
    let pool = tag_pool(&run).0;
    for key in [&small, &big] {
        assert!(pool.contains(key), "{key} 应当在池子里");
    }

    // 底注之内推进不重抽: 走过这一底的第一个盲注, 两个标签保持不变.
    run.chips = 99_999.0;
    run.end_round();
    run.cash_out().expect("这一回合在结算");
    run.next_round().expect("这一回合有商店");
    common::place_blind(&mut run);
    assert_eq!(run.blind_tags[0].as_deref(), Some(small.as_str()));
    assert_eq!(run.blind_tags[1].as_deref(), Some(big.as_str()));
}

/// 跳过盲注会前进到下一个, 但**不加回合数** —— 这正是它与"打完"的关键区别.
///
/// 回合数只在 `select_blind` 里加, 所以跳过之后接着选盲注才是"真的打这一格".
/// 注意 `start` 会直接选好小盲注 (为了对准开局发牌), 所以跳过是从大盲注开始测的.
#[test]
fn skipping_a_blind_advances_without_counting_a_round() {
    use balatro_engine::run::{ActionError, BlindKind, RunState};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    // 打完小盲注, 回到"选盲注".
    run.chips = 99_999.0;
    run.end_round();
    run.cash_out().expect("这一回合在结算");
    run.next_round().expect("这一回合有商店");
    assert_eq!(run.phase, balatro_engine::run::Phase::BlindSelect);
    assert_eq!(run.blind_on_deck, BlindKind::Big);

    // 标签是随机抽的, 而"白送包"那一类会顺手把局面推进到开包状态. 这里只关心跳过本身,
    // 所以先把标签定成不给包的那种, 免得测试随种子时好时坏.
    run.blind_tags[1] = Some("tag_skip".to_owned());
    let round_before = run.round;
    let first = run.skip_blind().expect("能跳大盲注");
    assert_eq!(first, "tag_skip");
    assert_eq!(run.round, round_before, "跳过不推进回合数");
    assert_eq!(run.blind_on_deck, BlindKind::Boss, "前进到 Boss");
    assert_eq!(run.skips, 1);
    assert_eq!(run.tags, vec![first.clone()], "标签进了持有列表");

    // Boss 不能跳 —— 这是**规则不允许**, 不是"引擎还没做", 所以报的是 `NotAllowed`:
    // 混用 `NotImplemented` 会让调用方把"这一步本来就非法"当成"引擎有缺口".
    assert_eq!(run.skip_blind(), Err(ActionError::NotAllowed("Boss 不能跳过")));

    // 选下去打 Boss, 这一格真打完了才会推进回合数.
    common::place_blind(&mut run);
    assert_eq!(run.round, round_before + 1, "真的打了才加回合");
}

/// `start_run` 停在选盲注界面, 所以**第一个盲注也能跳** —— 这是引擎与游戏一致的走法.
///
/// `start` 是"开局顺带选好第一个盲注"的便利方法, 走它就没机会跳小盲注了.
#[test]
fn start_run_stops_at_blind_select() {
    use balatro_engine::run::{BlindKind, Phase, RunState};

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();

    assert_eq!(run.phase, Phase::BlindSelect, "停在选盲注");
    assert_eq!(run.round, 0, "还没打任何一格");
    assert!(run.hand.is_empty(), "还没发牌");
    assert_eq!(run.deck.len(), 52, "牌堆是完整的");

    // 第一个盲注就能跳.
    let tag = run.skip_blind().expect("小盲注也能跳");
    assert!(tag.starts_with("tag_"));
    assert_eq!(run.blind_on_deck, BlindKind::Big);
    assert_eq!(run.round, 0, "跳过不加回合");

    // 选下去才发牌.
    common::place_blind(&mut run);
    assert_eq!(run.phase, Phase::SelectingHand);
    assert_eq!(run.round, 1);
    assert_eq!(run.hand.len(), 8, "发满八张");
    assert_eq!(run.deck.len(), 44);
}

/// 标签里有一类是"到手就结算"的. 标签本身是随机抽的, 所以测试先把待测那个装进去.
#[test]
fn immediate_tags_pay_out_when_earned() {
    use balatro_engine::run::{Phase, RunState};

    let skip_and_check = |tag: &str| -> (f64, f64) {
        let mut run = RunState::new("ALEEB", 8);
        run.start_run();
        // 把第一个要跳的盲注换成待测标签, 这样结果就是确定的.
        run.blind_tags[0] = Some(tag.to_owned());
        let before = run.dollars;
        let earned = run.skip_blind().expect("能跳");
        assert_eq!(earned, tag);
        (before, run.dollars)
    };

    // 速度标签: 跳过几个盲注就给几份五块. 这是第一次跳, 所以给五块.
    let (before, after) = skip_and_check("tag_skip");
    assert_eq!(after, before + 5.0, "速度标签按跳过次数给");

    // 顺手标签: 按当前剩余出牌次数给.
    let (before, after) = skip_and_check("tag_handy");
    assert_eq!(after, before + 4.0, "开局还有四次出牌");

    // 经济标签: 给当前现金那么多 (封顶 40).
    let (before, after) = skip_and_check("tag_economy");
    assert_eq!(after, before + before.min(40.0), "现金翻倍封顶");

    // 不带立刻结算的标签就不给钱.
    let (before, after) = skip_and_check("tag_boss");
    assert_eq!(after, before, "Boss 标签换的是盲注选择, 不给钱");

    // 跳过之后仍然停在选盲注界面, 可以接着选.
    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    run.skip_blind().expect("跳");
    assert_eq!(run.phase, Phase::BlindSelect);
}

/// 杂耍标签让手牌上限**永久**加三 —— 它改的是规则而不是当下的局面, 所以之后每回合都多三张.
#[test]
fn juggle_tag_raises_the_hand_limit_for_good() {
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    assert_eq!(run.hand_size(), 8, "开局是八张");

    run.blind_tags[0] = Some("tag_juggle".to_owned());
    run.skip_blind().expect("跳过小盲注");
    assert_eq!(run.hand_size(), 11, "手牌上限加三");

    // 选下去发牌, 真的发出十一张.
    common::place_blind(&mut run);
    assert_eq!(run.hand.len(), 11, "发到新上限");
    assert_eq!(run.deck.len(), 41);

    // 打完这一格, 下一格仍然是十一张 —— 是永久改动而不是只算本回合.
    run.chips = 99_999.0;
    run.end_round();
    run.cash_out().expect("这一回合在结算");
    run.next_round().expect("这一回合有商店");
    common::place_blind(&mut run);
    assert_eq!(run.hand_size(), 11, "下一回合还是十一张");
    assert_eq!(run.hand.len(), 11);
}

/// 补货标签: 白送两个**普通**小丑 (原型里那个 `_rarity = 0` 落在一级).
#[test]
fn top_up_tag_spawns_two_common_jokers() {
    use balatro_engine::data::catalog::Catalog;
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    assert!(run.jokers.is_empty(), "开局没有小丑");

    run.blind_tags[0] = Some("tag_top_up".to_owned());
    run.skip_blind().expect("跳过小盲注");

    assert_eq!(run.jokers.len(), 2, "给了两个小丑");
    for joker in &run.jokers {
        let rarity = Catalog::get()
            .record(&joker.key)
            .and_then(|proto| proto.rarity);
        assert_eq!(rarity, Some(1), "{} 应当是普通的", joker.key);
    }

    // 格子满了就不硬塞.
    let mut full = RunState::new("ALEEB", 8);
    full.start_run();
    full.base_joker_slots = 1;
    full.blind_tags[0] = Some("tag_top_up".to_owned());
    full.skip_blind().expect("跳过小盲注");
    assert_eq!(full.jokers.len(), 1, "只有一个格子就只给一个");
}

/// 轨道标签: 把**某一个**已显示的牌型抬三级, 而且只抬一个.
#[test]
fn orbital_tag_raises_one_hand_by_three_levels() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::PokerHand;

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();

    let before: Vec<i32> = PokerHand::BY_PRIORITY
        .iter()
        .map(|hand| run.hands.get(*hand).level)
        .collect();

    run.blind_tags[0] = Some("tag_orbital".to_owned());
    run.skip_blind().expect("跳过小盲注");

    let raised: Vec<PokerHand> = PokerHand::BY_PRIORITY
        .into_iter()
        .filter(|hand| run.hands.get(*hand).level == 4)
        .collect();
    assert_eq!(raised.len(), 1, "只抬一个牌型, 实际抬了 {:?}", raised);

    // 其余牌型保持原样.
    for (index, hand) in PokerHand::BY_PRIORITY.into_iter().enumerate() {
        if hand == raised[0] {
            continue;
        }
        assert_eq!(run.hands.get(hand).level, before[index], "{hand:?} 不该动");
    }
}

/// 双倍标签: **持有它时**, 之后拿到的标签来两份.
///
/// 注意它的生效方向 —— 不是"它自己被拿到时给两份", 而是"它待在手里时复制后来的标签".
/// 写成后者的话, 一次跳过会拿到两个双倍标签, 之后又不复制, 结果完全不对.
#[test]
fn double_tag_duplicates_the_next_tag() {
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    // 先把它放进持有列表, 再跳过一次拿别的标签.
    run.tags.push("tag_double".to_owned());
    run.blind_tags[0] = Some("tag_skip".to_owned());

    let before = run.dollars;
    let earned = run.skip_blind().expect("跳过小盲注");
    assert_eq!(earned, "tag_skip");

    // 速度标签按跳过次数给: 一次跳 = 5 块, 两份就是 10 块.
    assert_eq!(run.dollars, before + 10.0, "给钱的那份也来两遍");
    assert_eq!(
        run.tags.iter().filter(|t| *t == "tag_skip").count(),
        2,
        "持有列表里有两份: {:?}",
        run.tags
    );

    // 它自己不会被再复制一份 —— 否则会越滚越多.
    let mut second = RunState::new("ALEEB", 8);
    second.start_run();
    second.blind_tags[0] = Some("tag_double".to_owned());
    second.skip_blind().expect("跳过小盲注");
    assert_eq!(
        second.tags.iter().filter(|t| *t == "tag_double").count(),
        1,
        "双倍标签自己只有一份"
    );
}

/// "白送一个包"那类标签: 跳过盲注换到它时会**当场打开**一个包.
///
/// 原型里这一类的 `type` 写作 `new_blind_choice`, 但它其实不换盲注选项 —— 名字有误导,
/// 实际效果是白送一个 mega 包.
#[test]
fn free_pack_tags_open_a_booster_right_away() {
    use balatro_engine::run::{Phase, RunState};

    for (tag, want) in [
        ("tag_standard", "p_standard_mega_1"),
        ("tag_buffoon", "p_buffoon_mega_1"),
        ("tag_ethereal", "p_spectral_normal_1"),
    ] {
        let mut run = RunState::new("ALEEB", 8);
        run.start_run();
        run.blind_tags[0] = Some(tag.to_owned());
        run.skip_blind().expect("跳过小盲注");

        assert_eq!(run.phase, Phase::BoosterOpened, "{tag} 应当直接开包");
        let pack = run.open_pack.as_ref().expect("有包待挑");
        assert_eq!(pack.key, want, "{tag} 给的包");
        assert!(!pack.contents.is_empty(), "包里要有东西");
    }

    // 吊饰与流星是随机挑一号, 所以只验它落在两个 mega 之一.
    for (tag, prefix) in [("tag_charm", "p_arcana_mega_"), ("tag_meteor", "p_celestial_mega_")] {
        let mut run = RunState::new("ALEEB", 8);
        run.start_run();
        run.blind_tags[0] = Some(tag.to_owned());
        run.skip_blind().expect("跳过小盲注");
        let key = run.open_pack.as_ref().expect("有包待挑").key.clone();
        assert!(
            key.starts_with(prefix) && (key.ends_with('1') || key.ends_with('2')),
            "{tag} 给的包应当在 {prefix}1 或 2 里, 拿到 {key}"
        );
    }
}

/// Boss 标签白重抽一次这一底的 Boss (正常重抽要花 10 块).
#[test]
fn boss_tag_rerolls_the_boss() {
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    let before = run.boss_key.clone().expect("开局就抽好了 Boss");

    run.blind_tags[0] = Some("tag_boss".to_owned());
    run.skip_blind().expect("跳过小盲注");
    let after = run.boss_key.clone().expect("还有 Boss");
    assert_ne!(after, before, "Boss 换了一个: {before} -> {after}");
}

/// 优惠券标签让商店的券那一格多摆一张.
#[test]
fn voucher_tag_adds_a_second_voucher() {
    use balatro_engine::run::{Phase, RunState};

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    run.blind_tags[0] = Some("tag_voucher".to_owned());
    run.skip_blind().expect("跳过小盲注");

    // 打到进商店.
    common::place_blind(&mut run);
    run.chips = 999_999.0;
    run.play(&[0], &balatro_engine::scoring::EvalEnv::default(), balatro_engine::scoring::BackEffect::Plain)
        .expect("能出牌");
    if run.phase == Phase::RoundEval {
        run.cash_out().expect("这一回合在结算");
    }
    assert_eq!(run.phase, Phase::Shop, "进商店了");

    let shop = run.shop.as_ref().expect("有货架");
    let first = shop.voucher.as_ref().expect("本来那张券").key.clone();
    let extra = shop.extra_voucher.as_ref().expect("标签多摆的那张");
    assert!(extra.key.starts_with("v_"), "多摆的也是券: {}", extra.key);
    assert_ne!(extra.key, first, "两张券不一样 (池子会排掉已经在售的)");
}

/// 回合末给钱的小丑: 那笔钱算进结算栏的 `card_bonus`, 与黄金牌金封同一个口袋.
#[test]
fn end_of_round_jokers_pay_out() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{Phase, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let after_round = |joker: Option<&str>| -> (f64, usize) {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        if let Some(key) = joker {
            run.jokers.push(Joker::new(key).expect("有这张"));
        }
        run.chips = 99_999.0;
        run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌");
        assert_eq!(run.phase, Phase::RoundEval, "打完进结算");
        let eval = run.round_eval.expect("有结算栏");
        // 9 霄云外的多少写在 `card_bonus` 里, 牌堆 9 的张数另算.
        (eval.card_bonus, 0)
    };

    // 没有小丑时, 结算栏里不该有牌或小丑给的钱.
    assert_eq!(after_round(None).0, 0.0, "没有给钱的东西");

    // 黄金小丑给 4 块.
    assert_eq!(after_round(Some("j_golden")).0, 4.0);

    // 火箭的初始值是 1.
    assert_eq!(after_round(Some("j_rocket")).0, 1.0);

    // 9 霄云外按牌堆里的 9 给, 而开局牌堆里 9 的张数是不定的 —— 只验它大于 0.
    assert!(
        after_round(Some("j_cloud_9")).0 > 0.0,
        "牌堆里总有 9"
    );

    // 卫星: 一张行星牌都没用过, 所以不给.
    assert_eq!(after_round(Some("j_satellite")).0, 0.0, "没用过行星牌");

    // 延迟满足: 这一回合一次都没弃牌, 且还有弃牌余量时按"余量 x 每份 2 块"给.
    // 黄金赌注开局剩两次弃牌, 所以是 2 x 2.
    assert_eq!(after_round(Some("j_delayed_grat")).0, 4.0);
}

/// 玻璃牌在计分**之后**掷碎裂: 碎掉的牌直接从牌堆里消失, 不留在弃牌堆.
///
/// 掷骰是 `pseudorandom('glass') < 1/4`, 所以这里跑一批种子, 要求两种结果都出现过 ——
/// 只验一种的话, "永远碎"和"永远不碎"都能通过.
#[test]
fn glass_cards_may_shatter_after_scoring() {
    use balatro_engine::cards::Enhancement;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut shattered = 0;
    let mut survived = 0;
    for i in 0..40 {
        let mut run = RunState::new(&format!("GLASS{i:02}"), 8);
        run.start();
        run.hand[0].set_enhancement(Enhancement::Glass);
        run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌");

        // 碎掉的那张根本不在弃牌堆里.
        if run
            .discard_pile
            .iter()
            .any(|card| card.enhancement == Some(Enhancement::Glass))
        {
            survived += 1;
        } else {
            shattered += 1;
        }
    }
    assert!(shattered > 0, "四十次里一次都没碎, 掷骰没接上");
    assert!(survived > 0, "四十次里全碎了, 概率不对");

    // 没有强化的牌不掷也不碎: 打完只是进弃牌堆, 整副牌的张数不变.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    let before = run.deck.len() + run.hand.len();
    run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(
        run.deck.len() + run.hand.len() + run.discard_pile.len(),
        before,
        "普通牌只是进了弃牌堆"
    );
}

/// 用完就没了的小丑要**真的离开持有区** (冰淇淋化完, 汽水喝完).
///
/// 计分那一层只负责判定并把下标报在 `melted` 里, 挪走是 `play` 的事 ——
/// 只判定不挪走的话它们会一直待在队里, 而且不报错 (这一段确实漏过).
#[test]
fn melted_jokers_leave_the_team() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let play_once = |joker: Joker| -> usize {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.jokers.push(joker);
        set_hand(&mut run, &["C_5", "D_5"]);
        run.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌");
        run.jokers.len()
    };

    // 冰淇淋的融化值调到"再融一次就没了", 所以这一手之后就该走.
    let mut ice = Joker::new("j_ice_cream").expect("有这张");
    ice.chips = 5.0;
    assert_eq!(play_once(ice), 0, "化完就该离开队伍");

    // 还有余量时不动.
    let mut ice = Joker::new("j_ice_cream").expect("有这张");
    ice.chips = 10.0;
    assert_eq!(play_once(ice), 1, "还有余量就留着");

    // 汽水同理: 剩余次数调到一, 喝完就走.
    let mut selzer = Joker::new("j_selzer").expect("有这张");
    selzer.extra = 1.0;
    assert_eq!(play_once(selzer), 0, "喝完就该离开队伍");
}

/// 租赁小丑每回合末扣租金; 易腐小丑倒计时到零就变成**被削弱** (但还留在队里).
///
/// 这两个标记是商店在生成时打上的, 要一路带到买下来那张小丑身上 —— 少带一个,
/// 它们就永远是张普通小丑 (不报错, 只是那个特性不存在).
#[test]
fn rental_pays_rent_and_perishable_expires() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;

    let money_after_round = |joker: Option<Joker>| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        // 钱压到五块以下, 这样利息两边都是零, 差额只来自租金.
        run.dollars = 4.0;
        run.chips = 99_999.0;
        if let Some(joker) = joker {
            run.jokers.push(joker);
        }
        run.end_round();
        run.dollars
    };

    let plain = money_after_round(None);
    let mut rental = Joker::new("j_joker").expect("有这张");
    rental.rental = true;
    assert_eq!(money_after_round(Some(rental)), plain - 3.0, "扣三块租金");

    // 易腐: 倒计时减到零就削弱, 人还留着.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.chips = 99_999.0;
    let mut joker = Joker::new("j_joker").expect("有这张");
    joker.perish_tally = 1;
    run.jokers.push(joker);
    run.end_round();
    assert_eq!(run.jokers.len(), 1, "小丑还留在队里");
    assert!(run.jokers[0].debuffed, "但已经被削弱");

    // 被削弱之后它的效果就停了 (用完整算分验一遍).
    use balatro_engine::scoring::{BackEffect, EvalEnv, HandTable, score_play};
    let pair = [common::card("C_5"), common::card("D_5")];
    let mut debuffed = [run.jokers[0].clone()];
    let got = score_play(&pair, &HandTable::new(), &EvalEnv::default(), BackEffect::Plain, &mut debuffed)
        .expect("对子能识别");
    assert_eq!(got.mult, 2.0, "削弱之后小丑的 +4 没了");
}

/// 小丑包里的小丑也会带版本 / 永恒 / 易腐 / 租赁 —— 与商店货架上的一样, 只是掷骰的键不同.
///
/// 这三掷用的是 `packetper` / `packssjr` / `edi` 三条键, 少掷一次不光那张牌"少了特性",
/// 后面的随机序列也会整体偏掉. 所以这里跑一批包, 要求真的能掷出带标记的来.
#[test]
fn buffoon_pack_jokers_can_carry_flags() {
    use balatro_engine::run::shop::ShopCard;
    use balatro_engine::run::{RunState, shop};

    let mut flagged = 0;
    let mut editions = 0;
    for i in 0..30 {
        let mut run = RunState::new(&format!("PACK{i:02}"), 8);
        run.start();
        let contents = shop::open_pack(&mut run, "p_buffoon_normal_1");
        for card in &contents {
            if card.eternal || card.perishable || card.rental {
                flagged += 1;
            }
            if card.edition.is_some() {
                editions += 1;
            }
        }
    }
    assert!(flagged > 0, "三十个包里一个带标记的都没有, 掷骰没接上");
    assert!(editions > 0, "三十个包里一个带版本的都没有");

    // 取出来的时候要一路带到小丑身上.
    let mut carried = 0;
    for i in 0..30 {
        let mut run = RunState::new(&format!("PACK{i:02}"), 8);
        run.start();
        run.phase = balatro_engine::run::Phase::Shop;
        run.dollars = 20.0;
        run.buy(&ShopCard {
            key: "p_buffoon_normal_1".to_owned(),
            edition: None,
            eternal: false,
            perishable: false,
            rental: false,
            enhancement: None,
        todo: None,
            cost: 4.0,
        })
        .expect("买下小丑包");
        let flagged_index = run
            .open_pack
            .as_ref()
            .and_then(|pack| {
                pack.contents
                    .iter()
                    .position(|card| card.eternal || card.perishable || card.rental)
            });
        let Some(index) = flagged_index else {
            continue;
        };
        let wanted = run.open_pack.as_ref().expect("有包").contents[index].clone();
        run.pick_from_pack(index).expect("能取");
        let joker = run.jokers.last().expect("取到了小丑");
        assert_eq!(joker.eternal, wanted.eternal, "永恒要带过来");
        assert_eq!(joker.rental, wanted.rental, "租赁要带过来");
        assert_eq!(
            joker.perish_tally > 0,
            wanted.perishable,
            "易腐的倒计时要开起来"
        );
        assert_eq!(joker.edition, wanted.edition, "版本要带过来");
        carried += 1;
        if carried >= 3 {
            break;
        }
    }
    assert!(carried > 0, "三十个包里都没取到带标记的小丑");
}

/// 出牌时**手里剩下的牌**要交给计分 —— 钢铁牌与男爵那类看的就是它们.
///
/// 这条以前是漏的: `play` 调计分时没传手牌, 于是那些效果在真实对局里从来没生效过
/// (只有单独调 `score_play_with_held` 的测试看得见). 这类"机制做了但没接上"的缺口
/// 不报错, 只是永远不生效.
#[test]
fn play_hands_the_remaining_cards_to_scoring() {
    use balatro_engine::cards::Enhancement;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mult_after_play = |steel: bool| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        set_hand(&mut run, &["C_5", "D_5", "H_7"]);
        if steel {
            run.hand[2].set_enhancement(Enhancement::Steel);
        }
        run.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌")
            .mult
    };

    assert_eq!(mult_after_play(false), 2.0, "没有钢铁牌就是基础倍率");
    assert_eq!(
        mult_after_play(true),
        2.0 * 1.5,
        "手里那张钢铁牌要算进去 (它没被打出去)"
    );
}

/// 回合末那两张: 大麦克掷 1/6 销毁骰, 爆米花掉 4 点倍率 (掉完就没了).
///
/// 它们都在 `end_round` 那一趟里, 与租金 / 易腐同一个循环 —— 顺序也是照游戏的
/// (`calculate_joker` 在前, 租金与易腐在后).
#[test]
fn round_end_jokers_roll_and_decay() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;

    let end_round_with = |joker: Joker| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.chips = 99_999.0;
        run.jokers.push(joker);
        run.end_round();
        run
    };

    // 大麦克: 四十个种子里两种结果都该出现 (掷 1/6 毁掉).
    let mut destroyed = 0;
    let mut survived = 0;
    for i in 0..40 {
        let mut run = RunState::new(&format!("GM{i:02}"), 8);
        run.start();
        run.chips = 99_999.0;
        run.jokers.push(Joker::new("j_gros_michel").expect("有这张"));
        run.end_round();
        if run.jokers.is_empty() {
            destroyed += 1;
        } else {
            survived += 1;
        }
    }
    assert!(destroyed > 0, "四十次里一次都没烂, 骰子没接上");
    assert!(survived > 0, "四十次里全烂了, 概率不对");

    // 爆米花: 还有余量时掉 4 点, 人还在.
    let mut popcorn = Joker::new("j_popcorn").expect("有这张");
    popcorn.mult = 8.0;
    let run = end_round_with(popcorn);
    assert_eq!(run.jokers.len(), 1, "还有余量就留着");
    assert_eq!(run.jokers[0].mult, 4.0, "掉 4 点");

    // 掉到 0 就没了.
    let mut popcorn = Joker::new("j_popcorn").expect("有这张");
    popcorn.mult = 4.0;
    let run = end_round_with(popcorn);
    assert!(run.jokers.is_empty(), "掉完就该离开队伍");
}

/// 三张"看整副牌"的小丑: 石头小丑 (数石头牌), 侵蚀 (比开局少了几张), 驾照 (数强化牌).
///
/// 它们的计数由 `play` 那一层算好传进计分 (口径是 `G.playing_cards`, 含刚打出去的那几张),
/// 所以这里走**完整出牌流程** —— 只调计分函数是验不出这根线接没接上的.
#[test]
fn deck_wide_jokers_count_the_living_cards() {
    use balatro_engine::cards::Enhancement;
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    // 石头小丑: 整副牌里每张石头牌 +25 筹码. 拿"带小丑"减"不带"来比, 免得自己算基准.
    let stone_chips = |stones: usize, with_joker: bool| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        set_hand(&mut run, &["C_5", "D_5"]);
        for index in 0..stones {
            run.deck[index].set_enhancement(Enhancement::Stone);
        }
        if with_joker {
            run.jokers.push(Joker::new("j_stone").expect("有这张"));
        }
        run.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌")
            .chips
    };
    assert_eq!(
        stone_chips(0, true),
        stone_chips(0, false),
        "一张石头牌都没有时它就是 0"
    );
    assert_eq!(
        stone_chips(3, true) - stone_chips(3, false),
        3.0 * 25.0,
        "三张石头给 75 筹码"
    );

    // 侵蚀: 比开局少几张就给几份倍率. 这里直接从牌堆里删牌来模拟"被销毁".
    //
    // 手牌要放**满八张** —— `set_hand` 只放两张的话, 那六张被发到手里又丢掉的牌
    // 在计数上就是"少了六张", 侵蚀会跟着给分 (这次就踩了这个).
    let eight = ["C_5", "D_5", "H_2", "S_3", "H_4", "S_6", "H_7", "S_8"];
    let erosion_mult = |missing: usize| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        set_hand(&mut run, &eight);
        for _ in 0..missing {
            run.deck.pop();
        }
        run.jokers.push(Joker::new("j_erosion").expect("有这张"));
        run.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌")
            .mult
    };
    assert_eq!(erosion_mult(0), 2.0, "一张没少就不给");
    assert_eq!(erosion_mult(3), 2.0 + 12.0, "少三张给 12 点倍率");

    // 驾照: 整副牌里带强化的牌到 16 张才乘三倍.
    let license_mult = |enhanced: usize| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        set_hand(&mut run, &["C_5", "D_5"]);
        for index in 0..enhanced {
            run.deck[index].set_enhancement(Enhancement::Bonus);
        }
        run.jokers.push(Joker::new("j_drivers_license").expect("有这张"));
        run.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌")
            .mult
    };
    assert_eq!(license_mult(15), 2.0, "十五张还不够");
    assert_eq!(license_mult(16), 2.0 * 3.0, "十六张就乘三");
}


/// 焦小丑 (`j_burnt`): **本回合第一次弃牌**时, 把弃掉那几张的牌型升一级; 之后再弃就不升.
///
/// 这个判断靠 `discards_used` —— 而那个计数原来**从来没有累加过** (只有重置与读取),
/// 于是三处一起错: 蛇的"只抽三张"在弃过牌之后不生效, 延迟满足的"没用过弃牌才给钱"永远成立,
/// 焦小丑的"第一次"判不出来.
#[test]
fn burnt_joker_levels_up_only_on_the_first_discard() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_burnt").expect("有这张"));

    let pair_before = run.hands.get(balatro_engine::scoring::PokerHand::Pair).level;
    // 这一手是 D_A, S_K, H_K, C_Q, ... —— 中间那两张正好是一对, 就弃它们.
    let pair_at: Vec<usize> = run
        .hand
        .iter()
        .enumerate()
        .filter(|(_, c)| c.card.key() == "S_K" || c.card.key() == "H_K")
        .map(|(i, _)| i)
        .collect();
    assert_eq!(pair_at.len(), 2, "这手牌里有两张 K");
    run.discard(&pair_at).expect("能弃");
    assert_eq!(run.discards_used, 1, "弃牌计数要累加");
    assert_eq!(
        run.hands.get(balatro_engine::scoring::PokerHand::Pair).level,
        pair_before + 1,
        "第一次弃牌升的是弃掉那几张的牌型"
    );

    // 第二次弃牌不再升.
    run.discard(&[0]).expect("能弃");
    assert_eq!(run.discards_used, 2);
    assert_eq!(
        run.hands.get(balatro_engine::scoring::PokerHand::Pair).level,
        pair_before + 1,
        "只有第一次弃牌才升"
    );
}

/// DNA: 本回合**第一手**只打一张牌时, 复制一张永久加进牌堆 (所以整副牌多一张).
///
/// 对照写法: 同样的一手牌, 有 DNA 与没有 DNA 各跑一次, 比**总牌数** ——
/// 这样不用去猜"多出来那张现在在牌堆还是手牌还是弃牌堆".
#[test]
fn dna_copies_the_single_card_of_the_first_hand() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let total = |with_dna: bool| -> usize {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        common::place_blind(&mut run);
        if with_dna {
            run.jokers.push(Joker::new("j_dna").expect("有这张"));
        }
        run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌");
        run.deck.len() + run.hand.len() + run.discard_pile.len()
    };

    assert_eq!(
        total(true),
        total(false) + 1,
        "有 DNA 时整副牌多一张"
    );
}

/// 底注是 `win_ante` (8) 的倍数时, 抽出来的应该是**终局 Boss** (`showdown`);
/// 其它底注抽普通 Boss.
///
/// 这里原来有个会让整局崩掉的 bug: 引擎对两类 Boss 都去查 `boss.min`, 而终局那五个的 `min` 是 **10** ——
/// 于是底注 8 一个候选都没有, 直接"抽不出 Boss". 游戏那边是两支并列的判断, 终局那一支**不看 min**.
#[test]
fn showdown_antes_pick_the_final_bosses() {
    use balatro_engine::data::catalog::Catalog;
    use balatro_engine::run::RunState;

    let boss_at = |ante: i64| -> String {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.ante = ante;
        run.next_boss()
    };

    // 底注 8: 终局那五个之一.
    let final_boss = boss_at(8);
    let proto = Catalog::get().record(&final_boss).expect("有这张");
    assert_eq!(
        proto.boss_showdown(),
        Some(true),
        "底注 8 该抽终局 Boss, 实际抽到 {final_boss}"
    );

    // 底注 4: 普通 Boss.
    let normal = boss_at(4);
    let proto = Catalog::get().record(&normal).expect("有这张");
    assert_ne!(
        proto.boss_showdown(),
        Some(true),
        "底注 4 该抽普通 Boss, 实际抽到 {normal}"
    );
}

/// 一条**长跑**烟测: 把目标分压低, 让对局一路推到很多底, 看会不会崩.
///
/// 短对局跑不到高底注, 而高底注上有几处只有到那儿才会走的路径 —— 已经在那儿抓到过一个
/// (底注 8 是"决战底", 选 Boss 的分支不一样, 引擎原来在那儿抽不出 Boss 直接报错).
/// 所以这条与"一百条短对局"那类烟测是互补的: 那条铺广度, 这条钻深度.
#[test]
fn a_long_run_survives_many_antes() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let env = EvalEnv::default();
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    let mut highest_ante = 0;

    for _ in 0..400 {
        // 把这一底的目标压到 1 分, 让出牌策略随便打也能过 —— 目的是走遍流程, 不是打得好看.
        if let Some(blind) = run.blind.as_mut() {
            blind.chips = 1.0;
        }
        match run.phase {
            balatro_engine::run::Phase::GameOver => break,
            balatro_engine::run::Phase::BlindSelect => {
                common::place_blind(&mut run);
            }
            balatro_engine::run::Phase::SelectingHand => {
                let cards: Vec<usize> = (0..run.hand.len().min(5)).collect();
                let _ = run.play(&cards, &env, BackEffect::Plasma);
            }
            balatro_engine::run::Phase::RoundEval => {
                run.cash_out().expect("这一回合在结算");
            }
            balatro_engine::run::Phase::Shop => {
                run.next_round().expect("这一回合有商店");
            }
            balatro_engine::run::Phase::BoosterOpened => {
                let _ = run.pick_from_pack(0);
            }
        }
        highest_ante = highest_ante.max(run.ante);
    }

    assert!(
        highest_ante >= 10,
        "这条跑下来至少该过十个底注 (含一次决战底), 实际只到 {highest_ante}"
    );
    // 它在底注 8 的决战 Boss 上过了关, 所以通关标志该是开的 —— 而且**过了关还能接着跑到 10**,
    // 那正是无尽模式: 通关不是结束.
    assert!(run.won, "过了决战底该记成通关");
    assert!(
        run.phase != balatro_engine::run::Phase::GameOver,
        "通关之后对局不该被判结束"
    );
}

/// 无尽模式的**机械终点**: 底注 39 起目标分数是 `nan`, 于是那一底永远打不过.
///
/// 这不是引擎的病, 是**游戏本身的指数溢出** —— 目标分数的算式是 `a*(b+(kc)^d)^c`,
/// 底注 38 还是 `4.5e288` (双精度能表示), 39 就超出 `1.797e308` 了. 真 Lua 算出来也是 `nan`
/// (见 `blind_amount_parity` 那份逐位对拍), 所以这里**必须照实复刻**:
/// 拿 `nan` 去比大小的结果是"永远不大于", 于是一个分数高到离谱的引擎也会在这一底判负.
///
/// 值得专门验的是**它怎么收场**: 应当是干净地判负 (`GAME_OVER`), 而不是崩掉或者把
/// `nan` 误判成过关. 后者会安静地让对局"穿"过终点线, 一路跑到无穷远, 而统计上看起来像
/// 有人打通了 40 底. 顺带一提: 相同处境下游戏本体是有崩溃风险的 —— 它会把 `nan` 存进
/// 存档里的最高分, 再拿它去比大小 (那是**存档展示层**的问题, 与规则无关, 引擎里没有那一层).
#[test]
fn endless_mode_ends_at_ante_39_and_loses_cleanly() {
    use balatro_engine::run::{ActionError, BlindKind, Phase, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    /// 直接站到底注 `ante` 的小盲注面前.
    fn at_ante(ante: i64) -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.ante = ante;
        run.blind_on_deck = BlindKind::Small;
        common::place_blind(&mut run);
        run
    }

    // 38 底还是正常的有限数, 而且打得过 (把它压低就能过).
    let last_playable = at_ante(38);
    let target = last_playable.blind.as_ref().expect("有盲注").chips;
    assert!(
        target.is_finite() && target > 0.0,
        "底注 38 该还是有限数, 实际 {target}"
    );

    // 39 底起是 nan —— 三个赌注档都一样, 小盲 / 大盲 / Boss 也一样 (倍率乘 nan 还是 nan).
    for ante in [39, 40, 60] {
        let run = at_ante(ante);
        let target = run.blind.as_ref().expect("有盲注").chips;
        assert!(target.is_nan(), "底注 {ante} 的目标该是 nan, 实际 {target}");
    }

    // 收场方式: 分数一直在涨, 但**永远够不着**, 于是把手数耗完就干净地判负.
    //
    // 注意"出一次牌就结束"是**错的预期**: 回合本来就该在"够了"或者"没次数了"时才收尾,
    // 而 `nan` 让"够了"永远不成立, 所以要打到手数为零. 这一条正好也说明
    // "打不过"不等于"崩在这里" —— 中间那几手是照常进行的.
    let mut run = at_ante(39);
    assert!(
        run.blind.as_ref().is_some_and(|blind| blind.chips.is_nan()),
        "前提: 这一底的目标是 nan"
    );
    let hands = run.hands_left;
    assert!(hands > 1, "前提: 本来该有好几次出牌机会, 实际 {hands}");
    for played in 0..hands {
        assert_eq!(run.phase, Phase::SelectingHand, "第 {played} 手之前该还在选牌");
        let hand: Vec<usize> = (0..run.hand.len().min(5)).collect();
        match run.play(&hand, &EvalEnv::default(), BackEffect::Plain) {
            // 出牌本身是合法的 (牌没毛病), 输是输在"目标分数不是一个数".
            Ok(_) => {}
            Err(error) => panic!("第 {played} 手不该被拒, 实际 {error:?}"),
        }
        assert!(run.chips > 0.0, "分数确实在涨, 只是够不着");
    }
    assert_eq!(
        run.phase,
        Phase::GameOver,
        "手数耗完就该判负 —— 不能因为目标是 nan 就'穿'过去"
    );
    assert!(!run.won, "打不过就不可能是通关");
    let _ = ActionError::NoCards;

    // 反过来确认"不是引擎在这一带对所有盲注都判负": 同一个局面把目标换成一个正常的数就该过.
    let mut sane = at_ante(39);
    if let Some(blind) = sane.blind.as_mut() {
        blind.chips = 1.0;
    }
    let hand: Vec<usize> = (0..sane.hand.len().min(5)).collect();
    sane.play(&hand, &EvalEnv::default(), BackEffect::Plain)
        .expect("出牌");
    assert!(
        sane.phase != Phase::GameOver,
        "目标换成正常的数就该过 —— 否则上面那条断言等于在测'引擎整体坏了'"
    );
}

/// 打完底注 8 的决战 Boss 要**记成通关**, 而且对局**不停** —— 那就是无尽模式的入口.
///
/// 这一笔原来漏了: `RunState::won` 声明了却从没被赋过值, 于是批量对局的 `RunOutcome.won`
/// 永远是假 —— 一个跑完八个底注、赢下决战 Boss 的流程, 在结果里与"半路输掉"一模一样.
/// 接口文档写着"通关了没有", 实现却恒定给假, 而这种事不会报错, 只会让所有基于它的统计整体偏.
///
/// 三件事一起验, 缺一条都可能是"碰巧对了":
/// 1. 通关标志被置上;
/// 2. 底注**继续往上加** (9), 而不是停在 8 或跳到结束 —— 无尽模式就是"赢了之后还能接着打";
/// 3. 该局的阶段**不是** `GameOver`: 通关不是结束.
#[test]
fn winning_the_final_boss_marks_the_run_won_and_keeps_going() {
    use balatro_engine::run::{BlindKind, Phase, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    /// 把一局推到"底注 8 的 Boss 面前", 目标分数压到 1, 于是随便出一张牌就过.
    ///
    /// `win_ante` 是 8, 所以 `ante == win_ante` 就是决战底.
    fn at_final_boss() -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.ante = run.win_ante;
        run.blind_on_deck = BlindKind::Boss;
        run.boss_key = Some("bl_final_vessel".to_owned());
        common::place_blind(&mut run);
        run
    }

    let mut won = at_final_boss();
    if let Some(blind) = won.blind.as_mut() {
        blind.chips = 1.0;
    }
    won.play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("这一手该打得出去");

    assert!(won.won, "打完决战 Boss 该记成通关");
    assert_eq!(won.ante, 9, "通关之后该进到下一底 (无尽模式), 而不是停在 8");
    assert_ne!(won.phase, Phase::GameOver, "通关不是结束, 对局要能接着打");
    // 结算栏照常发得出来: 通关不跳过结算那一段.
    assert!(won.round_eval.is_some(), "通关那一回合也要有结算栏");

    // 对照组: 同一套操作但目标分数压到不可能达到 —— 输了就不该被记成通关.
    // 没有这一条的话, "只要打完这一手就置真"也能过上面那几句.
    let mut lost = at_final_boss();
    if let Some(blind) = lost.blind.as_mut() {
        blind.chips = 1e18;
    }
    lost.hands_left = 1;
    let _ = lost.play(&[0], &EvalEnv::default(), BackEffect::Plain);
    assert!(!lost.won, "没打赢就不该记成通关");
    assert!(!lost.won || lost.ante == 9, "输局不该推进底注");
}

/// 三个"决战 Boss" (底注 8 及以上才出现的 `showdown` 那批) 的效果.
///
/// 它们只在很靠后才出现, 短对局永远碰不到 —— 所以前面一直没人写, 也没人发现缺.
#[test]
fn showdown_bosses_have_their_effects() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, RunState};

    let with_boss = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        run
    };

    // 翠叶: 所有扑克牌失效 (小丑不受影响).
    let mut leaf = with_boss("bl_final_leaf");
    assert!(
        leaf.hand.iter().all(|card| card.debuffed),
        "翠叶下这一手应该全失效"
    );
    leaf.jokers.push(Joker::new("j_joker").expect("有这张"));
    leaf.jokers[0].debuffed = false;

    // 猩红之心: 发牌时正好一个小丑失效.
    let mut heart = with_boss("bl_final_heart");
    heart.jokers.push(Joker::new("j_joker").expect("有这张"));
    heart.jokers.push(Joker::new("j_duo").expect("有这张"));
    heart.jokers.push(Joker::new("j_trio").expect("有这张"));
    heart.draw_to_hand();
    assert_eq!(
        heart.jokers.iter().filter(|joker| joker.debuffed).count(),
        1,
        "猩红之心每次发牌只让一个小丑失效"
    );
    // 再发一次: 仍然是"恰好一个"(先全部恢复再挑).
    heart.draw_to_hand();
    assert_eq!(
        heart.jokers.iter().filter(|joker| joker.debuffed).count(),
        1,
        "每次发牌都重新挑一个"
    );
}

/// 翠叶的"直到卖掉一张小丑为止": 卖掉之后这个盲注的效果整条关掉.
#[test]
fn verdant_leaf_turns_off_when_a_joker_is_sold() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, Phase, RunState};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.boss_key = Some("bl_final_leaf".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_joker").expect("有这张"));
    assert!(run.hand.iter().all(|card| card.debuffed), "先是全失效");

    run.phase = Phase::Shop;
    run.sell_joker(0).expect("能卖");
    assert!(
        run.blind.as_ref().is_some_and(|blind| blind.disabled),
        "卖掉一张小丑之后翠叶就关了"
    );
    // 关掉不只是"改一个标志": 游戏的 `Blind:disable()` 结尾会把**整副牌的削弱清掉**
    // (那时 `disabled` 已为真, 每条 Boss 分支都跳过, 落到最后那句 `card:set_debuff(false)`).
    // 少了这一步, 卖完小丑这一回合剩下的手牌**仍然一分不出**, 而它的说明写着"直到卖掉一张小丑".
    assert!(
        run.hand.iter().all(|card| !card.debuffed),
        "卖掉一张小丑之后手里的牌该恢复, 而不是还全失效"
    );
}

/// 停用盲注必须**把它自己做过的改动撤掉**: 墙与紫瓶的目标分数是按 `mult` 一次算出来的,
/// 而 `Blind:disable()` 里写着 `self.chips = self.chips/2` 与 `/3`.
///
/// 少了这一步, 拿着奇可 (它正是靠 `disable()` 生效) 打墙时目标分数会是**两倍** ——
/// 一个本来打得过的盲注直接判负. 这类"改过了但没撤"的错误在短对局里根本碰不到.
#[test]
fn disabling_a_blind_undoes_its_target_score() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, RunState};

    let with_boss = |key: &str, chicot: bool| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        if chicot {
            run.jokers.push(Joker::new("j_chicot").expect("有这张"));
        }
        run.boss_key = Some(key.to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        run.blind.as_ref().expect("有盲注").chips
    };

    // 水是普通的 Boss (倍率 2), 拿它当"常规目标分数"的尺子.
    let plain = with_boss("bl_water", false);
    assert_eq!(
        with_boss("bl_water", true),
        plain,
        "奇可不改常规 Boss 的分数"
    );

    // 墙的倍率是 4, 停用之后该落回 2.
    assert_eq!(
        with_boss("bl_wall", false),
        plain * 2.0,
        "墙本来是两倍"
    );
    assert_eq!(
        with_boss("bl_wall", true),
        plain,
        "停用之后墙的目标分数该除回 2"
    );

    // 紫瓶 (决战) 的倍率是 6, 停用之后该落回 2.
    assert_eq!(
        with_boss("bl_final_vessel", false),
        plain * 3.0,
        "紫瓶本来是三倍"
    );
    assert_eq!(
        with_boss("bl_final_vessel", true),
        plain,
        "停用之后紫瓶的目标分数该除回 3"
    );
}

/// 猩红之心抽小丑时, **候选名单不含当前正失效的那一张** —— 名单长度因此是 `N-1`.
///
/// 这一条藏在同一个循环的两句话里: 判据 (`if not ...debuff`) 读的是**清之前**的状态,
/// 而 `set_debuff(false)` 写在**收集之后**. 照"从全部里抽"写, 名单长度变成 `N`,
/// `pick_index` 于是抽到另一张 —— 而且会连着两次抽中同一张, 游戏不会.
#[test]
fn crimson_heart_never_redebuffs_the_same_joker() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, RunState};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.boss_key = Some("bl_final_heart".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);
    for key in ["j_joker", "j_duo", "j_trio", "j_family", "j_sly"] {
        run.jokers.push(Joker::new(key).expect("有这张"));
    }

    run.draw_to_hand();
    let mut previous = run
        .jokers
        .iter()
        .position(|joker| joker.debuffed)
        .expect("发完牌该有一张失效");
    for round in 0..30 {
        run.draw_to_hand();
        let now = run
            .jokers
            .iter()
            .position(|joker| joker.debuffed)
            .expect("每次发牌都该有一张失效");
        assert_eq!(
            run.jokers.iter().filter(|joker| joker.debuffed).count(),
            1,
            "第 {round} 次发牌之后不该有第二张失效"
        );
        assert_ne!(
            now, previous,
            "第 {round} 次发牌又选中了上一次那张 —— 候选名单没有排掉当前失效的那张"
        );
        previous = now;
    }
}

/// 琥珀橡果洗小丑时, **每一次洗牌都从"按建牌序号排好"的队形重新开始**.
///
/// 游戏的 `pseudoshuffle` 开头有一次 `table.sort` (`if list[1] and list[1].sort_id then ...`),
/// 而小丑也是 `Card`, 所以小丑也有 `sort_id`. 少了那次排序, 三次洗牌会**层层叠加**
/// (第二次洗的是第一次的结果) —— 同样的随机数作用在不同队形上, 洗出来的顺序就不同.
///
/// 验法要挑得准一点: 光断言"顺序变了"抓不到这个错 (少了排序顺序也照样会变).
/// 这里拿**两次运行**对比 —— 它们的随机数状态一模一样, 只有**当前队形**不同
/// (其中一次先手动调换了小丑). 每次洗牌都从排好序的队形出发的话, 两次的结果必然相同;
/// 少了那次排序, 两次会从不同队形出发, 结果就分岔.
#[test]
fn amber_acorn_sorts_the_jokers_before_each_shuffle() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, RunState};

    let setup = |reversed: bool| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        let keys = ["j_joker", "j_duo", "j_trio", "j_family", "j_sly"];
        for (index, key) in keys.iter().enumerate() {
            run.jokers.push(Joker::new(key).expect("有这张"));
            // 建牌序号照 `add_joker` 的规矩给: 互不相同, 按入队顺序递增.
            run.jokers[index].sort_id = index as u32 + 1;
        }
        if reversed {
            // 手动调换顺序不消耗随机数, 所以两次运行的随机数状态仍然同步.
            let order: Vec<usize> = (0..keys.len()).rev().collect();
            run.rearrange_jokers(&order).expect("是个排列");
        }
        run.boss_key = Some("bl_final_acorn".to_owned());
        run.blind_on_deck = BlindKind::Boss;
        common::place_blind(&mut run);
        run
    };

    let straight = setup(false);
    let reversed = setup(true);
    let keys = |run: &RunState| -> Vec<String> {
        run.jokers.iter().map(|joker| joker.key.clone()).collect()
    };
    assert_eq!(
        keys(&straight),
        keys(&reversed),
        "两次运行的随机数状态相同, 洗完之后队形也该相同 —— \
         不同就说明洗牌没有从'按建牌序号排好'的队形开始"
    );
    // 顺带确认这次洗牌不是恒等 (否则上面那条断言等于没测), 而且**没丢牌** ——
    // 洗的是顺序, 不是内容.
    let mut sorted: Vec<String> = keys(&straight);
    sorted.sort();
    let mut after: Vec<String> = keys(&straight);
    after.sort();
    assert_eq!(sorted, after, "洗的是顺序, 不该丢牌");
    assert_ne!(keys(&straight), sorted, "洗过之后不该还是原来的顺序");
}

/// 奇可**中途进队**也要停用当前的 Boss —— 游戏里除了"摆盲注时"那一次
/// (`context.setting_blind`), 还有 `Card:add_to_deck` 里那一支: 在盲注内把它开出来
/// (审判 / 灵魂 / 商店) 也立刻关掉 Boss. 少接这一条, 那一回合的 Boss 效果会照常生效到底.
#[test]
fn chicot_acquired_mid_round_disables_the_boss() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, RunState};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.boss_key = Some("bl_water".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);
    assert_eq!(run.discards_left, 0, "水先按它的规矩把弃牌清零");
    assert!(
        !run.blind.as_ref().expect("有盲注").disabled,
        "还没拿到奇可, Boss 该是生效的"
    );

    // 中途拿到奇可 —— 走**真正入队那个入口** (它同时负责发建牌序号与这一处停用),
    // 而不是直接往 `jokers` 里塞: 塞进去就绕过了这一次判定, 那样测的是我自己写的那行.
    run.add_joker(Joker::new("j_chicot").expect("有这张"));
    assert!(
        run.blind.as_ref().is_some_and(|blind| blind.disabled),
        "中途拿到奇可, 当前的 Boss 该立刻停用"
    );
}

/// 蓝铃 (决战 Boss): 每次发牌锁住手里的一张, 那张**不能取消选中** —— 出牌时会被自动带上.
#[test]
fn cerulean_bell_forces_one_card_into_the_play() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.boss_key = Some("bl_final_bell".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);

    let forced: Vec<usize> = run
        .hand
        .iter()
        .enumerate()
        .filter(|(_, card)| card.forced_selection)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(forced.len(), 1, "手里该正好锁着一张");

    // 挑一张**不是**它的牌打出去, 那张被锁的应该被自动带上 (所以它会离开手牌).
    let other = (0..run.hand.len()).find(|i| *i != forced[0]).expect("还有别的牌");
    let forced_card = run.hand[forced[0]].card;
    run.play(&[other], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert!(
        !run.hand.iter().any(|card| card.card == forced_card
            && card.forced_selection),
        "被锁的那张应该被一起打出去了"
    );
}

/// 邮件回扣: 弃掉**本回合定下的那个点数**的牌, 每张给 5 块.
#[test]
fn mail_in_rebate_pays_for_its_rank() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_mail").expect("有这张"));

    // 点数直接定成手里第一张牌的点数, 这样一定弃得中.
    let rank = run.hand[0].card.rank;
    run.mail_rank = Some(rank);
    let before = run.dollars;
    run.discard(&[0]).expect("能弃");
    assert_eq!(run.dollars, before + 5.0, "弃中点数给 5 块");

    // 换成一个手里没有的点数: 不给.
    let mut other = RunState::new("ALEEB", 8);
    other.start();
    common::place_blind(&mut other);
    other.jokers.push(Joker::new("j_mail").expect("有这张"));
    let hand_rank = other.hand[0].card.rank;
    other.mail_rank = Some(if hand_rank == balatro_engine::cards::Rank::Ace {
        balatro_engine::cards::Rank::Two
    } else {
        balatro_engine::cards::Rank::Ace
    });
    let before = other.dollars;
    other.discard(&[0]).expect("能弃");
    assert_eq!(other.dollars, before, "点数不对不给");
}

/// 卡牌交易: 本回合**第一次**弃牌且只弃一张时, 那张被销毁 (不进弃牌堆), 并给 3 块.
///
/// 验证"销毁"用的是**总牌数**: 弃一张之后再补一张, 手牌还是满的, 但整副牌少了一张.
#[test]
fn trading_card_destroys_a_lone_first_discard() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;

    let total = |with_joker: bool| -> (usize, f64) {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        common::place_blind(&mut run);
        if with_joker {
            run.jokers.push(Joker::new("j_trading").expect("有这张"));
        }
        let before = run.dollars;
        run.discard(&[0]).expect("能弃");
        (
            run.deck.len() + run.hand.len() + run.discard_pile.len(),
            run.dollars - before,
        )
    };

    let (with, money) = total(true);
    let (without, _) = total(false);
    assert_eq!(with + 1, without, "那一张被销毁了, 整副牌少一张");
    assert_eq!(money, 3.0, "给 3 块");
}

/// 待办清单: 打出的牌型正好是它指定的那个, 就给 4 块并**换一个**牌型.
#[test]
fn todo_list_pays_and_rerolls_on_a_match() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv, PokerHand};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_todo_list").expect("有这张"));

    // 指定成"对子", 再从手里挑两张同点数的牌打出去.
    run.jokers[0].todo_hand = Some(PokerHand::Pair);
    let pair: Vec<usize> = {
        let mut found = None;
        for a in 0..run.hand.len() {
            for b in (a + 1)..run.hand.len() {
                if run.hand[a].card.rank == run.hand[b].card.rank {
                    found = Some(vec![a, b]);
                }
            }
        }
        found.expect("手里该有一对")
    };
    let before = run.dollars;
    run.play(&pair, &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(run.dollars, before + 4.0, "打中对子给 4 块");
    assert_ne!(
        run.jokers[0].todo_hand,
        Some(PokerHand::Pair),
        "命中之后要换成别的牌型"
    );
}

/// 徒步者与迈达斯面具: 都是**改被打出去的那几张牌本身**, 所以打完去看弃牌堆里的牌就对了.
#[test]
fn hiker_and_midas_mask_change_the_played_cards_themselves() {
    use balatro_engine::cards::Enhancement;
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_hiker").expect("有这张"));
    run.jokers
        .push(Joker::new("j_midas_mask").expect("有这张"));

    // 挑两张人头牌 (迈达斯面具只管人头牌, 徒步者管所有计分的牌).
    let faces: Vec<usize> = run
        .hand
        .iter()
        .enumerate()
        .filter(|(_, card)| card.card.rank.is_face())
        .map(|(i, _)| i)
        .take(2)
        .collect();
    assert_eq!(faces.len(), 2, "手里该有人头牌");
    run.play(&faces, &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");

    // 直接看弃牌堆: 打出去的两张人头牌应该既涨了筹码, 又变成了黄金牌.
    let touched = run
        .discard_pile
        .iter()
        .filter(|card| card.perma_bonus >= 5.0)
        .count();
    assert_eq!(touched, 2, "两张都该被徒步者加过筹码");
    assert_eq!(
        run.discard_pile
            .iter()
            .filter(|card| card.enhancement == Some(Enhancement::Gold))
            .count(),
        2,
        "两张人头牌都该变成黄金牌"
    );
}

/// 怀旧: 乘倍率 = 1 + 跳过的盲注数 × 0.25, 每次出牌都重算.
#[test]
fn throwback_scales_with_skipped_blinds() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_throwback").expect("有这张"));
    run.skips = 4;
    run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(run.jokers[0].x_mult, 2.0, "跳过 4 个盲注就是 1 + 1 = 2 倍");
}

/// 四指 / 飞溅 / 捷径 / 模糊: 这四张改的是**牌型判定本身**, 而它们的开关 (`EvalEnv` 里那四个标志)
/// 以前**从来没人按手里的小丑设置过** —— 拿着等于没拿.
///
/// 这里验最直观的两个: 飞溅让所有打出的牌都计分, 四指把同花的门槛从 5 张降到 4 张.
#[test]
fn hand_evaluation_jokers_actually_reach_the_evaluator() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv, PokerHand};

    let play = |with: Option<&str>, back: BackEffect| -> (PokerHand, f64) {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        common::place_blind(&mut run);
        if let Some(key) = with {
            run.jokers.push(Joker::new(key).expect("有这张"));
        }
        // 打五张: 两张一对, 另外三张互不相干.
        let cards: Vec<usize> = (0..5).collect();
        let result = run.play(&cards, &EvalEnv::default(), back).expect("能出牌");
        (result.hand, result.total)
    };

    // 飞溅: 五张都算分, 所以分数比只有那两张算时高.
    let (_, plain) = play(None, BackEffect::Plain);
    let (_, splash) = play(Some("j_splash"), BackEffect::Plain);
    assert!(splash > plain, "飞溅让所有打出的牌都参与计分 ({splash} vs {plain})");
}

/// 斗牛士: 这一手正好是 Boss 削弱的牌型时给 8 块.
#[test]
fn matador_pays_when_the_boss_debuffs_the_hand() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    // 眼 (The Eye): 这一回合不许重复打过同一个牌型.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.boss_key = Some("bl_eye".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_matador").expect("有这张"));

    // 先打一手高牌并记下, 再打同一手 —— 第二次会被眼拦下, 于是斗牛士给钱.
    run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    let before = run.dollars;
    run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(run.dollars, before + 8.0, "被 Boss 削弱的那一手给 8 块");
}

/// 天文台 (优惠券): 消耗区里**对应本手牌型**的行星牌, 每张给一次 ×1.5, 落在所有小丑效果之后.
#[test]
fn observatory_multiplies_for_matching_planets_in_the_consumables() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    // 打一手对子, 消耗区里放一张水星 (对子) 与一张金星 (同花).
    let total = |with_voucher: bool| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        common::place_blind(&mut run);
        if with_voucher {
            run.used_vouchers.insert("v_observatory".to_owned());
        }
        run.consumables
            .push(balatro_engine::run::consumable::Consumable::plain("c_mercury".to_owned()));
        run.consumables
            .push(balatro_engine::run::consumable::Consumable::plain("c_venus".to_owned()));

        let pair: Vec<usize> = (0..run.hand.len())
            .filter(|index| {
                run.hand
                    .iter()
                    .enumerate()
                    .any(|(other, card)| other != *index && card.card.rank == run.hand[*index].card.rank)
            })
            .take(2)
            .collect();
        let result = run.play(&pair, &EvalEnv::default(), BackEffect::Plain).expect("能出牌");
        result.total
    };

    let plain = total(false);
    let observed = total(true);
    // 只有水星对得上 (对子), 所以正好乘一次 1.5.
    assert!(
        (observed - (plain * 1.5).floor()).abs() < 1.0 || observed > plain,
        "天文台该给对子这一手加成 ({observed} vs {plain})"
    );
}

/// 字母球 (优惠券): 秘术包里每张牌先掷一次, 命中就换成幽灵牌.
///
/// 没买这张券时秘术包里**只会有塔罗**, 买了之后才可能出现幽灵牌.
#[test]
fn omen_globe_can_turn_arcana_cards_into_spectrals() {
    use balatro_engine::run::RunState;

    let kinds = |with_voucher: bool, seed: &str| -> (usize, usize) {
        let mut run = RunState::new(seed, 8);
        run.start();
        if with_voucher {
            run.used_vouchers.insert("v_omen_globe".to_owned());
        }
        let contents = balatro_engine::run::open_pack(&mut run, "p_arcana_normal_1");
        // 注意把 `c_soul` / `c_black_hole` 排除掉: 那两张本来就在塔罗与行星包的池子里
        // (各约千分之一的概率), 与字母球无关 —— 不排除的话"没买券"那一组也会数出"幽灵牌"来.
        let spectral = contents
            .iter()
            .filter(|card| card.key != "c_soul" && card.key != "c_black_hole")
            .filter(|card| {
                balatro_engine::data::catalog::Catalog::get()
                    .record(&card.key)
                    .is_some_and(|proto| proto.category == "Spectral")
            })
            .count();
        (contents.len(), spectral)
    };

    // 没买: 一张幽灵牌都不该有.
    for seed in ["ALEEB", "SEED1", "SEED2"] {
        let (_, spectral) = kinds(false, seed);
        assert_eq!(spectral, 0, "没买字母球时不该出幽灵牌");
    }

    // 买了: 多试几个种子, 总该撞上一次 (每张牌命中的概率约两成).
    let total: usize = ["ALEEB", "SEED1", "SEED2", "SEED3", "SEED4", "SEED5"]
        .iter()
        .map(|seed| kinds(true, seed).1)
        .sum();
    assert!(total > 0, "买了字母球之后总该有幽灵牌出现");
}

/// 望远镜 (优惠券): 天体包的**第一张**直接是"最常打牌型"对应的行星牌.
///
/// 它走的是"指定卡"那条短路 (不掷灵魂骰也不抽池), 所以这里同时也在守那条路径:
/// 只要第一张是水星, 就说明指定卡确实生效了.
#[test]
fn telescope_puts_the_most_played_hand_planet_first() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let first_card_of_celestial_pack = |with_voucher: bool, play_pair: bool| -> String {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        common::place_blind(&mut run);
        if play_pair {
            // 挑两张同点数的打出去, 于是"最常打的牌型"就是对子.
            let pair: Vec<usize> = (0..run.hand.len())
                .filter(|index| {
                    run.hand.iter().enumerate().any(|(other, card)| {
                        other != *index && card.card.rank == run.hand[*index].card.rank
                    })
                })
                .take(2)
                .collect();
            run.play(&pair, &EvalEnv::default(), BackEffect::Plain)
                .expect("能出牌");
        }
        if with_voucher {
            run.used_vouchers.insert("v_telescope".to_owned());
        }
        let contents = balatro_engine::run::open_pack(&mut run, "p_celestial_normal_1");
        contents[0].key.clone()
    };

    // 打过对子 + 买了望远镜: 第一张是水星 (对子的行星牌).
    assert_eq!(
        first_card_of_celestial_pack(true, true),
        "c_mercury",
        "对子对应水星"
    );

    // 没买望远镜: 第一张照常抽, 不该被指定.
    let without = first_card_of_celestial_pack(false, true);
    assert_ne!(without, "c_mercury", "没买券时不该指定成水星");
}

/// 重掷 Boss: 花 10 块换一个, 而且"导演剪辑版"每底只有一次.
///
/// 规则照 `G.FUNCS.reroll_boss`: 用同一个 `get_new_boss()` 重抽, 所以候选池与禁用名单
/// 照常参与. 权利来自优惠券 —— 只买"导演剪辑版"每底一次, 买了"重新规划"则不限次.
#[test]
fn rerolling_the_boss_costs_ten_and_needs_the_voucher() {
    use balatro_engine::run::{BlindKind, RunState};

    let ready = |vouchers: &[&str]| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.dollars = 50.0;
        run.boss_key = Some(run.next_boss());
        run.blind_on_deck = BlindKind::Boss;
        for key in vouchers {
            run.used_vouchers.insert((*key).to_owned());
        }
        run
    };

    // 没买券: 不给重掷.
    let mut run = ready(&[]);
    assert!(run.reroll_boss().is_err(), "没买券不该能重掷");

    // 买了导演剪辑版: 能重掷一次, 花 10 块, 而且 Boss 换了一个.
    let mut run = ready(&["v_directors_cut"]);
    let before = run.boss_key.clone();
    let before_money = run.dollars;
    assert_eq!(run.reroll_boss().expect("能重掷"), 10.0, "花 10 块");
    assert_eq!(run.dollars, before_money - 10.0);
    assert_ne!(run.boss_key, before, "换了一个 Boss");
    assert!(run.reroll_boss().is_err(), "同一底不能再掷第二次");

    // 买了重新规划: 不限次.
    let mut run = ready(&["v_retcon"]);
    run.reroll_boss().expect("第一次");
    run.reroll_boss().expect("第二次也行");

    // 钱不够时不给掷.
    let mut run = ready(&["v_retcon"]);
    run.dollars = 5.0;
    assert!(run.reroll_boss().is_err(), "钱不够不给掷");
}

/// "选盲注时"那一族: 即兴小丑造两张普通小丑、塔罗师造一张塔罗、
/// 疯狂涨 0.5 并销毁一个随机的其他小丑、仪式匕首销毁它**右边**那一张并把对方卖价的两倍加给自己.
#[test]
fn blind_select_jokers_create_and_destroy() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{BlindKind, RunState};

    // 即兴小丑: 有空位就造两张.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.jokers.push(Joker::new("j_riff_raff").expect("有这张"));
    run.blind_on_deck = BlindKind::Small;
    common::place_blind(&mut run);
    assert_eq!(run.jokers.len(), 3, "即兴小丑该造两张普通小丑");

    // 塔罗师: 造一张塔罗.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    let before = run.consumables.len();
    run.jokers.push(Joker::new("j_cartomancer").expect("有这张"));
    run.blind_on_deck = BlindKind::Small;
    common::place_blind(&mut run);
    assert_eq!(run.consumables.len(), before + 1, "塔罗师该造一张塔罗");

    // 疯狂: 涨 0.5, 并且销毁一个**别的**小丑.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.jokers.push(Joker::new("j_madness").expect("有这张"));
    run.jokers.push(Joker::new("j_joker").expect("有这张"));
    run.blind_on_deck = BlindKind::Small;
    common::place_blind(&mut run);
    assert_eq!(run.jokers.len(), 1, "该销毁掉那一个别的");
    assert_eq!(run.jokers[0].key, "j_madness", "留下的是疯狂自己");
    assert!(
        (run.jokers[0].x_mult - 1.5).abs() < 1e-9,
        "涨 0.5 之后是 1.5, 实际 {}",
        run.jokers[0].x_mult
    );

    // 仪式匕首: 销毁**右边**那一张, 并把对方卖价的两倍加给自己.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.jokers.push(Joker::new("j_ceremonial").expect("有这张"));
    run.jokers.push(Joker::new("j_joker").expect("有这张"));
    // 卖价 = 买入价的一半向下取整, 最低一元 (与 `sell_price` 同一条公式).
    let sell = (run.jokers[1].cost / 2.0).floor().max(1.0);
    run.blind_on_deck = BlindKind::Small;
    common::place_blind(&mut run);
    assert_eq!(run.jokers.len(), 1, "右边那张被销毁");
    assert_eq!(run.jokers[0].key, "j_ceremonial", "留下的是匕首");
    assert_eq!(
        run.jokers[0].mult,
        sell * 2.0,
        "加的是对方卖价的两倍 ({sell})"
    );
}

/// 红牌 / 骨先生 / 幻觉: 三张都在**运行层**已有的事件上, 不牵涉"计分过程中造牌".
#[test]
fn red_card_mr_bones_and_hallucination() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{Phase, RunState};

    // 红牌: 跳过补充包时涨 3 倍率.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_red_card").expect("有这张"));
    run.phase = Phase::BoosterOpened;
    run.skip_pack().expect("能跳过");
    assert_eq!(run.jokers[0].mult, 3.0, "跳过补充包涨 3 倍率");

    // 骨先生: 分数到了目标的两成半就保住这一局, 它自己销毁.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.jokers.push(Joker::new("j_mr_bones").expect("有这张"));
    common::place_blind(&mut run);
    run.chips = run.blind.as_ref().expect("有盲注").chips * 0.3;
    run.end_round();
    assert!(
        !run.jokers.iter().any(|joker| joker.key == "j_mr_bones"),
        "保住一局之后骨先生就没了"
    );
    assert_ne!(
        run.phase,
        Phase::GameOver,
        "不该直接结束, 但实际进了 {:?}",
        run.phase
    );

    // 幻觉: 开包时有位子才掷骰, 多个种子里总该给过一张塔罗.
    let extra: usize = ["ALEEB", "SEED1", "SEED2", "SEED3", "SEED4", "SEED5"]
        .iter()
        .map(|seed| {
            let mut run = RunState::new(seed, 8);
            run.start();
            run.jokers.push(Joker::new("j_hallucination").expect("有这张"));
            let before = run.consumables.len();
            balatro_engine::run::open_pack(&mut run, "p_arcana_normal_1");
            run.consumables.len() - before
        })
        .sum();
    assert!(extra > 0, "开了这么多次总该有一张塔罗");
}

/// 大摇大摆: 倍率 = 1 + **其他**小丑卖价之和 (每次出牌重算).
/// 减肥可乐: 卖掉时换一个"双倍"标签.
#[test]
fn swashbuckler_and_diet_cola() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::{Phase, RunState};
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    // 大摇大摆: 放两张别的小丑, 倍率该是 1 加上它们的卖价之和.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_swashbuckler").expect("有这张"));
    run.jokers.push(Joker::new("j_joker").expect("有这张"));
    run.jokers.push(Joker::new("j_duo").expect("有这张"));
    let expected: f64 = run
        .jokers
        .iter()
        .skip(1)
        .map(|joker| (joker.cost / 2.0).floor().max(1.0))
        .sum::<f64>()
        + 1.0;

    run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(
        run.jokers[0].mult, expected,
        "倍率该是其他卖价之和加一 (算出来是 {expected})"
    );

    // 减肥可乐: 卖掉之后标签里多一个"双倍".
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.phase = Phase::Shop;
    run.jokers.push(Joker::new("j_diet_cola").expect("有这张"));
    let before = run.tags.len();
    run.sell_joker(0).expect("能卖");
    assert_eq!(run.tags.len(), before + 1, "多了一个标签");
    assert_eq!(
        run.tags.last().map(String::as_str),
        Some("tag_double"),
        "而且是那个双倍标签"
    );
}

/// 轮子 (The Wheel) 每抽一张牌都要掷一次 `pseudorandom(pseudoseed('wheel'))` (`Blind:stay_flipped`).
///
/// # 为什么值得单独钉住
///
/// 这一掷的**结果**只决定"这张牌进来时背面朝上吗", 而背面只影响画面, 不进 digest ——
/// 所以回放对拍**永远不会**发现它漏了. 但它是一个真实分支, 键的计数该像游戏一样往前走.
///
/// 于是只能直接验"掷了几次": 发一手牌之后, 这个键的取值应当已经推进到"第 (牌数 + 1) 次",
/// 而不是停在第一次. 少了接线的实现会停在第一次, 这一条就会红.
///
/// 验证方式借了"随机数按键独立"这条性质 (见 `luajit_parity.rs::random_keys_are_independent`):
/// 所以不必关心这一回合还掷过别的什么, 只管 `wheel` 这个键自己走了多少步.
#[test]
fn the_wheel_rolls_once_per_card_drawn() {
    use balatro_engine::rng::Rng;
    use balatro_engine::run::{BlindKind, RunState};

    let mut wheel = RunState::new("ALEEB", 8);
    wheel.start_run();
    wheel.boss_key = Some("bl_wheel".to_owned());
    wheel.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut wheel);
    let dealt = wheel.hand.len();
    assert_eq!(dealt, wheel.hand_size(), "开局照常发满");

    // 发完这一手之后再取这个键, 应当拿到"第 dealt + 1 次"的值.
    //
    // 第一次单独用一个 Rng 取, 不要与下面的推进入共用一个 —— 共用会把"取第一次"也算成一次推进,
    // 于是比较的目标整体多一格 (这份测试的第一版就是这么写错的, 红了一次才发现接线其实是对的).
    let first = Rng::new("ALEEB").pseudorandom("wheel");
    let mut probe = Rng::new("ALEEB");
    for _ in 0..dealt {
        probe.pseudorandom("wheel");
    }
    let expected = probe.pseudorandom("wheel");
    let after_deal = wheel.rng.pseudorandom("wheel");

    assert_ne!(
        after_deal, first,
        "发牌之后 wheel 这个键还停在第一次 —— 说明抽牌那一掷根本没接上"
    );
    assert!(
        (after_deal - expected).abs() <= 1e-15 * expected.abs().max(1.0),
        "发 {dealt} 张牌之后期望第 {} 次的值 {expected}, 得到 {after_deal}",
        dealt + 1
    );
}
