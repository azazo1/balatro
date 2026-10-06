//! 出牌的分项明细: 每一步"谁改了多少".
//!
//! 这份记录的价值在于**解释**一个总分, 所以它失效的方式很特别: 记录与计算分开写时, 数字不会报错,
//! 只是"报出来的"和"算出来的"悄悄分叉 —— agent 于是拿着错的解释去学, 下一手还是会按同样的错法估.
//! 所以这里的断言盯的是两者的**一致性**, 而不是把某张小丑的加成数抄一遍.

mod common;

use balatro_engine::agent::summary;
use balatro_engine::cards::CardInstance;
use balatro_engine::jokers::Joker;
use balatro_engine::scoring::{BackEffect, EvalEnv, HandTable, PokerHand, score_play};

/// 一套"手里这几张牌 + 这几张小丑"的计分.
fn score(codes: &[&str], jokers: &mut [Joker]) -> balatro_engine::scoring::ScoreResult {
    let cards: Vec<_> = codes.iter().map(|code| common::card(code)).collect();
    let env = EvalEnv::default();
    score_play(&cards, &HandTable::new(), &env, BackEffect::Plain, jokers).expect("这一手能识别")
}

/// 记录里最后一步之后的筹码与倍率, 必须与结果给的总数一致.
///
/// 这一条是整份记录的地基: 改动的传入路径与记录的传出路径必须是同一条, 否则报出来的明细解释不了
/// 结果. 拿几张牌与几张有加成的小丑一起算, 任何一处"改了但没记"或"记了但没改"都会露出来.
#[test]
fn steps_end_where_the_result_ends() {
    let mut jokers = vec![
        Joker::new("j_jolly").expect("有这张"),      // 含对子时 +8 倍率
        Joker::new("j_odd_todd").expect("有这张"),   // 奇数牌各 +31 筹码
        Joker::new("j_stencil").expect("有这张"),    // 按空位给乘倍率
    ];
    let result = score(&["C_5", "D_5", "S_9", "H_3", "S_3"], &mut jokers);
    let last = result.steps.last().expect("至少记了一步");
    assert_eq!(last.chips, result.chips, "记录结尾的筹码与结果不符");
    assert_eq!(last.mult, result.mult, "记录结尾的倍率与结果不符");
}

/// 小丑那一步要报出**是哪张小丑**, 且加成数与它对得上.
#[test]
fn a_joker_step_names_the_joker_and_its_amount() {
    let mut jokers = vec![Joker::new("j_jolly").expect("有这张")];
    let result = score(&["C_5", "D_5"], &mut jokers);

    let step = result
        .steps
        .iter()
        .find(|step| matches!(step.source, balatro_engine::scoring::ScoreSource::Joker { .. }))
        .expect("含对子, 欢快小丑应当记一步");
    match &step.source {
        balatro_engine::scoring::ScoreSource::Joker { key } => assert_eq!(key, "j_jolly"),
        other => panic!("来源应当是那张小丑, 实际 {other:?}"),
    }
    assert_eq!(
        step.kind,
        balatro_engine::scoring::ScoreKind::Mult,
        "欢快小丑给的是倍率"
    );
    assert_eq!(step.amount, 8.0, "欢快小丑给 +8 倍率");

    // 报出来的名字要认得出是哪张牌 —— 中文名, 不是内部键名.
    // 名字从手册取而不是写死: 这里要验的是"取了手册的名字", 而不是"某个译名没变".
    let (name, _) = balatro_engine::data::knowledge::describe("j_jolly").expect("手册里有这张");
    let text = summary::score_report(&result, &[], 0, &Default::default());
    assert!(text.contains(name), "明细里要有中文名 {name}: {text}");
    assert!(!text.contains("j_jolly"), "不该露出内部键名: {text}");
}

/// 逐张计分的牌要各记一步, 来源指到那一张.
#[test]
fn every_scoring_card_gets_its_own_step() {
    let result = score(&["C_5", "D_5", "H_9"], &mut []);
    let card_steps: Vec<&_> = result
        .steps
        .iter()
        .filter(|step| {
            matches!(
                step.source,
                balatro_engine::scoring::ScoreSource::Card { .. }
            )
        })
        .collect();
    assert_eq!(card_steps.len(), 2, "对子的两张各一步: {card_steps:?}");

    // 每一步的来源要指到**它自己**那张, 不能都指第一张.
    let indices: Vec<usize> = card_steps
        .iter()
        .map(|step| match step.source {
            balatro_engine::scoring::ScoreSource::Card { index, .. } => index,
            _ => unreachable!(),
        })
        .collect();
    assert_eq!(indices.len(), 2);
    assert_ne!(indices[0], indices[1], "两步要指向不同的牌: {indices:?}");

    // 每一步都要真的把筹码加上去了: 后一步的筹码不小于前一步.
    for pair in card_steps.windows(2) {
        assert!(
            pair[1].chips >= pair[0].chips,
            "筹码应当单调不减: {:?} -> {:?}",
            pair[0],
            pair[1]
        );
    }
}

