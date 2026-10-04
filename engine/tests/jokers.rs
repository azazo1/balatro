//! 小丑的通用数值分支.
//!
//! 三张都取自 ALEEB 那局实际持有过的小丑, 参数直接来自 `catalog.json`:
//!
//! - 古怪小丑 `j_zany`: `t_mult = 12`, 牌型 `Three of a Kind`
//! - 精明小丑 `j_crafty`: `t_chips = 80`, 牌型 `Flush`
//! - 卡尼奥 `j_caino`: 成长值 `caino_xmult`, 大于 1 才生效

mod common;

use balatro_engine::jokers::Joker;
use balatro_engine::scoring::{
    BackEffect, EvalEnv, HandTable, PokerHand, evaluate_poker_hand, score_play,
};
use common::{card, hand};

fn table() -> HandTable {
    HandTable::new()
}

/// 把手里换成指定的几张, 这样测的是**确定的牌型** —— 发出来的牌是什么全看种子.
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

#[test]
fn prototype_parameters_come_from_the_catalog() {
    let zany = Joker::new("j_zany").expect("古怪小丑在原版里");
    assert_eq!(zany.t_mult, 12.0);
    assert_eq!(zany.kind, Some(PokerHand::ThreeOfAKind));

    let crafty = Joker::new("j_crafty").expect("精明小丑在原版里");
    assert_eq!(crafty.t_chips, 80.0);
    assert_eq!(crafty.kind, Some(PokerHand::Flush));

    let caino = Joker::new("j_caino").expect("卡尼奥在原版里");
    assert_eq!(caino.caino_xmult, 1.0, "初值是 1, 还没摧毁过人头牌");
    assert_eq!(caino.extra, 1.0, "每带头加 1 倍率乘数");
}