/// 没生效的小丑不记步 —— 记了会把明细淹掉, 而 agent 会以为它在起作用.
#[test]
fn a_joker_that_does_nothing_records_nothing() {
    // 欢快小丑要"含对子"才生效, 这里打高牌, 它不该出现.
    let mut jokers = vec![Joker::new("j_jolly").expect("有这张")];
    let result = score(&["C_5", "D_9", "H_K"], &mut jokers);
    assert!(
        !result.steps.iter().any(|step| matches!(
            step.source,
            balatro_engine::scoring::ScoreSource::Joker { .. }
        )),
        "条件没命中的小丑不该记步: {:?}",
        result.steps
    );
}

/// 明细要能解释总分: 报出来的末值等于总分, 且总数那行用的是中文牌型名.
#[test]
fn the_report_explains_the_total() {
    let mut jokers = vec![Joker::new("j_jolly").expect("有这张")];
    let result = score(&["C_5", "D_5"], &mut jokers);
    let played: Vec<CardInstance> = ["C_5", "D_5"]
        .iter()
        .map(|code| CardInstance::from_key(code).expect("能造出牌"))
        .collect();
    let text = summary::score_report(&result, &played, 1, &Default::default());

    assert!(text.starts_with("对子 ="), "首行是牌型与总分: {text}");
    assert!(text.contains(&format!("= {}", result.total)), "要有总数行: {text}");
    assert!(!text.contains("Pair"), "牌型要用中文: {text}");
    // 每一行都是三段式 `来源 | 改了什么 | 筹码x倍率`.
    for line in text.lines().skip(1) {
        if line.starts_with("出牌:") || line.starts_with("基础") || line.starts_with('=') {
            continue;
        }
        assert_eq!(
            line.matches('|').count(),
            2,
            "明细行应当是三段: {line}"
        );
    }
    // 参与计分的牌要标出来, 一眼看得出哪几张算进去了.
    assert!(text.contains('*'), "计分牌要有标记: {text}");
}

/// 标签升级之后等级要报出来 (等级改的是基础值, 不报就看不懂基础那一行为什么是那个数).
#[test]
fn the_report_shows_the_hand_level() {
    let result = score(&["C_5", "D_5"], &mut []);
    let with_level = summary::score_report(&result, &[], 3, &Default::default());
    assert!(with_level.contains("Lv3"), "要报等级: {with_level}");
    // 等级 1 是初始值, 不报出来更干净.
    let plain = summary::score_report(&result, &[], 1, &Default::default());
    assert!(!plain.contains("Lv1"), "等级 1 不必报: {plain}");
    assert_eq!(result.hand, PokerHand::Pair);
}

/// 被封禁的一手要说明"为什么是零", 而不是只报一个 0.
///
/// 只给零会让 agent 以为计分坏了 (或者以为自己算错了), 而实际是它踩了 Boss 的限制.
/// 游戏那边的写法是 `被盲注封禁 | 本手不计分 | 0x0`, 这里对齐它.
#[test]
fn a_blocked_hand_says_why_it_scored_zero() {
    use balatro_engine::run::{BlindKind, RunState};
    use balatro_engine::scoring::BackEffect;

    // 眼 (The Eye): 同一回合里打重复的牌型就整手不计分.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.boss_key = Some("bl_eye".to_owned());
    run.blind_on_deck = BlindKind::Boss;
    common::place_blind(&mut run);
    run.hand = ["C_5", "D_5", "H_9"]
        .iter()
        .enumerate()
        .map(|(index, code)| {
            let mut card = balatro_engine::cards::CardInstance::from_key(code).expect("能造出牌");
            card.card.sort_id = index as u32;
            card
        })
        .collect();

    let env = EvalEnv::default();
    run.play(&[0, 1], &env, BackEffect::Plain).expect("第一手能出");
    // 再打一次对子.
    run.hand = ["C_7", "D_7", "H_9"]
        .iter()
        .enumerate()
        .map(|(index, code)| {
            let mut card = balatro_engine::cards::CardInstance::from_key(code).expect("能造出牌");
            card.card.sort_id = index as u32;
            card
        })
        .collect();
    let blocked = run.play(&[0, 1], &env, BackEffect::Plain).expect("第二手能出");

    let text = summary::score_report(&blocked, &[], 1, &Default::default());
    assert!(blocked.blocked, "这一手应当被标成封禁: {text}");
    assert!(text.contains("封禁"), "明细要说明原因: {text}");
    assert!(text.contains("= 0"), "总分是零: {text}");
}