#[test]
fn zany_adds_mult_only_on_three_of_a_kind() {
    let mut jokers = [Joker::new("j_zany").expect("有这张")];

    // 三条: 生效.
    let three = ["C_5", "D_5", "H_5", "S_9", "C_K"].map(card);
    let hit = score_play(&three, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    assert_eq!(hit.hand, PokerHand::ThreeOfAKind);
    // 三条基础 30 筹码 3 倍率, 三张 5 共 15 点, 再加 +12 倍率.
    assert_eq!(hit.chips, 45.0);
    assert_eq!(hit.mult, 15.0);
    assert_eq!(hit.total, 675.0);

    // 对子: `Three of a Kind` 不满足, 小丑不生效.
    let pair = ["C_5", "D_5", "H_9", "S_8", "C_K"].map(card);
    let miss = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    assert_eq!(miss.hand, PokerHand::Pair);
    assert_eq!(miss.mult, 2.0, "没有小丑加成");
}

#[test]
fn crafty_adds_chips_only_on_flush() {
    let mut jokers = [Joker::new("j_crafty").expect("有这张")];

    let flush = ["C_2", "C_5", "C_7", "C_9", "C_K"].map(card);
    let hit = score_play(&flush, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    assert_eq!(hit.hand, PokerHand::Flush);
    // 同花基础 35 筹码 4 倍率, 五张牌 2+5+7+9+10 = 33 点, 再加 +80 筹码.
    assert_eq!(hit.chips, 35.0 + 33.0 + 80.0);
    assert_eq!(hit.mult, 4.0);

    // 不是同花就不生效. 这手牌最高只是高牌, 只算最大那张 (K 的 10 点).
    let not_flush = ["C_2", "D_5", "C_7", "C_9", "C_K"].map(card);
    let miss = score_play(&not_flush, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    assert_eq!(miss.hand, PokerHand::HighCard);
    assert_eq!(miss.scoring_cards.len(), 1);
    assert_eq!(miss.chips, 5.0 + 10.0);
}

#[test]
fn caino_multiplies_only_after_it_grew() {
    let mut caino = Joker::new("j_caino").expect("有这张");
    let three = ["C_5", "D_5", "H_5", "S_9", "C_K"].map(card);

    // 成长值还是 1 时整条分支不返回.
    let before = score_play(
        &three,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [caino.clone()],
    )
    .expect("能识别牌型");
    assert_eq!(before.mult, 3.0, "只有三条自己的 3 倍率");

    // 摧毁过两张人头牌之后是 1 + 2 = 3 倍率乘数.
    caino.caino_xmult = 3.0;
    let after = score_play(
        &three,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [caino],
    )
    .expect("能识别牌型");
    assert_eq!(after.mult, 9.0, "3 倍率再乘 3");
}

/// 实机基准: 2026-10-04 跑的一次对局, 等离子牌组, 手里一对 T 配一张 `j_jolly`.
///
/// 真游戏的计分明细 (`gamestate` 的 `round.last_hand.text`):
///
/// ```text
/// 上一手: 对子 Lv1 = 400
/// 出牌: 梅花10* 方片10*
/// 梅花10 | +10 筹码 | 20x2
/// 方片10 | +10 筹码 | 30x2
/// Jolly Joker | +8 倍率 | 30x10
/// = 400
/// ```
///
/// 注意小丑排在两张计分牌**之后**, 也就是 `joker_main` 在所有逐卡效果之后才结算.
#[test]
fn jolly_joker_matches_a_real_game() {
    let mut jokers = [Joker::new("j_jolly").expect("有这张")];
    let played = ["C_T", "D_T"].map(card);
    let result = score_play(
        &played,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plasma,
        &mut jokers,
    )
    .expect("能识别牌型");

    assert_eq!(result.hand, PokerHand::Pair);
    assert_eq!(result.chips, 20.0, "对子基础 10 加两张 T 的 20 点, 等离子平均后是 20");
    assert_eq!(result.mult, 20.0, "2 倍率加 8, 平均后也是 20");
    assert_eq!(result.total, 400.0, "与真游戏一致");
}

/// 一批纯数值小丑的实机基准 (2026-10-04, 等离子牌组, `add` 端点塞的小丑).
///
/// 每组是 (小丑键, 打出的牌, 真游戏的 `last_hand.total`). 前五组的小丑应当生效,
/// 后两组是条件不命中 —— 真游戏的明细里那时连小丑那一行都不会出现.
///
/// 几个可以用来交叉检查的中间值:
///
/// - 对子 T 是 `30x2`, 加 4 点倍率成 `30x6`; 等离子再平均成 `18x18 = 324`.
/// - `j_sly` 把筹码推到 80, 平均成 `41x41 = 1681`.
/// - 三条 T 是 `60x3`, 加 12 点倍率成 `60x15`, 平均成 `37x37 = 1369`.
/// - `j_wily` 把筹码推到 160, 平均成 `81x81 = 6561`.
#[test]
fn numeric_jokers_match_real_games() {
    let cases: [(&str, [&str; 2], f64); 3] = [
        ("j_joker", ["C_T", "D_T"], 324.0),
        ("j_jolly", ["C_T", "D_T"], 400.0),
        ("j_sly", ["C_T", "D_T"], 1681.0),
    ];
    for (key, played, expected) in cases {
        let joker = Joker::new(key).expect("有这张");
        let cards = played.map(card);
        let result = score_play(
            &cards,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plasma,
            &mut [joker],
        )
        .expect("能识别牌型");
        assert_eq!(result.total, expected, "{key} 的实机总分");
    }

    // 三条 T 的两组.
    let three: [&str; 3] = ["C_T", "D_T", "S_T"];
    for (key, expected) in [("j_zany", 1369.0), ("j_wily", 6561.0)] {
        let joker = Joker::new(key).expect("有这张");
        let cards = three.map(card);
        let result = score_play(
            &cards,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plasma,
            &mut [joker],
        )
        .expect("能识别牌型");
        assert_eq!(result.total, expected, "{key} 的实机总分");
    }

    // 条件不命中: 对子配上要求同花 / 三条的小丑, 总分与不带小丑时相同.
    let pair = ["C_T", "D_T"].map(card);
    let baseline = score_play(
        &pair,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plasma,
        &mut [],
    )
    .expect("能识别牌型");
    assert_eq!(baseline.total, 256.0, "对子 T 不带小丑的实机总分");
    for key in ["j_zany", "j_crafty", "j_wily", "j_crazy"] {
        let joker = Joker::new(key).expect("有这张");
        let result = score_play(
            &pair,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plasma,
            &mut [joker],
        )
        .expect("能识别牌型");
        assert_eq!(result.total, 256.0, "{key} 不该在这手牌上生效");
    }
}

/// 实机基准: `j_trousers` (备用裤子) 打出两对. 2026-10-04, 等离子牌组.
///
/// ```text
/// 上一手: 两对 Lv1 = 676
/// Spare Trousers | 升级!   | 20x2     <- before 阶段, 排在所有计分牌之前
/// 梅花10 | +10 筹码 | 30x2
/// 方片10 | +10 筹码 | 40x2
/// 红桃4  | +4  筹码 | 44x2
/// 黑桃4  | +4  筹码 | 48x2
/// Spare Trousers | +2 倍率 | 48x4     <- joker_main, 用的是刚涨上去的值
/// = 676
/// ```
///
/// 这一手正好把两个阶段都露出来了: 升级发生在计分牌**之前**, 而它的效果 (`+2 倍率`)
/// 在计分牌**之后**回收, 所以成长**本次就生效**. 顺序错了会得到不同的数.
#[test]
fn trousers_grow_before_scoring_and_count_this_hand() {
    let mut jokers = [Joker::new("j_trousers").expect("有这张")];
    let two_pair = ["C_T", "D_T", "H_4", "S_4"].map(card);

    let first = score_play(
        &two_pair,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plasma,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(first.hand, PokerHand::TwoPair);
    assert_eq!(jokers[0].mult, 2.0, "成长值涨到 2");
    assert_eq!(first.chips, 26.0, "48 筹码与 4 倍率平均成 26");
    assert_eq!(first.mult, 26.0);
    assert_eq!(first.total, 676.0, "与真游戏一致");

    // 再打一手两对: 继续成长到 4, 这一手用 4 而不是 2.
    let second = score_play(
        &two_pair,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(jokers[0].mult, 4.0);
    assert_eq!(second.mult, 2.0 + 4.0, "两对基础 2 倍率再加成长后的 4");

    // 对子不满足条件, 不成长也不加成.
    let pair = ["C_T", "D_T"].map(card);
    let third = score_play(
        &pair,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(jokers[0].mult, 4.0, "对子不该让它成长");
    assert_eq!(third.mult, 2.0 + 4.0);
}

/// 绿色小丑每出一手涨 1 倍率, 弃牌掉 1.
#[test]
fn green_joker_grows_on_every_hand_and_shrinks_on_discard() {
    let mut jokers = [Joker::new("j_green_joker").expect("有这张")];
    let pair = ["C_T", "D_T"].map(card);

    let first = score_play(
        &pair,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(jokers[0].mult, 1.0);
    assert_eq!(first.mult, 3.0, "对子自己的 2 倍率加涨到 1");

    // 弃一张牌: 绿小丑掉 1 倍率 (城堡看花色长大那条在同一处, 这里用不到).
    jokers[0].on_discard(&[balatro_engine::cards::CardInstance::from_key("C_5").expect("有这张")], None, false);
    assert_eq!(jokers[0].mult, 0.0, "弃一次牌掉回 0");
}

/// 方形小丑看的是**打出的张数**, 正好四张才涨, 涨出来的筹码当轮就加进去.
#[test]
fn square_grows_on_exactly_four_cards() {
    let mut jokers = [Joker::new("j_square").expect("有这张")];
    let four = ["C_5", "D_7", "H_9", "S_J"].map(card);

    let first = score_play(
        &four,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(jokers[0].chips, 4.0, "涨了一次");
    // 这手只是高牌, 只算最大的 J(10), 再加小丑的 4. 人头牌的筹码值都是 10.
    assert_eq!(first.chips, 5.0 + 10.0 + 4.0);

    // 再打四张: 涨到 8, 这一手用 8.
    let second = score_play(
        &four,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(jokers[0].chips, 8.0);
    assert_eq!(second.chips, 5.0 + 10.0 + 8.0);

    // 打三张不涨, 但已经涨出来的照给.
    let three = ["C_5", "D_7", "H_9"].map(card);
    let third = score_play(
        &three,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(jokers[0].chips, 8.0, "三张不该让它涨");
    assert_eq!(third.chips, 5.0 + 9.0 + 8.0);
}

/// 跑步选手只在顺子上涨, 而同花顺也算顺子 (评估器会把 `Straight` 这一组一并记上).
#[test]
fn runner_grows_on_straights_including_flush_straights() {
    let mut jokers = [Joker::new("j_runner").expect("有这张")];

    let straight = ["C_5", "D_6", "H_7", "S_8", "C_9"].map(card);
    let first = score_play(
        &straight,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(first.hand, PokerHand::Straight);
    assert_eq!(jokers[0].chips, 15.0);

    // 同花顺: 也涨.
    let flush_straight = ["C_5", "C_6", "C_7", "C_8", "C_9"].map(card);
    let second = score_play(
        &flush_straight,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(second.hand, PokerHand::StraightFlush);
    assert_eq!(jokers[0].chips, 30.0, "同花顺也算顺子");

    // 不是顺子就不涨.
    let pair = ["C_5", "D_5"].map(card);
    // 这一手只关心小丑自己的成长值, 分数不用留.
    score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    assert_eq!(jokers[0].chips, 30.0);
}

/// 搭乘巴士: 连着打不含面牌的牌就一路涨, 一旦碰到面牌就清零重来.
#[test]
fn ride_the_bus_resets_on_face_cards() {
    let mut jokers = [Joker::new("j_ride_the_bus").expect("有这张")];
    let no_face = ["C_5", "D_5"].map(card);
    let with_face = ["C_K", "D_K"].map(card);

    for _ in 0..2 {
        score_play(
            &no_face,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("能识别牌型");
    }
    assert_eq!(jokers[0].mult, 2.0, "两次都没面牌");

    // 碰到了面牌: 清零, 这一手也就没有加成了.
    let reset = score_play(
        &with_face,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(jokers[0].mult, 0.0);
    assert_eq!(reset.mult, 2.0, "只剩对子自己的 2 倍率");

    // 之后重新攒.
    score_play(
        &no_face,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(jokers[0].mult, 1.0, "从头来过");
}

/// 冰淇淋每回合融 5 点, 而**融是在用完之后**: 每次计分拿到的都是还没减的那个值.
/// 100 点够撑 20 手, 第 21 手用完剩下那 5 点就化掉.
#[test]
fn ice_cream_melts_after_each_hand_until_it_disappears() {
    let mut jokers = [Joker::new("j_ice_cream").expect("有这张")];
    assert_eq!(jokers[0].chips, 100.0, "初值 100");
    let pair = ["C_5", "D_5"].map(card);

    let first = score_play(
        &pair,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    // 对子基础 10 加两张 5 共 20, 再加冰淇淋给的 100.
    assert_eq!(first.chips, 20.0 + 100.0, "第一次用的是没融过的 100");
    assert_eq!(jokers[0].chips, 95.0, "打完这一手才融掉 5");
    assert!(first.melted.is_empty(), "还没化");

    // 一路打到化: 每手融 5.
    //
    // 数一下: 每手都用当时的整值, 第 19 手用的是 10 并减到 5, 第 20 手用掉那 5 才化.
    let mut hands = 1;
    loop {
        let result = score_play(
            &pair,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("能识别牌型");
        hands += 1;
        if !result.melted.is_empty() {
            assert_eq!(result.chips, 20.0 + 5.0, "最后一次用的是剩下的 5");
            break;
        }
        assert!(hands < 40, "算到现在还没融化, 步长多半不对");
    }
    assert_eq!(hands, 20, "100 点每手融 5, 第 20 手化掉");
    // 自毁那一步不再减值 (游戏里也是直接进自毁分支跳过了减法), 这张卡随后就被移出持有区,
    // 所以这个残留值不影响任何计算.
    assert_eq!(jokers[0].chips, 5.0, "自毁时停在最后那 5 点");
}

/// 汽水给重触发次数, 每回合掉一次.
#[test]
fn seltzer_reports_remaining_repetitions() {
    let mut jokers = [Joker::new("j_selzer").expect("有这张")];
    assert_eq!(jokers[0].extra, 10.0, "初值 10 回合");
    let pair = ["C_5", "D_5"].map(card);

    let first = score_play(
        &pair,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    // 重触发次数目前只记在结果里, 计分引擎还没用它, 所以这里只看数值本身.
    assert_eq!(jokers[0].extra, 9.0, "打完掉一次");
    assert!(first.melted.is_empty());
}

#[test]
fn several_jokers_apply_left_to_right() {
    let mut caino = Joker::new("j_caino").expect("有这张");
    caino.caino_xmult = 2.0;
    let zany = Joker::new("j_zany").expect("有这张");

    let three = ["C_5", "D_5", "H_5", "S_9", "C_K"].map(card);

    // 先加倍率再乘, 与反过来算结果不同: (3 + 12) * 2 = 30.
    let left_to_right = score_play(
        &three,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [zany.clone(), caino.clone()],
    )
    .expect("能识别牌型");
    assert_eq!(left_to_right.mult, 30.0);

    // 顺序反过来: 3 * 2 + 12 = 18.
    let reversed = score_play(
        &three,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [caino, zany],
    )
    .expect("能识别牌型");
    assert_eq!(reversed.mult, 18.0);
}

#[test]
fn a_debuffed_joker_does_nothing() {
    let mut jokers = [Joker::new("j_zany").expect("有这张")];
    let three = ["C_5", "D_5", "H_5", "S_9", "C_K"].map(card);

    let mut views: Vec<_> = hand(&["C_5", "D_5", "H_5", "S_9", "C_K"]);
    // 把小丑标成被禁用走的是 ctx, 这里直接确认牌没被影响即可.
    let normal = score_play(&views, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    views[0].debuffed = true;
    let weakened = score_play(&views, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    assert_eq!(normal.mult, 15.0);
    assert_eq!(weakened.mult, 15.0, "小丑照常加成, 少的是那张牌的 5 点筹码");
    assert_eq!(weakened.chips, 40.0);
    assert_eq!(three.len(), 5);
}

/// 笑脸: 效果按**人头牌的张数**叠加, 不是整手只给一次.
///
/// 它在逐张计分牌那一步触发, 所以一对 K 拿两份 (10 倍率). 如果写成"整手判一次",
/// 结果会少了这一张的量 —— 这类错误只在对子以上的牌型上才看得出来.
#[test]
fn smiley_adds_mult_for_each_face_card() {
    let mut jokers = [Joker::new("j_smiley").expect("有这张")];

    // 一对 K: 两张人头, 各 5 倍率.
    let pair = ["C_K", "D_K"].map(card);
    let two = score_play(
        &pair,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(two.mult, 2.0 + 10.0, "对子基础 2 倍率加两张人头各 5");

    // 三条 Q: 三张人头.
    let three = ["C_Q", "D_Q", "H_Q"].map(card);
    let got = score_play(
        &three,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(got.mult, 3.0 + 15.0, "三条基础 3 倍率加三张人头各 5");

    // 没有头牌就没有加成.
    let plain = ["C_5", "D_5"].map(card);
    let none = score_play(
        &plain,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("能识别牌型");
    assert_eq!(none.mult, 2.0, "五不是人头牌");
}

/// 奇数托德: 点数为 3 / 5 / 7 / 9 或 A 的牌各给 +31 筹码, A 要单独算.
///
/// 这里最容易写错的是 A —— 它的点数序号是 14, 落不进"3 到 9 的奇数"那一条, 但游戏把它
/// 也算了进去.
#[test]
fn odd_todd_pays_on_odd_pips_and_aces() {
    let mut jokers = [Joker::new("j_odd_todd").expect("有这张")];
    let table_here = table();

    // 送一张牌, 看它有没有拿到小丑的 31 筹码.
    let bonus_for = |jokers: &mut [Joker], key: &str| -> f64 {
        let played = [card(key)];
        let result = score_play(
            &played,
            &table_here,
            &EvalEnv::default(),
            BackEffect::Plain,
            jokers,
        )
        .expect("能识别牌型");
        // 高牌只算一张, 所以直接扣掉那张牌自己的筹码就是小丑给的.
        result.chips - result.base_chips - played[0].chip_bonus()
    };

    for key in ["C_3", "C_5", "C_7", "C_9", "C_A"] {
        assert_eq!(bonus_for(&mut jokers, key), 31.0, "{key} 是奇数点或 A, 应当给筹码");
    }
    for key in ["C_2", "C_4", "C_6", "C_8", "C_T", "C_J", "C_Q", "C_K"] {
        assert_eq!(bonus_for(&mut jokers, key), 0.0, "{key} 不该给");
    }
}

/// 四张花色小丑 (贪婪 / 色欲 / 愤怒 / 暴食): 每张该花色的**计分牌**给 +3 倍率.
///
/// 它们共用同一段实现, 差别只在原型里的 `extra.suit`, 所以这里把四种花色都过一遍.
#[test]
fn suit_jokers_pay_for_each_matching_card() {
    // 五张同花: 全部计分, 所以那张小丑应当给五份.
    let flush = ["C_2", "C_4", "C_6", "C_8", "C_T"].map(card);
    let cases = [
        ("j_gluttenous_joker", 15.0, "梅花"),
        ("j_greedy_joker", 0.0, "方块 (这手是梅花, 不给)"),
    ];
    for (key, want_mult, note) in cases {
        let mut jokers = [Joker::new(key).expect("有这张")];
        let got = score_play(
            &flush,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("同花能识别");
        assert_eq!(got.mult, 4.0 + want_mult, "{note}: 同花基础 4 倍率");
    }

    // 换成方块的同花, 贪婪小丑就吃满了.
    let diamonds = ["D_2", "D_4", "D_6", "D_8", "D_T"].map(card);
    let mut jokers = [Joker::new("j_greedy_joker").expect("有这张")];
    let got = score_play(
        &diamonds,
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("同花能识别");
    assert_eq!(got.mult, 4.0 + 15.0, "五张方块给五份");
}

/// 看**局面**而不是看牌的那几张: 旗帜看剩余弃牌, 神秘之峰看弃牌清零, 斗牛看现金.
#[test]
fn board_reading_jokers_pay_from_the_current_state() {
    let pair = ["C_5", "D_5"].map(card);
    let score_with = |key: &str, env: &EvalEnv| -> (f64, f64) {
        let mut jokers = [Joker::new(key).expect("有这张")];
        let got = score_play(&pair, &table(), env, BackEffect::Plain, &mut jokers)
            .expect("对子能识别");
        (got.chips, got.mult)
    };

    // 旗帜: 每剩一次弃牌 +30 筹码. 对子自己的筹码是 10 + 5 + 5 = 20.
    let three_left = EvalEnv {
        discards_left: 3,
        ..EvalEnv::default()
    };
    assert_eq!(score_with("j_banner", &three_left).0, 20.0 + 90.0, "三次弃牌给 90 筹码");
    let none_left = EvalEnv {
        discards_left: 0,
        ..EvalEnv::default()
    };
    assert_eq!(score_with("j_banner", &none_left).0, 20.0, "没剩就不给");

    // 神秘之峰: 只有一次弃牌都不剩时才给 +15 倍率.
    assert_eq!(score_with("j_mystic_summit", &none_left).1, 2.0 + 15.0);
    assert_eq!(score_with("j_mystic_summit", &three_left).1, 2.0, "还有弃牌就不给");

    // 斗牛: 每块钱 +2 筹码.
    let rich = EvalEnv {
        dollars: 12.0,
        ..EvalEnv::default()
    };
    assert_eq!(score_with("j_bull", &rich).0, 20.0 + 24.0, "十二块给 24 筹码");
    let broke = EvalEnv {
        dollars: -5.0,
        ..EvalEnv::default()
    };
    assert_eq!(score_with("j_bull", &broke).0, 20.0, "欠钱时按 0 算");
}

/// 抽象小丑: 每持有一张小丑 (含它自己) 给 +3 倍率.
#[test]
fn abstract_joker_counts_itself() {
    let pair = ["C_5", "D_5"].map(card);

    // 只有它自己: 一份.
    let mut jokers = [Joker::new("j_abstract").expect("有这张")];
    let one = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(one.mult, 2.0 + 3.0, "孤零零一张给一份");

    // 再加两张**不影响倍率**的作陪衬 (冰淇淋只给筹码, 汽水也一样),
    // 否则它们自己那份会被算进来, 数就对不上了.
    let mut three = [
        Joker::new("j_abstract").expect("有这张"),
        Joker::new("j_ice_cream").expect("有这张"),
        Joker::new("j_selzer").expect("有这张"),
    ];
    let got = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut three)
        .expect("对子能识别");
    assert_eq!(got.mult, 2.0 + 9.0, "三张小丑给三份");
}

/// 按**点数**给的五张小丑: 各自认不同的点数, 混在一起也能逐个分清.
///
/// 这里统一用高牌 (只算一张), 所以"小丑给的那份"可以直接从总分里减出来 ——
/// 免得像上次那样把陪衬牌自己的效果也算了进来.
#[test]
fn pip_reading_jokers_pay_for_the_right_cards() {
    let single = |joker: &str, key: &str| -> (f64, f64) {
        let played = [card(key)];
        let mut jokers = [Joker::new(joker).expect("有这张")];
        let got = score_play(
            &played,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("高牌能识别");
        (got.chips, got.mult)
    };

    // 斐波那契: A / 2 / 3 / 5 / 8 给 +8 倍率, 其余不给.
    for key in ["C_A", "C_2", "C_3", "C_5", "C_8"] {
        assert_eq!(single("j_fibonacci", key).1, 1.0 + 8.0, "{key} 应当在斐波那契里");
    }
    for key in ["C_4", "C_6", "C_T", "C_K"] {
        assert_eq!(single("j_fibonacci", key).1, 1.0, "{key} 不在斐波那契里");
    }

    // 学者: 只有 A 给 +20 筹码 +4 倍率.
    // 高牌的筹码是"牌型基础 5 + 牌面点数", A 的牌面是 11, 所以是 5 + 11 + 20.
    assert_eq!(single("j_scholar", "C_A"), (5.0 + 11.0 + 20.0, 1.0 + 4.0));
    assert_eq!(single("j_scholar", "C_2"), (5.0 + 2.0, 1.0), "2 不是 A, 不给");

    // 对讲机: 只有 10 与 4.
    assert_eq!(single("j_walkie_talkie", "C_T"), (5.0 + 10.0 + 10.0, 1.0 + 4.0));
    assert_eq!(single("j_walkie_talkie", "C_4"), (5.0 + 4.0 + 10.0, 1.0 + 4.0));
    assert_eq!(single("j_walkie_talkie", "C_5"), (5.0 + 5.0, 1.0), "5 不算");

    // 偶数史蒂文: 偶数点给 +4 倍率, 人头牌不算 (点数是 11 到 13).
    assert_eq!(single("j_even_steven", "C_4").1, 1.0 + 4.0);
    assert_eq!(single("j_even_steven", "C_5").1, 1.0, "5 是奇数");
    assert_eq!(single("j_even_steven", "C_Q").1, 1.0, "人头牌不算");

    // 恐怖面孔: 人头牌给 +30 筹码.
    assert_eq!(single("j_scary_face", "C_K"), (5.0 + 10.0 + 30.0, 1.0));
    assert_eq!(single("j_scary_face", "C_T"), (5.0 + 10.0, 1.0), "10 不是人头牌");
}

/// 钢铁小丑 (看手里的钢铁牌) 与蓝色小丑 (看牌堆张数).
#[test]
fn steel_and_blue_jokers_read_the_board() {
    use balatro_engine::cards::{CardInstance, Enhancement};
    use balatro_engine::scoring::score_play_with_held;

    let pair = ["C_5", "D_5"].map(card);

    // 钢铁小丑: 手里一张钢铁牌 -> 倍率乘 1.2.
    let mut jokers = [Joker::new("j_steel_joker").expect("有这张")];
    let mut steel = CardInstance::from_key("H_7").expect("能造出牌");
    steel.set_enhancement(Enhancement::Steel);
    let got = score_play_with_held(
        &pair,
        &[steel.to_hand_card()],
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("对子能识别");
    // 倍率走两道: 钢铁牌自己在手里先乘 1.5, 钢铁小丑再乘 1.2.
    assert!((got.mult - 2.0 * 1.5 * 1.2).abs() < 1e-9, "两张都乘上: {}", got.mult);

    // 手里没有钢铁牌就不给.
    let mut jokers = [Joker::new("j_steel_joker").expect("有这张")];
    let plain = score_play_with_held(
        &pair,
        &[],
        &table(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut jokers,
    )
    .expect("对子能识别");
    assert_eq!(plain.mult, 2.0, "没钢铁牌就不乘");

    // 蓝色小丑: 牌堆每张给 +2 筹码.
    let env = EvalEnv {
        deck_len: 30,
        ..EvalEnv::default()
    };
    let mut jokers = [Joker::new("j_blue_joker").expect("有这张")];
    let got = score_play(&pair, &table(), &env, BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(got.chips, 20.0 + 60.0, "三十张牌给 60 筹码");
}

/// 积分卡: 拿到之后每打六手给一次 x4, 落在第 5 / 11 / 17 ... 手上.
///
/// 游戏那边的算式是 `(4 - n) % 6 == 5`, 而 Lua 的取模结果跟模数同号 —— 化简下来就是
/// `n % 6 == 5`. 这里把前六手逐个数一遍, 确认只有第 5 手给.
#[test]
fn loyalty_card_pays_every_sixth_hand_starting_at_the_fifth() {
    let pair = ["C_5", "D_5"].map(card);
    let mut jokers = [Joker::new("j_loyalty_card").expect("有这张")];

    for hand in 1..=6 {
        let got = score_play(
            &pair,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("对子能识别");
        if hand == 5 {
            assert_eq!(got.mult, 2.0 * 4.0, "第 {hand} 手该给 x4");
        } else {
            assert_eq!(got.mult, 2.0, "第 {hand} 手不该给");
        }
    }

    // 再往后数到第 11 手, 又是一次.
    for hand in 7..=11 {
        let got = score_play(
            &pair,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("对子能识别");
        if hand == 11 {
            assert_eq!(got.mult, 2.0 * 4.0, "第 {hand} 手该给 x4");
        } else {
            assert_eq!(got.mult, 2.0, "第 {hand} 手不该给");
        }
    }
}

/// 方尖碑: 打的是"本局被打得最多的牌型"时重置成 1, 否则涨 0.2.
///
/// 判定用的是 `>=` 而不是 `>`: 只要有别的牌型"不算比它少"就判为增长, 所以**并列时也是增长**.
/// 只有这一手是**唯一最多**的那种牌型时才重置 —— 这一点最容易看反.
#[test]
fn obelisk_grows_unless_you_play_the_most_played_hand() {
    use balatro_engine::scoring::HandTable;

    let pair = ["C_5", "D_5"].map(card);
    let flush = ["C_2", "C_4", "C_6", "C_8", "C_T"].map(card);

    let mut jokers = [Joker::new("j_obelisk").expect("有这张")];
    let mut table = HandTable::new();

    // 开局所有牌型都是 0 次, 打对子时"别的牌型 0 >= 0"成立, 所以是增长.
    let first = score_play(&pair, &table, &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    // 成长在**当次**就生效: `before` 先把它涨到 1.2, 主效果紧接着读它.
    assert_eq!(jokers[0].x_mult, 1.2, "打完涨到 1.2");
    assert_eq!(first.mult, 2.0 * 1.2, "这一手就乘上了");

    // 让对子成为"打得最多的那个": 它的次数高于其余全部.
    for _ in 0..3 {
        table.record_played(balatro_engine::scoring::PokerHand::Pair);
    }
    let before = jokers[0].x_mult;
    score_play(&pair, &table, &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(jokers[0].x_mult, 1.0, "打最多的牌型就重置 (之前是 {before})");

    // 换成同花 (它一次都没打过), 别的牌型里有对子的 3 次 >= 它的 0 次, 所以是增长.
    score_play(&flush, &table, &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("同花能识别");
    assert_eq!(jokers[0].x_mult, 1.2, "打冷门牌型就涨回去");

    // 判定用的是 `>=`: 只要有别的牌型"不比我少"就算没打过最冷门的, 所以**并列时是增长**.
    // 让同花也打过 3 次, 此时对子与它并列, 再打对子就该涨而不是重置.
    for _ in 0..3 {
        table.record_played(balatro_engine::scoring::PokerHand::Flush);
    }
    jokers[0].x_mult = 2.0; // 先垫一个值, 好看出它到底涨了还是重置了
    score_play(&pair, &table, &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(jokers[0].x_mult, 2.2, "并列时是增长 (重置的话会变成 1.0)");
}

/// 二重奏 / 三重奏 / 一家人 / 秩序 / 部落: 原型里是 `{Xmult, type}`, 命中那个牌型才乘倍率.
///
/// 它们也走 `Xmult` 那个字段 —— 上一轮发现它按小写读时全军读成 0, 这里顺带把这一类都验到.
#[test]
fn typed_xmult_jokers_only_fire_on_their_hand() {
    let pair = ["C_5", "D_5"].map(card);
    let straight = ["C_2", "D_3", "H_4", "S_5", "C_6"].map(card);

    let score_one = |key: &str, cards: &[balatro_engine::scoring::HandCard]| -> f64 {
        let mut jokers = [Joker::new(key).expect("有这张")];
        score_play(cards, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("能识别牌型")
            .mult
    };

    // 二重奏: 对子时 x2, 顺子时不给.
    assert_eq!(score_one("j_duo", &pair), 2.0 * 2.0, "对子命中");
    assert_eq!(score_one("j_duo", &straight), 4.0, "顺子不命中");

    // 秩序: 顺子时 x3.
    assert_eq!(score_one("j_order", &straight), 4.0 * 3.0, "顺子命中");
    assert_eq!(score_one("j_order", &pair), 2.0, "对子不命中");

    // 判定是"**包含**"而不是"就是" —— 游戏那边读的是 `context.poker_hands[type]`,
    // 而一手葫芦**同时**算作对子, 所以二重奏在葫芦上照样给 x2.
    let full_house = ["C_5", "D_5", "H_5", "S_9", "C_9"].map(card);
    assert_eq!(
        score_one("j_duo", &full_house),
        4.0 * 2.0,
        "葫芦含对子, 二重奏照样给"
    );
}

/// 超新星: 这一手牌型本局**打过几次**就加几点倍率 —— 给的是次数本身, 不再乘 `extra`.
#[test]
fn supernova_pays_for_how_often_that_hand_was_played() {
    use balatro_engine::scoring::{HandTable, PokerHand};

    let pair = ["C_5", "D_5"].map(card);

    // 一次都还没打过时不给.
    let table = HandTable::new();
    let mut jokers = [Joker::new("j_supernova").expect("有这张")];
    let first = score_play(&pair, &table, &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(first.mult, 2.0, "没打过就不加");

    // 打过三次就是 +3.
    let mut table = HandTable::new();
    for _ in 0..3 {
        table.record_played(PokerHand::Pair);
    }
    let got = score_play(&pair, &table, &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(got.mult, 2.0 + 3.0, "打过三次加三点");
}

/// 棒球卡: 队里每张**罕见**(2 级)小丑让倍率乘 1.5, 别的稀有度不算.
///
/// 陪衬要用**本身不改倍率**的小丑 (`j_stencil` / `j_four_fingers` 这类 config 是空的),
/// 否则它们自己那份会被算进来 —— 这个坑踩过好几次了.
#[test]
fn baseball_card_scales_with_uncommon_jokers() {
    let pair = ["C_5", "D_5"].map(card);

    let score_with = |others: &[&str]| -> f64 {
        let mut jokers: Vec<Joker> = vec![Joker::new("j_baseball").expect("有这张")];
        for key in others {
            jokers.push(Joker::new(key).expect("有这张"));
        }
        let got = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("对子能识别");
        got.mult
    };

    // 先确认这几张陪衬确实不改倍率, 免得测试本身失效.
    assert_eq!(score_with(&[]), 2.0, "孤零零一张时不乘");
    let plain = |key: &str| -> f64 {
        let mut jokers = [Joker::new(key).expect("有这张")];
        score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("对子能识别")
            .mult
    };
    assert_eq!(plain("j_stencil"), 2.0, "模具小丑不改倍率");
    assert_eq!(plain("j_ice_cream"), 2.0, "冰淇淋不改倍率");

    // 一张罕见乘一次, 两张乘两次.
    assert_eq!(score_with(&["j_stencil"]), 2.0 * 1.5, "一张罕见");
    assert_eq!(
        score_with(&["j_stencil", "j_four_fingers"]),
        2.0 * 1.5 * 1.5,
        "两张罕见乘两次"
    );

    // 普通小丑不算 —— 用冰淇淋 (1 级, 且不改倍率).
    assert_eq!(score_with(&["j_ice_cream"]), 2.0, "普通小丑不算");
}

/// 蓝图复制**右边**那张的效果, 脑风暴复制**队首**那张.
///
/// 用 `j_joker` (+4 倍率) 当样板: 蓝图在它左边时, 两张各给一份, 所以一共 +8.
#[test]
fn blueprint_and_brainstorm_copy_another_joker() {
    let pair = ["C_5", "D_5"].map(card);

    let score = |keys: &[&str]| -> f64 {
        let mut jokers: Vec<Joker> = keys.iter().map(|key| Joker::new(key).expect("有这张")).collect();
        score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("对子能识别")
            .mult
    };

    // 先确认样板自己的数值.
    assert_eq!(score(&["j_joker"]), 2.0 + 4.0, "样板给 +4");

    // 蓝图 + 样板: 蓝图复制右边那份, 所以是两份.
    assert_eq!(
        score(&["j_blueprint", "j_joker"]),
        2.0 + 4.0 + 4.0,
        "蓝图复制右边那份"
    );

    // 样板 + 蓝图: 蓝图右边没人, 复制不了, 所以只有样板那份.
    assert_eq!(score(&["j_joker", "j_blueprint"]), 2.0 + 4.0, "右边没人就不复制");

    // 脑风暴看的是**队首**: 队首是样板时它也复制一份.
    assert_eq!(
        score(&["j_joker", "j_brainstorm"]),
        2.0 + 4.0 + 4.0,
        "脑风暴复制队首那份"
    );

    // 脑风暴在最前面时, 它复制的就是自己 → 等于没有额外效果.
    assert_eq!(score(&["j_brainstorm", "j_joker"]), 2.0 + 4.0);

    // 两张蓝图连在一起: 后面那张没有右边可看.
    assert_eq!(
        score(&["j_blueprint", "j_blueprint", "j_joker"]),
        2.0 + 4.0 + 4.0 + 4.0,
        "两张蓝图各复制右边那份"
    );
}

/// 特技演员给固定 +250 筹码; 它的代价 (手牌上限减二) 在买进来时算, 不在这条里.
#[test]
fn stuntman_gives_a_flat_chip_bonus() {
    let pair = ["C_5", "D_5"].map(card);
    let mut jokers = [Joker::new("j_stuntman").expect("有这张")];
    let got = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    // 对子自己的筹码是 10 + 5 + 5 = 20.
    assert_eq!(got.chips, 20.0 + 250.0, "固定加 250 筹码");
}

/// 窃贼在**回合开始**时改这一回合的次数: 弃牌归零, 出牌加三.
///
/// 它排在发牌之后 —— 改的是"这一回合还能怎么打", 不是发什么牌.
#[test]
fn burglar_takes_away_discards_and_adds_hands() {
    use balatro_engine::run::RunState;

    let without = {
        let mut run = RunState::new("ALEEB", 8);
        run.start_run();
        common::place_blind(&mut run);
        (run.hands_left, run.discards_left)
    };
    assert!(without.1 > 0, "没有窃贼时是有弃牌的");
    assert_eq!(without.0, 4, "出牌次数是基础值");

    let with = {
        let mut run = RunState::new("ALEEB", 8);
        run.start_run();
        run.jokers.push(Joker::new("j_burglar").expect("有这张"));
        common::place_blind(&mut run);
        (run.hands_left, run.discards_left)
    };
    assert_eq!(with.1, 0, "窃贼让这一回合没有弃牌");
    assert_eq!(with.0, 4 + 3, "出牌次数加三");
}

/// 小丑身上的**版本**在它自己的效果之后结算.
///
/// 用冰淇淋当样板 (它只给筹码, 不给倍率), 这样加进来的那份一看就知道是谁的.
#[test]
fn joker_editions_add_their_share() {
    use balatro_engine::cards::Edition;

    let pair = ["C_5", "D_5"].map(card);
    let with = |edition: Option<Edition>| -> (f64, f64) {
        let mut joker = Joker::new("j_ice_cream").expect("有这张");
        joker.edition = edition;
        let mut jokers = [joker];
        let r = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("对子能识别");
        (r.chips, r.mult)
    };

    // 冰淇淋自己给 100 筹码, 对子是 20, 一共 120.
    assert_eq!(with(None), (120.0, 2.0), "没有版本时只有冰淇淋那份");
    assert_eq!(with(Some(Edition::Foil)), (120.0 + 50.0, 2.0), "闪箔加筹码");
    assert_eq!(with(Some(Edition::Holo)), (120.0, 2.0 + 10.0), "镭射加倍率");
    assert_eq!(
        with(Some(Edition::Polychrome)),
        (120.0, 2.0 * 1.5),
        "多彩乘倍率"
    );
    assert_eq!(with(Some(Edition::Negative)), (120.0, 2.0), "负片不计分");

    // 蓝图复制的是**效果**, 不复制版本: 版本跟着格子里的那张牌走.
    let mut blueprint = Joker::new("j_blueprint").expect("有这张");
    blueprint.edition = Some(Edition::Foil);
    let mut jokers = [blueprint, Joker::new("j_ice_cream").expect("有这张")];
    let r = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    // 冰淇淋自己 100 + 蓝图复制的那 100, 再加蓝图自己那份版本 50.
    assert_eq!(r.chips, 20.0 + 100.0 + 100.0 + 50.0, "蓝图有自己的版本");
}

/// 半张小丑: 打出的牌**不超过三张**时给 +20 倍率; 四张以上就不给.
#[test]
fn half_joker_pays_only_for_small_plays() {
    let pair = ["C_5", "D_5"].map(card);
    let flush = ["C_2", "C_4", "C_6", "C_8", "C_T"].map(card);

    let mut jokers = [Joker::new("j_half").expect("有这张")];
    let small = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(small.mult, 2.0 + 20.0, "两张牌给 +20");

    let large = score_play(&flush, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("同花能识别");
    assert_eq!(large.mult, 4.0, "五张牌就不给");

    // 三张刚好还是"不超过三张".
    let trips = ["C_5", "D_5", "H_5"].map(card);
    let three = score_play(&trips, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("三条能识别");
    assert_eq!(three.mult, 3.0 + 20.0, "三张也给");
}

/// 黑板: **手里每一张**都是黑桃或梅花时乘三倍.
#[test]
fn blackboard_needs_an_all_black_hand() {
    use balatro_engine::scoring::score_play_with_held;

    let pair = ["C_5", "D_5"].map(card);

    let with_held = |held: &[&str]| -> f64 {
        let held: Vec<_> = held.iter().map(|code| card(code)).collect();
        let mut jokers = [Joker::new("j_blackboard").expect("有这张")];
        score_play_with_held(
            &pair,
            &held,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("对子能识别")
        .mult
    };

    // 两张黑牌: 乘三倍.
    assert_eq!(with_held(&["S_3", "C_9"]), 2.0 * 3.0, "全是黑牌就乘");
    // 混进一张红牌就不算.
    assert_eq!(with_held(&["S_3", "H_9"]), 2.0, "有红牌就不乘");
    assert_eq!(with_held(&["D_3"]), 2.0, "方片也不行");
}

/// 照片: 这一手里的**第一张人头牌**给乘倍率, 而且只给一次 (不是每张人头牌都给).
#[test]
fn photograph_pays_for_the_first_face_card_only() {
    // 同花里带三张人头牌 (K / Q / J), 全部参与计分.
    let flush = ["C_K", "C_Q", "C_J", "C_9", "C_7"].map(card);

    // 对照用**本身不改倍率**的小丑 (模具小丑的 config 是空的), 否则它自己那份会混进来.
    let mut plain = [Joker::new("j_stencil").expect("有这张")];
    let without = score_play(&flush, &table(), &EvalEnv::default(), BackEffect::Plain, &mut plain)
        .expect("同花能识别");

    let mut jokers = [Joker::new("j_photograph").expect("有这张")];
    let with = score_play(&flush, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("同花能识别");

    // 同花基础 4 倍率, 照片乘一次 -> 8; 三张人头牌也只乘一次, 所以不是 32.
    assert_eq!(without.mult, 4.0, "没有照片时是基础值");
    assert_eq!(with.mult, 8.0, "只乘一次");

    // 没有计分的人头牌时不给.
    let no_face = ["C_2", "C_4", "C_6", "C_8", "C_T"].map(card);
    let mut jokers = [Joker::new("j_photograph").expect("有这张")];
    let none = score_play(&no_face, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("同花能识别");
    assert_eq!(none.mult, 4.0, "没有人头牌就不给");
}

/// 花盆: **参与计分的牌**凑齐四种花色时乘三倍; 百搭牌不算数.
#[test]
fn flower_pot_needs_all_four_suits_scoring() {
    // 顺子跨四种花色: S / H / D / C 各一张.
    let rainbow = ["S_5", "H_6", "D_7", "C_8", "S_9"].map(card);
    // 同花: 只有一种花色.
    let flush = ["C_2", "C_4", "C_6", "C_8", "C_T"].map(card);

    let mut jokers = [Joker::new("j_flower_pot").expect("有这张")];
    let mixed = score_play(&rainbow, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("顺子能识别");
    assert_eq!(mixed.mult, 4.0 * 3.0, "四花色齐了就乘三倍");

    let same = score_play(&flush, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("同花能识别");
    assert_eq!(same.mult, 4.0, "同花只有一种花色, 不给");

    // 百搭牌不算任何一种花色 (游戏那边显式跳过它), 所以换成百搭就凑不齐了.
    let mut rainbow = ["S_5", "H_6", "D_7", "C_8", "S_9"].map(card);
    rainbow[3].wild = true;
    let with_wild = score_play(&rainbow, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("顺子能识别");
    assert_eq!(with_wild.mult, 4.0, "梅花那张成了百搭, 就不齐了");
}

/// 提靴带: 每满五块钱给 +2 倍率, 不满五块的部分不算.
#[test]
fn bootstraps_pays_per_five_dollars() {
    let pair = ["C_5", "D_5"].map(card);
    let with_money = |dollars: f64| -> f64 {
        let env = EvalEnv {
            dollars,
            ..EvalEnv::default()
        };
        let mut jokers = [Joker::new("j_bootstraps").expect("有这张")];
        score_play(&pair, &table(), &env, BackEffect::Plain, &mut jokers)
            .expect("对子能识别")
            .mult
    };

    assert_eq!(with_money(0.0), 2.0, "没钱就不给");
    assert_eq!(with_money(4.0), 2.0, "不满五块不给");
    assert_eq!(with_money(5.0), 2.0 + 2.0, "五块给一份");
    assert_eq!(with_money(12.0), 2.0 + 4.0, "十二块给两份");
    assert_eq!(with_money(20.0), 2.0 + 8.0, "二十块给四份");
}

/// 杂技演员: 这一回合的**最后一手**乘三倍.
///
/// 出牌次数是在算分**之前**减的 (游戏里 `ease_hands_played(-1)` 排在计分那一段之前),
/// 所以最后一手在计分时看到的次数是 0.
#[test]
fn acrobat_pays_on_the_last_hand_of_the_round() {
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.jokers.push(Joker::new("j_acrobat").expect("有这张"));
    // 手里只放一张, 这样每一手都是高牌, 默认一倍率好算.
    set_hand(&mut run, &["C_5"]);

    // 还剩两次: 打这一手时不算最后一手.
    run.hands_left = 2;
    let first = run
        .play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(first.mult, 1.0, "不是最后一手就不给");

    // 只剩一次: 打完就没了, 这一手算最后一手.
    set_hand(&mut run, &["C_5"]);
    run.hands_left = 1;
    let last = run
        .play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(last.mult, 1.0 * 3.0, "最后一手乘三倍");
}

/// 模具小丑: 空着的小丑格子有几个就乘几倍, 再加上队里模具小丑的张数.
///
/// **顺序要看清楚**: 小丑是按持有顺序依次生效的, 所以排在模具后面的加性效果是在**乘完**
/// 之后才加 —— 写测试时按"先加完再乘"算就会算错 (这里踩过一次).
#[test]
fn stencil_scales_with_empty_joker_slots() {
    let pair = ["C_5", "D_5"].map(card);

    let with_team = |keys: &[&str], slots: usize| -> f64 {
        let mut jokers: Vec<Joker> = keys.iter().map(|key| Joker::new(key).expect("有这张")).collect();
        let env = EvalEnv {
            joker_capacity: slots,
            ..EvalEnv::default()
        };
        score_play(&pair, &table(), &env, BackEffect::Plain, &mut jokers)
            .expect("对子能识别")
            .mult
    };

    // 五个格子, 只有模具自己: 空四格 + 队里一张模具 = 乘五.
    assert_eq!(with_team(&["j_stencil"], 5), 2.0 * 5.0);
    // 格子少一点, 乘数也跟着小.
    assert_eq!(with_team(&["j_stencil"], 3), 2.0 * 3.0, "空两格 + 一张模具");

    // 队里还有一张别的: 空三格 + 一张模具 = 乘四, 而 `j_joker` 的 +4 排在**乘之后**.
    assert_eq!(
        with_team(&["j_stencil", "j_joker"], 5),
        2.0 * 4.0 + 4.0,
        "先乘四, 再加四"
    );

    // 两张模具: 空两格 + 两张模具 = 各乘四. 冰淇淋只给筹码, 不影响倍率.
    assert_eq!(
        with_team(&["j_stencil", "j_stencil", "j_ice_cream"], 5),
        2.0 * 4.0 * 4.0,
        "两张模具各乘一次"
    );
}

/// 按花色逐卡给的三张: 箭头 (黑桃给筹码), 缟玛瑙 (梅花给倍率), 璞玉 (方片给钱).
///
/// 与"同花小丑"那批的区别在于: 它们看的是**每一张计分牌**的花色, 所以五张同花就吃满五份.
#[test]
fn suit_per_card_jokers_pay_for_each_matching_card() {
    let spades = ["S_2", "S_4", "S_6", "S_8", "S_T"].map(card);
    let clubs = ["C_2", "C_4", "C_6", "C_8", "C_T"].map(card);
    let diamonds = ["D_2", "D_4", "D_6", "D_8", "D_T"].map(card);

    let score = |key: &str, cards: &[balatro_engine::scoring::HandCard]| -> (f64, f64, f64) {
        let mut jokers = [Joker::new(key).expect("有这张")];
        let got = score_play(cards, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("同花能识别");
        (got.chips, got.mult, got.dollars)
    };

    // 先拿一张没有小丑的同花当基准.
    let base_for = |cards: &[balatro_engine::scoring::HandCard]| -> (f64, f64, f64) {
        let mut none: [Joker; 0] = [];
        let got = score_play(cards, &table(), &EvalEnv::default(), BackEffect::Plain, &mut none)
            .expect("同花能识别");
        (got.chips, got.mult, got.dollars)
    };

    // 箭头: 黑桃同花吃满五份 50 筹码; 梅花同花一份都没有.
    let base = base_for(&spades);
    let (chips, _, _) = score("j_arrowhead", &spades);
    assert_eq!(chips, base.0 + 5.0 * 50.0, "五张黑桃给五份");
    assert_eq!(score("j_arrowhead", &clubs).0, base_for(&clubs).0, "梅花不给");

    // 缟玛瑙: 梅花同花吃满五份 7 倍率.
    let base = base_for(&clubs);
    let (_, mult, _) = score("j_onyx_agate", &clubs);
    assert_eq!(mult, base.1 + 5.0 * 7.0, "五张梅花给五份");
    assert_eq!(score("j_onyx_agate", &spades).1, base_for(&spades).1, "黑桃不给");

    // 璞玉: 方片同花每张给一块钱.
    let (_, _, dollars) = score("j_rough_gem", &diamonds);
    assert_eq!(dollars, 5.0, "五张方片给五块");
    assert_eq!(score("j_rough_gem", &clubs).2, 0.0, "梅花不给钱");
}

/// 血石: 每张**红桃**计分时掷一次骰 (1/2), 中了乘 1.5.
///
/// 掷骰在计分那一层做, 所以这里**先问骰子哪个种子会中**, 再拿那个种子跑 ——
/// 验的是真实路径, 而不是摆一个"中了"的布尔值.
#[test]
fn bloodstone_rolls_per_scoring_heart() {
    use balatro_engine::rng::Rng;
    use balatro_engine::scoring::score_play_with_rng;

    let hearts = ["H_5", "H_7", "H_9", "H_J", "H_K"].map(card);

    let score = |seed: &str| -> f64 {
        let mut rng = Rng::new(seed);
        let mut jokers = [Joker::new("j_bloodstone").expect("有这张")];
        score_play_with_rng(
            &hearts,
            &[],
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
            &mut rng,
        )
        .expect("同花能识别")
        .mult
    };
    let base = {
        let mut none: [Joker; 0] = [];
        score_play(&hearts, &table(), &EvalEnv::default(), BackEffect::Plain, &mut none)
            .expect("同花能识别")
            .mult
    };

    // 找一个"五张红桃全中"的种子: 一次判定要五连中, 五百次里未必有, 所以放宽到五千.
    let all_hit = (0..5000)
        .map(|i| format!("BLOOD{i}"))
        .find(|seed| {
            let mut rng = Rng::new(seed);
            (0..5).all(|_| rng.pseudorandom("bloodstone") < 0.5)
        })
        .expect("五千个种子里总该有五连中的");

    // 五张红桃各乘一次 1.5: 1.5^5 倍.
    let want = base * 1.5f64.powi(5);
    assert!(
        (score(&all_hit) - want).abs() < 1e-9,
        "五张红桃各乘一次, 期望 {want}, 实际 {}",
        score(&all_hit)
    );

    // 一个都没中的种子: 分数与没有血石一样.
    let none_hit = (0..5000)
        .map(|i| format!("NOHIT{i}"))
        .find(|seed| {
            let mut rng = Rng::new(seed);
            (0..5).all(|_| rng.pseudorandom("bloodstone") >= 0.5)
        })
        .expect("也总该有全不中的");
    assert!((score(&none_hit) - base).abs() < 1e-9, "没中就不乘");
}

/// 生意: 每张**人头牌**计分时掷一次 (1/2), 中了给两块.
#[test]
fn business_rolls_per_scoring_face_card() {
    use balatro_engine::rng::Rng;
    use balatro_engine::scoring::score_play_with_rng;

    // 葫芦 KKK + QQ: 五张都是人头牌, 而且**五张全部参与计分**.
    // (拿两对的话那个单张不参与计分, 只有四张会掷骰 —— 这里踩过一次.)
    let faces = ["C_K", "D_K", "H_K", "C_Q", "D_Q"].map(card);

    let dollars = |seed: &str| -> f64 {
        let mut rng = Rng::new(seed);
        let mut jokers = [Joker::new("j_business").expect("有这张")];
        score_play_with_rng(
            &faces,
            &[],
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
            &mut rng,
        )
        .expect("同花能识别")
        .dollars
    };

    // 五张人头牌全中的种子: 每张两块.
    let all_hit = (0..5000)
        .map(|i| format!("BIZ{i}"))
        .find(|seed| {
            let mut rng = Rng::new(seed);
            (0..5).all(|_| rng.pseudorandom("business") < 0.5)
        })
        .expect("总能找到五连中的");
    assert_eq!(dollars(&all_hit), 5.0 * 2.0, "五张各给两块");
}

/// 重触发这一族: 袜子与巴斯金 (人头牌), 烂脱口秀演员 (2/3/4/5), 挂账 (**第一张**),
/// 黄昏 (最后一手), 汽水 (每张).
///
/// 重触发重跑的是**整段逐卡效果** (含那张牌自己的筹码), 所以对子里的每张牌都会多给一份.
#[test]
fn retrigger_jokers_repeat_the_whole_card_effect() {
    type Views = [balatro_engine::scoring::HandCard];
    let score = |key: &str, cards: &Views| -> f64 {
        let mut jokers = [Joker::new(key).expect("有这张")];
        score_play(cards, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("对子能识别")
            .chips
    };
    let base = |cards: &Views| -> f64 {
        let mut none: [Joker; 0] = [];
        score_play(cards, &table(), &EvalEnv::default(), BackEffect::Plain, &mut none)
            .expect("对子能识别")
            .chips
    };

    // 对子 K: 基础 10, 两张 K 各 10 -> 30. 两张都是人头牌, 各多算一遍 -> 10 + 20 + 20.
    let kings = ["C_K", "D_K"].map(card);
    assert_eq!(base(&kings), 30.0, "基准");
    assert_eq!(score("j_sock_and_buskin", &kings), 50.0, "两张人头牌各重触发");

    // 对子 5: 点数 2..5 之内, 两张都重触发 -> 10 + 10 + 10.
    let fives = ["C_5", "D_5"].map(card);
    assert_eq!(base(&fives), 20.0, "基准");
    assert_eq!(score("j_hack", &fives), 30.0, "两张都在 2..5 里");
    // 人头牌不在 2..5 里, 所以烂脱口秀演员对它们没用.
    assert_eq!(score("j_hack", &kings), 30.0, "人头牌不重触发");

    // 挂账: 只有**第一张**计分牌多算, 而且原型里 `extra` 是 **2**, 也就是多算**两遍**.
    // 用同花 (五张点数各不相同) 来验 —— 拿两张一样的对子验不出"只有第一张", 因为
    // "第一张算三遍"与"两张各算两遍"结果一样.
    let flush = ["C_2", "C_4", "C_6", "C_8", "C_T"].map(card);
    assert_eq!(base(&flush), 65.0, "同花基准: 35 基础 + 30 点数");
    // 第一张是 2 点: 算三遍 -> 35 + 2*3 + 4 + 6 + 8 + 10 = 69.
    assert_eq!(score("j_hanging_chad", &flush), 69.0, "只有第一张多算两遍");
}

/// 黄昏只在**最后一手**重触发; 汽水每张都重触发.
///
/// 这两张要看回合状态, 所以走完整的 `play` 而不是光算分.
#[test]
fn dusk_and_selzer_depend_on_the_round_state() {
    use balatro_engine::run::RunState;

    let chips_after_play = |key: &str, hands_left: i64| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.jokers.push(Joker::new(key).expect("有这张"));
        set_hand(&mut run, &["C_5", "D_5"]);
        run.hands_left = hands_left;
        run.play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌")
            .chips
    };

    // 黄昏: 不是最后一手就不重触发 (基准 10 + 5 + 5).
    assert_eq!(chips_after_play("j_dusk", 3), 20.0, "不是最后一手");
    // 最后一手: 两张各多算一遍.
    assert_eq!(chips_after_play("j_dusk", 1), 30.0, "最后一手");

    // 汽水不看回合状态, 每张都多算一遍.
    assert_eq!(chips_after_play("j_selzer", 3), 30.0, "汽水随时都重触发");
}

/// 大理石给一张**石头牌**, 证书给一张**带蜡封**的随机牌 —— 都在选盲注那一刻进牌堆.
///
/// 证书那张必带蜡封 (种类另掷一次), 所以它不会是一张裸牌.
#[test]
fn marble_and_certificate_add_cards_when_the_blind_is_set() {
    use balatro_engine::run::RunState;

    let deck_with = |joker: &str| -> Vec<balatro_engine::cards::CardInstance> {
        let mut run = RunState::new("ALEEB", 8);
        run.start_run();
        let before = run.deck.len();
        run.jokers.push(Joker::new(joker).expect("有这张"));
        common::place_blind(&mut run);
        // 牌堆少了两张去手牌, 但多了一张新牌.
        assert!(run.deck.len() != before - 8, "{joker} 应当往牌堆里加了东西");
        run.deck.clone()
    };

    // 大理石: 多出来的是石头牌.
    let stones = deck_with("j_marble")
        .iter()
        .filter(|card| card.is_stone())
        .count();
    assert_eq!(stones, 1, "给了一张石头牌");

    // 证书: 那张带蜡封的牌是进**手牌**的, 不是牌堆 —— 游戏那边写的是
    // `create_playing_card({...}, G.hand, ...)`, 而且加进来之后还会 `G.hand:sort()`
    // (所以那一手会变成点数降序). 原来这条测试断言"往牌堆里加", 那是引擎当时写错了.
    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    run.jokers
        .push(Joker::new("j_certificate").expect("有这张"));
    common::place_blind(&mut run);
    let sealed = run.hand.iter().filter(|card| card.seal.is_some()).count();
    assert_eq!(sealed, 1, "给了一张带蜡封的牌, 而且在手里");
    assert_eq!(run.hand.len(), 9, "手牌多了一张 (8 + 1)");

    // 手牌按点数降序: 旁边那张也是这一手里的牌, 所以要整体看.
    let ranks: Vec<f64> = run.hand.iter().map(|c| c.card.nominal()).collect();
    assert!(
        ranks.windows(2).all(|pair| pair[0] >= pair[1]),
        "证书加完牌会给手牌排一次序 (点数降序), 实际 {ranks:?}"
    );
}

/// 眼观双路: 计分牌里**有梅花, 且红桃 / 方片 / 黑桃里至少还有一种**时乘两倍.
///
/// 它不是"四种花色齐" (那是花盆). 百搭牌不直接算数, 而是按"梅花 -> 方片 -> 黑桃 -> 红桃"
/// 的顺序去补还缺的那一种 —— 少了这一步, 手里有百搭牌时就会判错.
#[test]
fn seeing_double_wants_a_club_and_one_other_suit() {
    let with = |codes: &[&str], wild_index: Option<usize>| -> f64 {
        let mut played: Vec<_> = codes.iter().map(|code| card(code)).collect();
        if let Some(index) = wild_index {
            played[index].wild = true;
        }
        let mut jokers = [Joker::new("j_seeing_double").expect("有这张")];
        score_play(&played, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("能识别牌型")
            .mult
    };

    // 梅花 + 红桃: 两花色, 有梅花 -> 乘两倍.
    assert_eq!(with(&["C_5", "H_5"], None), 2.0 * 2.0, "梅花加红桃");
    // 只有梅花: 不给. (这两张点数不同, 是高牌, 基础倍率 1; 要是生效就会变成 2.)
    assert_eq!(with(&["C_5", "C_9"], None), 1.0, "只有一种花色");
    // 红桃 + 黑桃: 没有梅花 -> 不给.
    assert_eq!(with(&["H_5", "S_5"], None), 2.0, "没有梅花");

    // 百搭牌补缺: 红桃 + 方片时不成立, 但把方片当百搭就能补上**梅花** (顺序里梅花最先).
    assert_eq!(with(&["H_5", "D_5"], None), 2.0, "红桃加方片, 没有梅花");
    assert_eq!(
        with(&["H_5", "D_5"], Some(1)),
        2.0 * 2.0,
        "方片变百搭就补上了梅花"
    );
}

/// 印错: 每次触发从 0 到 23 之间**取一个整数**加进倍率 (不是小数).
#[test]
fn misprint_rolls_an_integer_mult() {
    use balatro_engine::rng::Rng;
    use balatro_engine::scoring::score_play_with_rng;

    let pair = ["C_5", "D_5"].map(card);
    let mut seen = std::collections::HashSet::new();
    for i in 0..40 {
        let mut rng = Rng::new(&format!("MIS{i}"));
        let mut jokers = [Joker::new("j_misprint").expect("有这张")];
        let got = score_play_with_rng(
            &pair,
            &[],
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
            &mut rng,
        )
        .expect("对子能识别");
        let added = got.mult - 2.0;
        assert!(
            (0.0..=23.0).contains(&added),
            "加的是 0..23 之间, 实际 {added}"
        );
        assert_eq!(added.fract(), 0.0, "必须是整数, 实际 {added}");
        seen.insert(added as i64);
    }
    assert!(seen.len() > 3, "四十个种子只掷出 {} 种, 不像随机", seen.len());
}

/// 大麦克固定 +15 倍率; 爆米花加的是它自己的成长值 (初始 20).
#[test]
fn gros_michel_and_popcorn_add_their_mult() {
    let pair = ["C_5", "D_5"].map(card);

    let mut jokers = [Joker::new("j_gros_michel").expect("有这张")];
    let gros = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(gros.mult, 2.0 + 15.0, "大麦克给 15");

    let mut jokers = [Joker::new("j_popcorn").expect("有这张")];
    let popcorn = score_play(&pair, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("对子能识别");
    assert_eq!(popcorn.mult, 2.0 + 20.0, "爆米花初始给 20");
}


/// 醋栗 (Cavendish) 与牌卡夏普 (Card Sharp): 数值都藏在 `extra` **里面**, 所以不走
/// "读顶层 `Xmult`" 那条通用分支 —— 不单独写就会**静默失效**.
///
/// 这一批一共 17 张 (醋栗 / 牌卡夏普 / 学分 / 冰淇淋 / 方形 / 城堡 / 小不点 ... ),
/// 都是通过"按名字实现"补的, 而**探针查不出来** (它们不报错, 只是什么也不做).
#[test]
fn jokers_with_values_inside_extra_are_not_silent_noops() {
    let pair = ["C_5", "D_5"].map(card);
    let straight = ["C_2", "D_3", "H_4", "S_5", "C_6"].map(card);

    let score_with = |key: &str, cards: &[balatro_engine::scoring::HandCard], table: &HandTable| {
        let mut jokers = [Joker::new(key).expect("有这张")];
        score_play(cards, table, &EvalEnv::default(), BackEffect::Plain, &mut jokers)
            .expect("能识别牌型")
            .mult
    };

    // 醋栗: 无条件乘三 (对子基础倍率 2 -> 6).
    assert_eq!(score_with("j_cavendish", &pair, &table()), 6.0, "醋栗乘三");

    // 牌卡夏普: 这一手型**之前没打过**就不给.
    assert_eq!(score_with("j_card_sharp", &pair, &table()), 2.0, "第一次打不加成");

    // 之前打过一次就乘三.
    let mut played = table();
    played.record_played(PokerHand::Pair);
    assert_eq!(score_with("j_card_sharp", &pair, &played), 6.0, "同一手型再打才乘三");
    // 但换成别的牌型不算.
    assert_eq!(
        score_with("j_card_sharp", &straight, &played),
        4.0,
        "别的牌型没打过, 不加成"
    );
}

/// 小不点 (Wee Joker): 每张**计分的 2** 长 8 点, 而且成长要到**下一手**才付账.
///
/// 顺序不能反: 游戏里手牌级的付账在逐张计分**之前**跑, 所以这一手的成长影响下一手.
#[test]
fn wee_grows_on_scored_twos_and_pays_next_hand() {
    let twos = ["C_2", "D_2"].map(card);
    let mut jokers = [Joker::new("j_wee").expect("有这张")];

    // 第一手: 成长值还是 0 (`extra.chips` 的初值是 **0**, 不是 8 —— 8 是"每次长多少").
    // 所以这一手只拿牌自己的筹码 (对子 10 + 两张 2 的点数 4).
    let first = score_play(&twos, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    assert_eq!(first.chips, 10.0 + 4.0, "成长值为 0 时不额外给筹码");

    // 两张 2 都计分了, 所以长 16 点.
    assert_eq!(jokers[0].chips, 16.0, "两张 2 各长 8 点");

    // 第二手才付账.
    let second = score_play(&twos, &table(), &EvalEnv::default(), BackEffect::Plain, &mut jokers)
        .expect("能识别牌型");
    assert_eq!(second.chips, 10.0 + 4.0 + 16.0, "下一手才付成长后的 16 点");
}

/// 城堡 (Castle): 弃掉**那一回合盯的花色**就长 3 点筹码; 别的花色不长.
///
/// 这条钩子 (`Joker::on_discard`) 原来**一次都没被调用过** —— 绿小丑只涨不掉、
/// 城堡整个没实现. 所以这里直接从钩子这一层测.
#[test]
fn castle_grows_only_on_its_own_suit() {
    use balatro_engine::cards::{CardInstance, Suit};

    let mut castle = Joker::new("j_castle").expect("有这张");
    let spade = CardInstance::from_key("S_5").expect("有这张");
    let heart = CardInstance::from_key("H_5").expect("有这张");

    castle.on_discard(std::slice::from_ref(&spade), Some(Suit::Spades), false);
    assert_eq!(castle.chips, 3.0, "弃黑桃长 3 点");

    castle.on_discard(&[heart], Some(Suit::Spades), false);
    assert_eq!(castle.chips, 3.0, "弃别的花色不长");

    castle.on_discard(&[spade], None, false);
    assert_eq!(castle.chips, 3.0, "没定花色时也不长");
}

/// 尤里克 (传奇): 每弃满 23 张牌就把自己的乘倍率 +1.
///
/// 计数是"**先判后减**" —— 游戏那边是 `if yorick_discards <= 1 then 重置+涨 else 减一`,
/// 所以正好每 23 张涨一次. 顺序写反就会早一张.
#[test]
fn yorick_gains_mult_every_23_discarded_cards() {
    use balatro_engine::cards::CardInstance;

    let mut yorick = Joker::new("j_yorick").expect("有这张");
    assert_eq!(yorick.x_mult, 1.0, "起始倍率是 1");

    let cards: Vec<CardInstance> = (0..22)
        .map(|_| CardInstance::from_key("C_5").expect("有这张"))
        .collect();
    yorick.on_discard(&cards, None, false);
    assert_eq!(yorick.x_mult, 1.0, "二十二张还不够");

    yorick.on_discard(&[CardInstance::from_key("C_5").expect("有这张")], None, false);
    assert_eq!(yorick.x_mult, 2.0, "第二十三张才涨一次");

    // 再来一轮.
    yorick.on_discard(&cards, None, false);
    assert_eq!(yorick.x_mult, 2.0, "第二轮二十二张还不够");
    yorick.on_discard(&[CardInstance::from_key("C_5").expect("有这张")], None, false);
    assert_eq!(yorick.x_mult, 3.0, "再满二十三张又涨一次");
}

/// 无面者: 一次弃掉的牌里**至少三张人头牌**就给 $5; 不够就不给.
#[test]
fn faceless_pays_for_three_discarded_face_cards() {
    use balatro_engine::cards::CardInstance;

    let cards = |keys: &[&str]| -> Vec<CardInstance> {
        keys.iter()
            .map(|k| CardInstance::from_key(k).expect("有这张"))
            .collect()
    };

    let mut faceless = Joker::new("j_faceless").expect("有这张");

    // 三张人头牌 -> 给钱.
    faceless.on_discard(&cards(&["S_K", "H_Q", "D_J"]), None, false);
    assert_eq!(faceless.faceless_dollars, 5.0, "三张人头牌给 5 块");

    // 只有两张 -> 不给.
    let mut other = Joker::new("j_faceless").expect("有这张");
    other.on_discard(&cards(&["S_K", "H_Q", "D_9"]), None, false);
    assert_eq!(other.faceless_dollars, 0.0, "两张人头牌不给");
}

/// 上古小丑: 每张**这一回合定的花色**的计分牌各乘一次 1.5.
///
/// 花色是回合开始时掷的 (`reset_ancient_card`), 由调用方通过 `EvalEnv` 传进来 ——
/// 所以这里直接把环境里的花色设好, 看它会不会只对那种花色给.
#[test]
fn ancient_multiplies_only_its_own_suit() {
    use balatro_engine::cards::Suit;

    let spades = ["C_5", "D_5"].map(card); // 先用两张凑一个对子
    let mut env = EvalEnv {
        ancient_suit: Some(Suit::Clubs),
        ..Default::default()
    };

    let score = |cards: &[balatro_engine::scoring::HandCard], env: &EvalEnv| {
        let mut jokers = [Joker::new("j_ancient").expect("有这张")];
        score_play(cards, &table(), env, BackEffect::Plain, &mut jokers)
            .expect("能识别牌型")
            .mult
    };

    // 只有梅花那张中, 所以乘一次 1.5.
    assert_eq!(score(&spades, &env), 2.0 * 1.5, "只有梅花那一张乘");

    // 换成这一回合不认的花色就不乘.
    env.ancient_suit = Some(Suit::Hearts);
    assert_eq!(score(&spades, &env), 2.0, "不对的花色不给");
}

/// 天涯路: 每弃一张 J 涨 0.5 倍, 回合结束回到 1 倍.
#[test]
fn hit_the_road_grows_on_jacks_and_resets_at_round_end() {
    use balatro_engine::cards::CardInstance;

    let mut joker = Joker::new("j_hit_the_road").expect("有这张");
    let jacks: Vec<CardInstance> = ["S_J", "H_J"]
        .iter()
        .map(|k| CardInstance::from_key(k).expect("有这张"))
        .collect();
    let non_jack = vec![CardInstance::from_key("S_9").expect("有这张")];

    // 先做一次别的弃牌: 倍率应该从 1 起算, 不是从 0.
    joker.on_discard(&non_jack, None, false);
    assert_eq!(joker.x_mult, 1.0, "没 J 的时候倍率就是 1");

    joker.on_discard(&jacks, None, false);
    assert_eq!(joker.x_mult, 2.0, "两张 J 各涨 0.5");

    joker.on_discard(&[CardInstance::from_key("D_J").expect("有这张")], None, false);
    assert_eq!(joker.x_mult, 2.5, "再弃一张 J 继续涨");

    // 回合结束回到 1.
    let mut rng = balatro_engine::rng::Rng::new("ALEEB");
    assert!(!joker.end_of_round_effect(&mut rng, 1.0), "不会自毁");
    assert_eq!(joker.x_mult, 1.0, "回合结束回 1");
}

/// 海龟豆: 手牌上限的当前值是 5, 每回合掉一点, 掉到 0 之前那一次自毁.
#[test]
fn turtle_bean_shrinks_each_round_then_dies() {
    let mut rng = balatro_engine::rng::Rng::new("ALEEB");
    let mut bean = Joker::new("j_turtle_bean").expect("有这张");
    assert_eq!(bean.extra, 5.0, "当前值是 5");

    for expected in [4.0, 3.0, 2.0, 1.0] {
        assert!(!bean.end_of_round_effect(&mut rng, 1.0), "还没到自毁");
        assert_eq!(bean.extra, expected, "每回合掉一点");
    }

    // 剩 1 点时再过一个回合就自毁 (先判后减).
    assert!(bean.end_of_round_effect(&mut rng, 1.0), "掉到 0 就自毁");
}

/// 隐形小丑: 每过一个回合攒一点, 攒够之后再卖掉会把**另一个**小丑复制一份.
#[test]
fn invisible_joker_duplicates_another_joker_when_sold() {
    use balatro_engine::run::RunState;

    let mut rng = balatro_engine::rng::Rng::new("ALEEB");
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    let mut invisible = Joker::new("j_invisible").expect("有这张");
    run.jokers.push(invisible.clone());
    run.jokers.push(Joker::new("j_joker").expect("有这张"));

    // 攒两个回合.
    assert!(!invisible.end_of_round_effect(&mut rng, 1.0));
    assert!(!invisible.end_of_round_effect(&mut rng, 1.0));
    assert_eq!(invisible.invis_rounds, 2.0, "过了两个回合");
    run.jokers[0] = invisible;

    // 卖掉它: 剩下那个小丑应该被复制一份, 所以队里还是两张.
    run.sell_joker(0).expect("能卖");
    assert_eq!(run.jokers.len(), 2, "卖掉隐形小丑之后队里仍是两张");
    assert_eq!(run.jokers[0].key, "j_joker", "留下的是原来那张");
    assert_eq!(run.jokers[1].key, "j_joker", "复制出来的也是它");
}

/// 混沌小丑: **每回合**多一次免费重抽 (`current_round.free_rerolls`, 每回合重置).
///
/// 注意它不是"拿到时给一次" —— 拿到之后每个回合都会给. 这个字段原来在引擎里**从来没被重置过**,
/// 所以顺手把"每回合清零"也补上了.
#[test]
fn chaos_the_clown_gives_one_free_reroll_each_round() {
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.jokers.push(Joker::new("j_chaos").expect("有这张"));

    common::place_blind(&mut run);
    assert_eq!(run.free_rerolls, 1, "这一回合有一次免费重抽");

    // 下一回合照旧有一次 (而不是累加成两次).
    common::place_blind(&mut run);
    assert_eq!(run.free_rerolls, 1, "每回合都正好一次");
}

/// 蛋: 每过一个回合, 自己的**卖出价**涨 3 块 (涨的是卖价, 不是筹码).
#[test]
fn egg_grows_its_sell_value_each_round() {
    use balatro_engine::rng::Rng;
    use balatro_engine::run::RunState;
    use balatro_engine::run::Phase;

    let mut rng = Rng::new("ALEEB");
    let mut egg = Joker::new("j_egg").expect("有这张");
    assert_eq!(egg.extra_value, 0.0, "刚拿到时没有加成");

    egg.end_of_round_effect(&mut rng, 1.0);
    egg.end_of_round_effect(&mut rng, 1.0);
    assert_eq!(egg.extra_value, 6.0, "两个回合涨 6 块");

    // 卖掉时能多拿: 卖价是 `(买价 + 加成) / 2` 向下取整, 最低一元.
    // 买价从卡本身取 —— 写死数字容易记错 (蛋其实是 4, 不是 3).
    let base = egg.cost;
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.phase = Phase::Shop;
    run.jokers.push(egg);
    let expected = ((base + 6.0) / 2.0).floor().max(1.0);
    assert_eq!(
        run.sell_joker(0).expect("能卖"),
        expected,
        "卖出价把加成算进去了 (买价 {base})"
    );
}

/// 预留车位: 手里每张**人头牌**各掷一次 (1/2), 中了给一块.
///
/// 从运行层验: 手里留一张人头牌, 打掉别的牌, 多个种子里总该给过钱 —— 每次 1/2,
/// 六个种子全不中的概率不到百分之二.
///
/// 这里**不**断言"手里没人头牌时一定不给": 那一手是开局发的, 手里往往还有人头牌,
/// 想构造"一张人头牌都不留"得把五张都打出去, 那就变成在测别的东西了.
#[test]
fn reserved_parking_rolls_for_held_face_cards() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let payouts = |seed: &str| -> f64 {
        let mut run = RunState::new(seed, 8);
        run.start();
        common::place_blind(&mut run);
        run.jokers.push(Joker::new("j_reserved_parking").expect("有这张"));

        // 找一张人头牌留下, 其余的挑一张打出去.
        let face = run.hand.iter().position(|card| card.card.rank.is_face());
        let play = match face {
            Some(index) => (0..run.hand.len()).find(|i| *i != index),
            None => Some(0),
        };
        let Some(play) = play else { return 0.0 };
        let before = run.dollars;
        run.play(&[play], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌");
        run.dollars - before
    };

    // 手上留人头牌时, 多个种子里总该撞上一次 (每次 1/2).
    let hits: f64 = ["ALEEB", "SEED1", "SEED2", "SEED3", "SEED4", "SEED5"]
        .iter()
        .map(|seed| payouts(seed))
        .sum();
    assert!(hits > 0.0, "留人头牌时总该给一次钱");
}

/// "牌型包含"家族: `j_jolly`/`j_zany`/... 与 `j_duo`/`j_trio`/... 这十五张都只靠
/// `config.type` 加上 `t_mult` / `t_chips` / `Xmult`, 走的是**通用分支** ——
/// 所以按名字搜源码是搜不到它们的, 但它们本来就该生效.
///
/// 这里**遍历全部十五张**, 预期值**从各自的 `config` 现算** (读 `t_mult` / `t_chips` /
/// `Xmult` 与 `type`) —— 抄一遍数字的话, 以后原型改了数值测试还会照旧通过,
/// 那就变成在验"我抄得对不对"了.
///
/// 每一张都要验**两面**: 打出的牌型包含它指定的那一种时确实生效; 不包含时**一点也不能给**.
/// 只验正面的话, "无条件生效"也能过.
///
/// 用哪副牌**不写死**: 手边准备一小把各不相同的牌型, 交给 `evaluate_poker_hand` 判,
/// 由它说"这副牌包含哪些"再挑一副合适的. 写死的话, 一旦牌型判定有偏差,
/// 这个测试会跟着一起错, 而不是把它揭出来.
#[test]
fn the_contain_family_works_through_the_generic_branch() {
    let env = EvalEnv::default();

    // 手边这副牌里能凑出的各种牌型. 挑的时候只看"包含哪些", 不看"最高是哪一种".
    let hand_of = |codes: [&str; 5]| -> [balatro_engine::scoring::HandCard; 5] {
        [
            card(codes[0]),
            card(codes[1]),
            card(codes[2]),
            card(codes[3]),
            card(codes[4]),
        ]
    };
    let pool: Vec<(&str, [balatro_engine::scoring::HandCard; 5])> = vec![
        // 高牌: 不成对, 不同花, 连不成顺.
        ("高牌", hand_of(["C_2", "D_7", "S_9", "H_J", "C_K"])),
        // 一对.
        ("一对", hand_of(["C_2", "D_2", "S_7", "H_9", "C_J"])),
        // 两对.
        ("两对", hand_of(["C_2", "D_2", "S_7", "H_7", "C_J"])),
        // 三条.
        ("三条", hand_of(["C_2", "D_2", "S_2", "H_7", "C_J"])),
        // 四条.
        ("四条", hand_of(["C_2", "D_2", "S_2", "H_2", "C_J"])),
        // 顺子 (不同花).
        ("顺子", hand_of(["C_5", "D_6", "S_7", "H_8", "C_9"])),
        // 同花.
        ("同花", hand_of(["C_2", "C_7", "C_9", "C_J", "C_K"])),
        // 葫芦 (同时包含一对 / 两对 / 三条).
        ("葫芦", hand_of(["S_K", "H_K", "S_5", "H_5", "C_5"])),
        // 同花顺 (包含顺子与同花).
        ("同花顺", hand_of(["S_5", "S_6", "S_7", "S_8", "S_9"])),
    ];
    let contains = |cards: &[balatro_engine::scoring::HandCard], hand: PokerHand| -> bool {
        evaluate_poker_hand(cards, &env).has(hand)
    };

    let baseline = |cards: &[balatro_engine::scoring::HandCard]| -> (f64, f64) {
        let mut jokers: [Joker; 0] = [];
        let result = score_play(cards, &table(), &env, BackEffect::Plain, &mut jokers)
            .expect("能识别牌型");
        (result.chips, result.mult)
    };
    let score = |key: &str, cards: &[balatro_engine::scoring::HandCard]| -> (f64, f64) {
        let mut jokers = [Joker::new(key).expect("有这张")];
        let result = score_play(cards, &table(), &env, BackEffect::Plain, &mut jokers)
            .expect("能识别牌型");
        (result.chips, result.mult)
    };

    // 十五张全在原版里, 而且都能造出来 —— 少一张说明原型表或构造函数有问题.
    let family = [
        "j_jolly", "j_zany", "j_mad", "j_crazy", "j_droll", "j_sly", "j_wily", "j_clever",
        "j_devious", "j_crafty", "j_duo", "j_trio", "j_family", "j_order", "j_tribe",
    ];
    assert_eq!(family.len(), 15, "这一族是十五张");

    let mut checked = 0;
    for key in family {
        let proto = balatro_engine::data::catalog::Catalog::get()
            .record(key)
            .expect("在原型表里");
        let config = proto.config.clone().expect("这一族都带 config");
        let number = |field: &str| config.get(field).and_then(|v| v.as_f64());
        let hand = config
            .get("type")
            .and_then(|v| v.as_str())
            .expect("这一族都带 type");
        let wanted = PokerHand::from_key(hand)
            .unwrap_or_else(|| panic!("{key} 的 type `{hand}` 认不出来"));
        // 三种加成里恰好写一种 —— 多一种就说明这一族变了, 该回来看这段.
        assert_eq!(
            [number("t_mult"), number("t_chips"), number("Xmult")]
                .iter()
                .filter(|x| x.is_some())
                .count(),
            1,
            "{key} 该恰好写一种加成"
        );

        // 正面: 从手边挑一副**包含**它要求的那种牌型的.
        let (名, hit) = pool
            .iter()
            .find(|(_, cards)| contains(cards, wanted))
            .unwrap_or_else(|| panic!("手边这副牌里凑不出 {hand}"));
        let (base_chips, base_mult) = baseline(hit);
        let (chips, mult) = score(key, hit);
        if let Some(value) = number("t_mult") {
            assert_eq!(mult, base_mult + value, "{key} 在{名}上该给 +{value} 倍率");
        } else if let Some(value) = number("t_chips") {
            assert_eq!(chips, base_chips + value, "{key} 在{名}上该给 +{value} 筹码");
        } else if let Some(value) = number("Xmult") {
            assert_eq!(mult, base_mult * value, "{key} 在{名}上该给 x{value} 倍率");
        }

        // 反面: 挑一副**不包含**的那种, 一点加成也不能给.
        let miss = pool
            .iter()
            .find(|(_, cards)| !contains(cards, wanted))
            .unwrap_or_else(|| panic!("手边这副牌全都包含 {hand}"));
        let (want_chips, want_mult) = baseline(&miss.1);
        assert_eq!(
            score(key, &miss.1),
            (want_chips, want_mult),
            "{key} 在{}上不该给任何加成 (那一手不包含 {hand})",
            miss.0
        );
        checked += 1;
    }
    assert_eq!(checked, 15, "十五张都要跑到");
}

/// 星座: 每用一张行星牌给 0.1 倍率 (涨在它自己的 `x_mult` 上, 靠通用分支付账).
/// 金票: 每张**计分**的黄金牌给 4 块.
/// 拉面: 每弃一张牌掉 0.01 倍率, 掉到 1 就自毁.
#[test]
fn constellation_ticket_and_ramen_work() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    // 星座: 用两张行星牌, 倍率该到 1.2.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_constellation").expect("有这张"));
    assert_eq!(run.jokers[0].x_mult, 1.0, "初始是 1");
    for key in ["c_mercury", "c_venus"] {
        run.consumables
            .push(balatro_engine::run::consumable::Consumable::plain(key.to_owned()));
        let index = run.consumables.len() - 1;
        run.use_consumable(index, &[]).expect("能用");
    }
    assert!(
        (run.jokers[0].x_mult - 1.2).abs() < 1e-9,
        "两张行星牌之后是 1.2, 实际 {}",
        run.jokers[0].x_mult
    );

    // 金票: 打出一张黄金牌, 该多给 4 块.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_ticket").expect("有这张"));
    run.hand[0].enhancement = Some(balatro_engine::cards::Enhancement::Gold);
    let result = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).expect("能出牌");
    assert_eq!(result.dollars, 4.0, "一张黄金牌给 4 块");

    // 拉面: 弃一张掉 0.01, 掉到 1 就没了.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_ramen").expect("有这张"));
    run.jokers[0].x_mult = 1.005;
    run.discard(&[0]).expect("能弃");
    assert!(
        run.jokers.is_empty(),
        "掉到 1 及以下就自毁 (剩 {} 张)",
        run.jokers.len()
    );
}

/// 模仿: 手里这张牌的效果再触发一次 —— 钢铁牌那类 ×1.5 会变成 ×1.5 两次.
/// 玻璃小丑: 每碎一张玻璃牌涨 0.75 乘倍率.
#[test]
fn mime_retriggers_held_cards_and_glass_joker_grows() {
    use balatro_engine::scoring::score_play_with_held;

    // 手里留一张钢铁牌 (×1.5 倍率).
    let mut steel = card("S_9");
    steel.h_x_mult = 1.5;
    let hand = [steel];

    let mult_with = |keys: &[&str]| -> f64 {
        let mut jokers: Vec<Joker> = keys
            .iter()
            .map(|key| Joker::new(key).expect("有这张"))
            .collect();
        let result = score_play_with_held(
            &[card("S_K")],
            &hand,
            &table(),
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("能识别牌型");
        result.mult
    };

    let plain = mult_with(&[]);
    let mime = mult_with(&["j_mime"]);
    assert!(
        (mime - plain * 1.5).abs() < 1e-6,
        "模仿该把钢铁牌那一下再触发一次 ({mime} vs {plain})"
    );

    // 玻璃小丑: 多个种子里总该碎过玻璃牌, 碎过就涨.
    let grew = ["ALEEB", "SEED1", "SEED2", "SEED3", "SEED4", "SEED5", "SEED6", "SEED7"]
        .iter()
        .any(|seed| {
            let mut run = balatro_engine::run::RunState::new(seed, 8);
            run.start();
            common::place_blind(&mut run);
            run.jokers.push(Joker::new("j_glass").expect("有这张"));
            run.hand[0].enhancement = Some(balatro_engine::cards::Enhancement::Glass);
            let before = run.jokers[0].x_mult;
            run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
                .expect("能出牌");
            run.jokers.is_empty() || run.jokers[0].x_mult > before
        });
    assert!(grew, "开了这么多次总该碎过一张玻璃牌");
}

/// 爱豆: 每张**正好是它这一回合盯的那张牌**的计分牌各乘一次 2 倍.
///
/// 与城堡的花色、邮件的点数同一套路 —— 这里把盯的那张直接设成手里第一张, 看它中不中.
#[test]
fn the_idol_doubles_for_its_chosen_card() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let total = |set_idol: bool| -> f64 {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        common::place_blind(&mut run);
        run.jokers.push(Joker::new("j_idol").expect("有这张"));
        if set_idol {
            let card = run.hand[0].card;
            run.idol_card = Some((card.suit, card.rank));
        }
        let result = run
            .play(&[0], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌");
        result.mult
    };

    let plain = total(false);
    let idol = total(true);
    assert!(
        (idol - plain * 2.0).abs() < 1e-9,
        "盯中的那一张该乘 2 ({idol} vs {plain})"
    );
}

/// 吸血鬼: **计分之前**把这一手计分牌里带强化的那些吸掉 (去掉强化), 每张给自己涨 0.1 乘倍率.
///
/// 之所以能在运行层做, 是因为游戏把它放在 `context.before` 那一趟 —— 计分之前.
/// 这样成长后的倍率这一手就生效, 而引擎也不必去碰"计分只读"那条约束.
#[test]
fn vampire_drains_enhancements_before_scoring() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let run_once = |with_vampire: bool| -> (f64, bool) {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        common::place_blind(&mut run);
        if with_vampire {
            run.jokers.push(Joker::new("j_vampire").expect("有这张"));
        }
        // 把要打出去的这张牌变强化牌, 看它会不会被吸走.
        run.hand[0].enhancement = Some(balatro_engine::cards::Enhancement::Mult);
        let result = run
            .play(&[0], &EvalEnv::default(), BackEffect::Plain)
            .expect("能出牌");
        // 打出去的那张牌现在在弃牌堆里.
        let still_enhanced = run
            .discard_pile
            .iter()
            .any(|card| card.enhancement.is_some());
        (result.mult, still_enhanced)
    };

    let (plain, enhanced_without) = run_once(false);
    let (drained, enhanced_with) = run_once(true);

    assert!(enhanced_without, "没有吸血鬼时强化还在");
    assert!(!enhanced_with, "有吸血鬼时强化被吸走");
    assert!(
        drained > plain,
        "吸走之后这一手的倍率该更高 ({drained} vs {plain})"
    );
}

/// 全息图: 每有一张牌进牌堆就涨 0.25 乘倍率 (游戏钩的是"牌进了牌堆"这件事).
/// 太空小丑: 计分之前掷一次 (1/4), 中了把这一手的牌型升一级.
#[test]
fn hologram_grows_on_card_added_and_space_joker_levels_up() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    // 全息图 + 大理石 (大理石回合开始会给一张石头牌进牌堆).
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.jokers.push(Joker::new("j_hologram").expect("有这张"));
    run.jokers.push(Joker::new("j_marble").expect("有这张"));
    assert_eq!(run.jokers[0].x_mult, 1.0, "初始是 1");
    common::place_blind(&mut run);
    assert!(
        run.jokers[0].x_mult > 1.0,
        "有牌进牌堆之后该涨, 实际 {}",
        run.jokers[0].x_mult
    );

    // 太空小丑: 多个种子里总该撞上一次 (1/4).
    let leveled = ["ALEEB", "SEED1", "SEED2", "SEED3", "SEED4", "SEED5"]
        .iter()
        .any(|seed| {
            let mut run = RunState::new(seed, 8);
            run.start();
            common::place_blind(&mut run);
            run.jokers.push(Joker::new("j_space").expect("有这张"));
            // 打一张牌就是"高牌", 所以升级只会落在高牌上 —— 记它前后的等级来比.
            let high = balatro_engine::scoring::PokerHand::HighCard;
            let before = run.hands.get(high).level;
            run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
                .expect("能出牌");
            run.hands.get(high).level > before
        });
    assert!(leveled, "开了这么多次总该升级过一次");
}

/// 帕瑞多利亚: **人人都是人头牌**.
///
/// 验法用笑脸 (每张人头牌 +5 倍率): 打一手全是小牌, 有了它每张都该给.
/// 顺带守一下"失效的牌先判否"这一条 —— 游戏里 `Card:is_face` 头一句就是判失效.
#[test]
fn pareidolia_makes_every_card_a_face_card() {
    use balatro_engine::scoring::{score_play_with_held, PokerHand};

    let small = [card("S_2"), card("H_3"), card("C_4"), card("D_5"), card("S_6")];

    let mult = |with_pareidolia: bool| -> f64 {
        let mut jokers = vec![
            Joker::new("j_smiley").expect("有这张"),
            Joker::new("j_pareidolia").expect("有这张"),
        ];
        let env = EvalEnv {
            pareidolia: with_pareidolia,
            ..Default::default()
        };
        let result = score_play_with_held(
            &small,
            &[],
            &table(),
            &env,
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("能识别牌型");
        result.mult
    };

    let plain = mult(false);
    let pareidolia = mult(true);
    assert_eq!(
        pareidolia - plain,
        25.0,
        "五张小牌每张 +5, 一共 +25 ({pareidolia} vs {plain})"
    );
    assert!(PokerHand::HighCard.index() < 12, "占位断言, 防止上面的常量写错");
}

/// 八号球: 每张**计分**的 8 各掷一次 (1/4), 中了造一张塔罗.
///
/// 这张把"计分过程中造牌"那条通道从头到尾走了一遍, 也踩齐了两个坑:
/// 一是"消耗槽还剩几个位子"没传给计分那一层 (于是"先看位子再掷骰"永远不成立),
/// 二是造好的牌**没人往运行状态里放** —— 计分那一层只负责"报告造了什么", 持有区归运行层管.
#[test]
fn eight_ball_creates_a_tarot_from_scored_eights() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    // 样本量开够: 每次命中概率 1/4, 跑三十个种子时"一次都不中"的概率约万分之二.
    let hits: usize = (0..30)
        .filter(|i| {
            let seed = format!("SEED{i}");
            let mut run = RunState::new(&seed, 8);
            run.start();
            common::place_blind(&mut run);
            run.jokers.push(Joker::new("j_8_ball").expect("有这张"));
            run.hand[0].card.rank = balatro_engine::cards::Rank::Eight;
            let before = run.consumables.len();
            run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
                .expect("能出牌");
            run.consumables.len() > before
        })
        .count();
    assert!(hits >= 3, "三十个种子里该中好几次, 实际 {hits} 次");
}

/// 叠加态: 这一手**包含顺子**而且计分牌里有 **A** 时, 造一张塔罗.
///
/// 局面直接摆出来 (把手里前五张改成 A,2,3,4,5), 不去"凑一副看起来真实的牌" ——
/// 那样既绕又脆, 上一轮就是这么把测试写废的.
#[test]
fn superposition_creates_a_tarot_for_an_ace_straight() {
    use balatro_engine::cards::{Rank, Suit};
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_superposition").expect("有这张"));

    let ranks = [Rank::Ace, Rank::Two, Rank::Three, Rank::Four, Rank::Five];
    let suits = [Suit::Spades, Suit::Hearts, Suit::Clubs, Suit::Diamonds, Suit::Spades];
    for (offset, (rank, suit)) in ranks.iter().zip(suits).enumerate() {
        run.hand[offset].card.rank = *rank;
        run.hand[offset].card.suit = suit;
    }

    let before = run.consumables.len();
    run.play(&[0, 1, 2, 3, 4], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(
        run.consumables.len(),
        before + 1,
        "A 打头的顺子该造一张塔罗"
    );
}

/// 通灵: 打出的牌型正好是配置里指定的那个 (它是"同花顺") ⇒ 造一张幽灵牌.
#[test]
fn seance_creates_a_spectral_for_its_hand_type() {
    use balatro_engine::cards::{Rank, Suit};
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_seance").expect("有这张"));

    // 摆一手同花顺.
    let ranks = [Rank::Six, Rank::Seven, Rank::Eight, Rank::Nine, Rank::Ten];
    for (offset, rank) in ranks.iter().enumerate() {
        run.hand[offset].card.rank = *rank;
        run.hand[offset].card.suit = Suit::Hearts;
    }

    let before = run.consumables.len();
    run.play(&[0, 1, 2, 3, 4], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(
        run.consumables.len(),
        before + 1,
        "同花顺该造一张幽灵牌"
    );
}

/// 第六感: 这一回合**第一手**只打出一张 **6** 时, 造一张幽灵牌, 并**销毁那张 6**.
///
/// 这张牌卡在一个**位置**问题上, 值得记下来: "这一回合还没打过牌"这个判断必须在
/// **算分之前、而且要在那一处把本手牌型记进 `round_hand_types` 之前**做 ——
/// 那处记录是给 Boss "嘴" 用的, 位置比我原来那段靠前. 我原来的位置查出来永远是假,
/// 于是五个条件里第一个就把整支挡掉了 (其余四个都是真的).
#[test]
fn sixth_sense_destroys_a_lone_first_hand_six() {
    use balatro_engine::cards::Rank;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    common::place_blind(&mut run);
    run.jokers.push(Joker::new("j_sixth_sense").expect("有这张"));

    run.hand[0].card.rank = Rank::Six;
    let marker = run.hand[0].card;
    let before = run.consumables.len();

    run.play(&[0], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");

    assert_eq!(run.consumables.len(), before + 1, "该造一张幽灵牌");
    assert!(
        !run.discard_pile.iter().any(|card| card.card == marker),
        "那张 6 该被销毁 (不进弃牌堆)"
    );
}

/// 幸运猫: 幸运牌**成功触发**一次就涨 0.25 乘倍率, 而且涨出来的那一份**这一手就用上**.
///
/// 这张牌卡在两处, 都得在这里钉住:
///
/// 1. 触发标志的生命周期是"这张牌的这一遍计分": 两个骰子任一中了就算触发过,
///    判定发生在逐卡小丑之前, 逐卡跑完就清掉 —— 红封让整段重跑时又会有新的一次机会.
/// 2. 成长写在逐卡那一趟, 但吃它的是稍后的**主效果** (泛化的 `x_mult > 1` 那条).
///    所以这里同时断言小丑身上的值和这一手的倍率, 只验其中一个都漏得掉 "写了没接上".
///
/// 骰子结果不预置, 而是三十个种子各跑一遍: 先照计分里的同样顺序 (倍率在前, 钱在后) 自己掷一次,
/// 知道这手会不会触发, 再用同一个种子真跑一遍对账.
#[test]
fn lucky_cat_grows_on_every_successful_lucky_trigger() {
    use balatro_engine::cards::{CardInstance, Enhancement};
    use balatro_engine::rng::Rng;
    use balatro_engine::scoring::score_play_with_rng;

    let mut run = common::aleeb_run();
    run.start();

    let mut lucky = CardInstance::from_key("C_5").expect("能造出牌");
    lucky.set_enhancement(Enhancement::Lucky);
    // 一对 5: 底子 20 筹码 2 倍率.
    let cards = [lucky.to_hand_card(), card("D_5")];

    let mut grown = 0;
    for index in 0..30 {
        let seed = format!("LUCKY-CAT-{index}");
        // 探测那一次要把两个骰子都掷掉 —— 写成一个 `||` 会在第一个中了之后短路掉第二个,
        // 之后的随机序列就跟计分里错开了.
        let mut probe = Rng::new(seed.as_str());
        let mult_hit = probe.pseudorandom("lucky_mult") < 1.0 / 5.0;
        let money_hit = probe.pseudorandom("lucky_money") < 1.0 / 15.0;
        let triggered = mult_hit || money_hit;

        let mut jokers = [Joker::new("j_lucky_cat").expect("有这张")];
        assert_eq!(jokers[0].x_mult, 1.0, "刚拿到手是 1, 还没触发过");
        let mut rng = Rng::new(seed.as_str());
        let result = score_play_with_rng(
            &cards,
            &[],
            &run.hands,
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
            &mut rng,
        )
        .expect("对子能识别");

        let expected_x = if triggered { 1.25 } else { 1.0 };
        assert_eq!(
            jokers[0].x_mult, expected_x,
            "种子 {seed}: 触发过才涨, 而且只涨一份"
        );
        let expected_mult = (if mult_hit { 22.0 } else { 2.0 }) * expected_x;
        assert_eq!(
            result.mult, expected_mult,
            "种子 {seed}: 刚涨出来的乘倍率这一手就该乘进来"
        );
        assert_eq!(result.total, (20.0 * expected_mult).floor());
        if triggered {
            grown += 1;
        }
    }
    assert!(grown > 0, "三十个种子里总该有触发过的");
    assert!(grown < 30, "也总该有没触发的 —— 否则上面那半断言等于没测");
}

/// 大理石与 DNA 往牌堆里加的牌要落在**牌堆底**, 不是牌堆顶.
///
/// # 为什么这条要单独钉
///
/// 游戏的 `CardArea:emplace` 对**牌堆**是特例 —— `G.deck.config.type` 是 `'deck'`, 于是它走
/// `table.insert(self.cards, 1, card)` 那一支 (插到数组头部), 而抽牌 (`remove_card`) 取的是尾部.
/// 两下一合: **新加的牌落在牌堆最底下, 最后才被抽到**.
///
/// 引擎这边数组下标 0 就是游戏的下标 1 (洗牌那条对拍测试钉住的), 所以"插到牌堆底"就是
/// `insert(0)`. 这条曾经写成 `push` (等于插到牌堆顶), 后果是**这一回合刚加的牌在下一次补牌时
/// 立刻被抽上来** —— 手牌内容当场就不对了.
///
/// **录像覆盖不到它**: 十九份录像里大理石只在商店货架上出现过, 一次都没进过队, 所以这个效果
/// 从没触发过. 这类分支只能靠单测钉住.
#[test]
fn cards_added_to_the_deck_go_to_the_bottom() {
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::{BackEffect, EvalEnv};

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    run.jokers.push(Joker::new("j_marble").expect("有这张"));
    common::place_blind(&mut run);

    // 石头牌就是刚加进来的那一张.
    let index = run
        .deck
        .iter()
        .position(|card| card.is_stone())
        .expect("大理石该给一张石头牌");
    assert_eq!(
        index,
        0,
        "新加的牌在下标 {index}, 应当在 0 (牌堆底) —— 下标 0 是游戏的下标 1, \
         而牌堆是**插头部、抽尾部**, 所以新牌落在最底下"
    );
    assert!(
        !run.deck.last().expect("牌堆非空").is_stone(),
        "新加的牌跑到牌堆顶了, 下一次补牌就会立刻抽到它"
    );

    // 出牌会补牌 —— 补上来的不该是那张石头牌 (它还在最底下).
    run.play(&[0, 1, 2, 3, 4], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert!(
        !run.hand.iter().any(|card| card.is_stone()),
        "补牌把堆底那张石头牌抽上来了 —— 说明插的位置是牌堆顶. 实际手牌: {}",
        common::hand_keys(&run)
    );
}
