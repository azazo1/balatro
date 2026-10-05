//! 塔罗牌.
//!
//! 原版有 22 张塔罗, 这里先做力量 —— 它是"底注 3 之后发牌对不上"的直接原因:
//! ALEEB 那局的 agent 在第二个底注的商店里用力量把方片 Q 升成了方片 K, 于是牌堆里多了一张
//! `D_K` 少了一张 `D_Q`, 后面的发牌自然就变了.
//!
//! `card.lua` 里三种效果各有分支:
//!
//! - `Death`: 把横坐标最大的那张复制给其余选中的牌,
//! - `Strength`: 点数升一级, `A` 绕回 `2`, `K` 升到 `A`,
//! - `suit_conv`: 改花色,
//! - 其余 `mod_conv`: 换一张强化牌原型.
//!
//! 目前只实现了 Strength.

mod common;

use balatro_engine::cards::{CardInstance, Enhancement, Rank, Suit};
use balatro_engine::run::{ActionError, Phase};
use balatro_engine::scoring::{BackEffect, EvalEnv, HandTable, PokerHand, score_play};
use common::{aleeb_run, card, hand_keys};

#[test]
fn rank_up_walks_by_pip_value_not_by_enum_order() {
    // 枚举的声明顺序是按字符码排的 (2..9, A, J, K, Q, T), 与点数顺序不同,
    // 所以这里逐个写清相邻关系.
    assert_eq!(Rank::Two.up(), Rank::Three);
    assert_eq!(Rank::Nine.up(), Rank::Ten);
    assert_eq!(Rank::Ten.up(), Rank::Jack);
    assert_eq!(Rank::Queen.up(), Rank::King);
    assert_eq!(Rank::King.up(), Rank::Ace);
    assert_eq!(Rank::Ace.up(), Rank::Two, "A 绕回 2, 不是变成别的");
}

#[test]
fn strength_raises_the_chosen_cards_and_is_consumed() {
    let mut run = aleeb_run();
    run.start();
    assert_eq!(run.phase, Phase::SelectingHand);
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_strength".to_owned()));

    // 开局前两张是 C_T 与 D_T, 各升一级都成 J.
    run.use_consumable(0, &[0, 1]).expect("能用");
    assert_eq!(hand_keys(&run), "C_J,D_J,S_9,S_7,H_6,H_5,H_4,D_2");
    assert!(run.consumables.is_empty(), "塔罗用完就没了");
}

#[test]
fn strength_can_turn_a_queen_into_a_second_king() {
    // 这正是 ALEEB 那局发生的事: 牌堆里原本只有一张 D_K, 力量把 D_Q 也变成了 K.
    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_strength".to_owned()));

    // 换一手带 Q 的牌来试: 开局手牌里没有 Q, 先手改几张凑出来.
    run.hand[0].card.rank = Rank::Queen;
    run.hand[1].card.rank = Rank::Queen;
    run.use_consumable(0, &[0, 1]).expect("能用");
    assert_eq!(run.hand[0].card.rank, Rank::King);
    assert_eq!(run.hand[1].card.rank, Rank::King);
    // 花色是各张牌自己的 (这两张开局分别是梅花与方片), 升点数不该动它.
    assert_eq!(run.hand[0].card.suit, Suit::Clubs);
    assert_eq!(run.hand[1].card.suit, Suit::Diamonds);
}

#[test]
fn using_a_tarot_rejects_bad_input() {
    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_strength".to_owned()));

    // 力量最多选两张, 选三张要拒.
    assert!(matches!(
        run.use_consumable(0, &[0, 1, 2]),
        Err(ActionError::TooManyCards { limit: 2, got: 3 })
    ));
    // 一张都不选也要拒.
    assert_eq!(run.use_consumable(0, &[]), Err(ActionError::NoCards));
    // 下标越界.
    assert_eq!(run.use_consumable(0, &[99]), Err(ActionError::BadIndex(99)));
    // 持有区里没有那张牌.
    assert_eq!(run.use_consumable(9, &[0]), Err(ActionError::BadIndex(9)));
    assert_eq!(run.consumables.len(), 1, "被拒时不消耗牌");
}

/// 消耗牌现在**全部实现**了: 任何一张用下去都不该报 `NotImplemented`.
///
/// 这条是覆盖率的看门测试 —— 以后加了新牌却忘了写效果, 它会红.
/// (给不出目标的那些会报 `NoCards` / `TooManyCards`, 那是正常的用法错误, 不算没实现.)
#[test]
fn every_consumable_is_implemented() {
    for kind in ["Tarot", "Planet", "Spectral"] {
        for proto in balatro_engine::data::catalog::Catalog::get().pool(kind) {
            let mut run = aleeb_run();
            run.start();
            run.phase = Phase::SelectingHand;
            run.consumables.push(balatro_engine::run::consumable::Consumable::plain(proto.id.clone()));
            let outcome = run.use_consumable(0, &[]);
            assert!(
                !matches!(outcome, Err(ActionError::NotImplemented(_))),
                "{} 还没实现 (返回 {outcome:?})",
                proto.id
            );
        }
    }
}

/// 星星 / 月亮 / 太阳 / 世界: 把选中的牌改成对应花色, 最多三张, 点数不动.
#[test]
fn suit_conversion_tarots_turn_cards_into_their_suit() {
    // 开局手牌是 C_T, D_T, S_9, S_7, H_6, H_5, H_4, D_2.
    let cases: [(&str, Suit, [&str; 3]); 4] = [
        ("c_world", Suit::Spades, ["S_T", "S_T", "S_6"]),
        ("c_star", Suit::Diamonds, ["D_T", "D_T", "D_6"]),
        ("c_moon", Suit::Clubs, ["C_T", "C_T", "C_6"]),
        ("c_sun", Suit::Hearts, ["H_T", "H_T", "H_6"]),
    ];
    for (key, suit, expected) in cases {
        let mut run = aleeb_run();
        run.start();
        run.consumables.push(balatro_engine::run::consumable::Consumable::plain(key.to_owned()));

        // 改前三张里的第 0, 1, 4 张 (两张 T 与一张 6).
        run.use_consumable(0, &[0, 1, 4]).expect("能用");

        assert_eq!(run.hand[0].card.suit, suit, "{key} 改花色");
        assert_eq!(run.hand[1].card.suit, suit);
        assert_eq!(run.hand[4].card.suit, suit);
        // 没选中的牌不受影响.
        assert_eq!(run.hand[2].card.suit, Suit::Spades);
        assert_eq!(run.hand[5].card.suit, Suit::Hearts);

        let wanted = format!("{},{},S_9,S_7,{},H_5,H_4,D_2", expected[0], expected[1], expected[2]);
        assert_eq!(hand_keys(&run), wanted);
        // 点数一个都没动.
        assert_eq!(run.hand[0].card.rank, Rank::Ten);
        assert_eq!(run.hand[4].card.rank, Rank::Six);
    }
}

/// 倒吊人删掉选中的牌, 而且不补抽, 所以手牌会变少.
#[test]
fn hanged_man_removes_the_chosen_cards_without_drawing() {
    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_hanged_man".to_owned()));

    run.use_consumable(0, &[0, 2]).expect("能用");
    assert_eq!(hand_keys(&run), "D_T,S_7,H_6,H_5,H_4,D_2");
    assert_eq!(run.hand.len(), 6, "删了两张, 不补抽");
    assert_eq!(run.deck.len(), 44, "牌堆没动");
    assert!(run.consumables.is_empty());
}

/// 改花色的那四张上限是三张, 删牌的那张上限是两张.
#[test]
fn tarot_limits_follow_the_prototype() {
    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_world".to_owned()));
    assert_eq!(
        run.use_consumable(0, &[0, 1, 2, 3]),
        Err(ActionError::TooManyCards { limit: 3, got: 4 })
    );

    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_hanged_man".to_owned()));
    assert_eq!(
        run.use_consumable(0, &[0, 1, 2]),
        Err(ActionError::TooManyCards { limit: 2, got: 3 })
    );
}

/// 魔术师, 皇后, 教皇那一批: 把选中的牌换成对应强化.
///
/// 游戏那边是拿新原型调 `set_ability`, 所以是**替换**而不是叠加.
#[test]
fn enhancement_tarots_replace_the_enhancement() {
    // (塔罗, 换成哪种强化, 上限)
    let cases = [
        ("c_magician", Enhancement::Lucky, 2),
        ("c_empress", Enhancement::Mult, 2),
        ("c_heirophant", Enhancement::Bonus, 2),
        ("c_lovers", Enhancement::Wild, 1),
        ("c_chariot", Enhancement::Steel, 1),
        ("c_justice", Enhancement::Glass, 1),
        ("c_devil", Enhancement::Gold, 1),
        ("c_tower", Enhancement::Stone, 1),
    ];

    for (key, want, limit) in cases {
        let mut run = aleeb_run();
        run.start();
        run.consumables.push(balatro_engine::run::consumable::Consumable::plain(key.to_owned()));

        // 正好用满上限.
        run.use_consumable(0, &(0..limit).collect::<Vec<_>>())
            .unwrap_or_else(|err| panic!("{key} 应当能用: {err:?}"));
        for index in 0..limit {
            assert_eq!(run.hand[index].enhancement, Some(want), "{key}");
            // 记号里也会带出来, 与回放 digest 的写法一致.
            assert!(run.hand[index].token().ends_with(want.key()), "{key}");
        }
        // 没选中的牌不受影响.
        assert_eq!(run.hand[limit + 1].enhancement, None, "{key} 不该波及别的牌");
        assert!(run.consumables.is_empty(), "用完就没了");
    }
}

/// 每张各自的上限, 超过要拒.
#[test]
fn enhancement_tarots_respect_their_limits() {
    for (key, limit) in [("c_magician", 2), ("c_lovers", 1), ("c_tower", 1)] {
        let mut run = aleeb_run();
        run.start();
        run.consumables.push(balatro_engine::run::consumable::Consumable::plain(key.to_owned()));
        assert_eq!(
            run.use_consumable(0, &(0..=limit).collect::<Vec<_>>()),
            Err(ActionError::TooManyCards {
                limit,
                got: limit + 1
            }),
            "{key}"
        );
        assert_eq!(run.consumables.len(), 1, "被拒时不消耗牌");
    }
}

/// 死神: 把**最靠右**的那张复制给其余选中的牌, 而且至少要选两张.
///
/// 方向很容易写反 —— 是右边那张盖到左边, 不是反过来. 手牌顺序就是屏幕从左到右,
/// 所以"最靠右"等于下标最大的那张.
#[test]
fn death_copies_the_rightmost_card_onto_the_others() {
    let mut run = aleeb_run();
    run.start();
    // 开局手牌: C_T, D_T, S_9, S_7, H_6, H_5, H_4, D_2.
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_death".to_owned()));

    // 选第 0 张 (C_T) 与第 2 张 (S_9): 右边那张盖过去.
    run.use_consumable(0, &[0, 2]).expect("能用");
    assert_eq!(hand_keys(&run), "S_9,D_T,S_9,S_7,H_6,H_5,H_4,D_2");

    // 连强化也一起复制 (游戏用的是 copy_card). 注意 `hand_keys` 只看牌面,
    // 要看增强得用 `token`.
    let mut run = aleeb_run();
    run.start();
    run.hand[2].set_enhancement(Enhancement::Bonus);
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_death".to_owned()));
    run.use_consumable(0, &[0, 2]).expect("能用");
    assert_eq!(run.hand[0].token(), "S_9~bonus", "复制过去的那张带上同样的强化");
    assert_eq!(run.hand[2].token(), "S_9~bonus");

    // 只选一张不够: 原型的 min_highlighted 是 2.
    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_death".to_owned()));
    assert_eq!(
        run.use_consumable(0, &[0]),
        Err(ActionError::TooFewCards { least: 2, got: 1 })
    );
    assert_eq!(run.consumables.len(), 1, "被拒时不消耗牌");
}

/// 行星牌升对应牌型一级, 而且它**不看选中的牌** —— 所以带 targets 要被拒.
///
/// 升级的效果直接体现在基础值上: `chips = 基础 + 每级增量 * (等级 - 1)`.
#[test]
fn planets_level_up_their_hand_type() {
    let mut run = aleeb_run();
    run.start();
    assert_eq!(run.hands.get(PokerHand::Pair).level, 1, "开局都是 1 级");

    // 水星升的是对子.
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_mercury".to_owned()));
    run.use_consumable(0, &[]).expect("用行星牌");
    assert_eq!(run.hands.get(PokerHand::Pair).level, 2, "对子升一级");
    assert_eq!(run.hands.get(PokerHand::Flush).level, 1, "别的牌型不动");
    assert!(run.consumables.is_empty(), "用完就没了");

    // 升级之后同一手牌的计分会变高.
    let pair = ["C_T", "D_T"].map(card);
    let before = score_play(
        &pair,
        &HandTable::new(),
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [],
    )
    .expect("能识别牌型");
    let after = score_play(
        &pair,
        &run.hands,
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [],
    )
    .expect("能识别牌型");
    assert!(
        after.base_chips > before.base_chips,
        "升级后基础筹码应当变高: {} -> {}",
        before.base_chips,
        after.base_chips
    );
    assert!(
        after.base_mult > before.base_mult,
        "倍率也应当变高: {} -> {}",
        before.base_mult,
        after.base_mult
    );
}

/// 行星牌不该带选中的牌, 带了要拒.
#[test]
fn planets_ignore_targets() {
    // 行星牌不需要目标, 而**多给的目标要忽略而不是报错** —— 游戏那边就是这样:
    // 一整局对拍的记录里, 第 41 步给一张不需要目标的牌传了两个目标, 那个效果照样生效.
    // (原本这里断言的是"报 `TooManyCards`", 那是引擎比游戏更严.)
    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_mercury".to_owned()));
    assert_eq!(run.use_consumable(0, &[0]), Ok(()));
    assert!(run.consumables.is_empty(), "牌用掉了");
    assert_eq!(run.hands.get(PokerHand::Pair).level, 2, "木星把对子升一级 (基础是 1 级)");
}

/// 强化牌在计分时的三份效果: 奖励牌给筹码, 倍率牌给倍率, 玻璃牌乘倍率.
///
/// 玻璃牌那一条要看清**时机**: 它乘的是"当前已经攒起来的倍率", 所以放在哪张牌上,
/// 以及前后还有没有别的倍率来源, 结果都不一样. 这里用同花凑一个固定局面来钉住它.
#[test]
fn enhanced_cards_pay_out_when_scored() {
    use balatro_engine::cards::Enhancement;

    let mut run = aleeb_run();
    run.start();

    // 送一张同花进牌堆: 五张黑桃, 其中一张强化.
    // 走 `CardInstance` 而不是直接设计分视图的字段, 这样"强化 -> 计分"那一环也一起验到.
    let play = |run: &mut balatro_engine::run::RunState, enh: Option<Enhancement>, key: &str| -> f64 {
        let mut hand: Vec<CardInstance> = ["S_2", "S_3", "S_4", "S_5", "S_6"]
            .iter()
            .map(|code| CardInstance::from_key(code).expect("能造出牌"))
            .collect();
        if let Some(e) = enh {
            let target = hand
                .iter_mut()
                .find(|c| c.token().starts_with(key))
                .expect("找得到");
            target.set_enhancement(e);
        }
        let views: Vec<_> = hand.iter().map(CardInstance::to_hand_card).collect();
        score_play(
            &views,
            &run.hands,
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut [],
        )
        .expect("同花能识别")
        .total
    };

    // 什么都不加的基准.
    let plain = play(&mut run, None, "");

    // 奖励牌给 30 筹码.
    let bonus = play(&mut run, Some(Enhancement::Bonus), "S_2");
    assert!(bonus > plain, "奖励牌应当多给筹码: {plain} -> {bonus}");

    // 倍率牌给 4 倍率.
    let mult = play(&mut run, Some(Enhancement::Mult), "S_2");
    assert!(mult > plain, "倍率牌应当多给倍率: {plain} -> {mult}");

    // 玻璃牌乘 2 倍率, 而且因为它作用在"已经攒起来的倍率"上, 收益最大.
    let glass = play(&mut run, Some(Enhancement::Glass), "S_2");
    assert!(
        glass > mult,
        "玻璃牌乘的是当前倍率, 倍数比起加固定值更可观: 倍率牌 {mult} vs 玻璃牌 {glass}"
    );
    assert_eq!(glass, plain * 2.0, "同花倍率乘 2");
}

/// 钢铁牌只在**留在手里**时给乘倍率: 打出去了就不算, 这也正是它要单独一个阶段的原因.
#[test]
fn steel_cards_only_pay_out_while_held() {
    use balatro_engine::cards::Enhancement;
    use balatro_engine::scoring::{HandCard, score_play_with_held};

    let mut run = aleeb_run();
    run.start();

    // 打出一对 5, 手里留一张钢铁 7.
    let played: Vec<HandCard> = ["C_5", "D_5"]
        .iter()
        .map(|code| CardInstance::from_key(code).expect("能造出牌").to_hand_card())
        .collect();
    let mut steel = CardInstance::from_key("H_7").expect("能造出牌");
    steel.set_enhancement(Enhancement::Steel);

    let score = |held: &[HandCard]| -> f64 {
        score_play_with_held(
            &played,
            held,
            &run.hands,
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut [],
        )
        .expect("对子能识别")
        .total
    };

    let without = score(&[]);
    let with_steel = score(&[steel.to_hand_card()]);
    assert!(
        (with_steel - (without * 1.5).floor()).abs() < 0.5,
        "手里那张钢铁牌把倍率乘 1.5: {without} -> {with_steel}"
    );

    // 同一张牌如果被打出去, 走的不是手牌那条路, 所以不该给这份乘倍率.
    // 拿它替换掉一对里的一张 (而不是随便配一张), 否则比的是两种不同的牌型.
    let mut steel_five = CardInstance::from_key("H_5").expect("能造出牌");
    steel_five.set_enhancement(Enhancement::Steel);
    let scored = score_play(
        &[played[0], steel_five.to_hand_card()],
        &run.hands,
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [],
    )
    .expect("对子能识别");
    let plain_played = score_play(
        &played,
        &run.hands,
        &EvalEnv::default(),
        BackEffect::Plain,
        &mut [],
    )
    .expect("对子能识别");
    assert_eq!(scored.hand, plain_played.hand, "两边都该是一对");
    assert_eq!(
        scored.total, plain_played.total,
        "打出去的钢铁牌不该给乘倍率"
    );
}

/// 红封让这张计分牌**多算一遍**: 它自己的筹码与逐卡小丑的效果都重跑一次.
#[test]
fn red_seal_scores_the_card_twice() {
    use balatro_engine::cards::Seal;
    use balatro_engine::jokers::Joker;

    let mut run = aleeb_run();
    run.start();

    let make = |seal: Option<Seal>, key: &str| {
        let mut c = CardInstance::from_key(key).expect("能造出牌");
        c.seal = seal;
        c.to_hand_card()
    };

    // 两张 5 构成一对; 其中一张带红封.
    let plain = [make(None, "C_5"), make(None, "D_5")];
    let sealed = [make(Some(Seal::Red), "C_5"), make(None, "D_5")];

    let score = |cards: &[balatro_engine::scoring::HandCard], jokers: &mut [Joker]| -> f64 {
        score_play(
            cards,
            &run.hands,
            &EvalEnv::default(),
            BackEffect::Plain,
            jokers,
        )
        .expect("对子能识别")
        .total
    };

    let baseline = score(&plain, &mut []);
    let doubled = score(&sealed, &mut []);

    // 一对 5: 基础 10 筹码 2 倍率; 两张 5 各给 5 筹码, 一共 20 筹码.
    // 红封让带封的那张再算一次, 于是多出 5 筹码.
    assert_eq!(baseline, 40.0, "10 + 5 + 5 筹码, 2 倍率");
    assert_eq!(doubled, 50.0, "再多一份 5 筹码: 10 + 5 + 5 + 5");
}

/// 红封会让**逐卡小丑**也跟着重跑 —— 这是"整段重跑"与"只加一次筹码"的分水岭.
#[test]
fn red_seal_also_repeats_per_card_jokers() {
    use balatro_engine::cards::Seal;
    use balatro_engine::jokers::Joker;

    let mut run = aleeb_run();
    run.start();

    // 笑脸对每张人头牌给 +5 倍率, 所以它最容易看出重跑与没重跑的区别.
    let face = |seal: Option<Seal>| {
        let mut c = CardInstance::from_key("C_K").expect("能造出牌");
        c.seal = seal;
        c.to_hand_card()
    };

    let one = |jokers: &mut [Joker], left_seal: Option<Seal>| -> f64 {
        let cards = [face(left_seal), face(None)];
        score_play(
            &cards,
            &run.hands,
            &EvalEnv::default(),
            BackEffect::Plain,
            jokers,
        )
        .expect("对子能识别")
        .mult
    };

    let mut smiley = [Joker::new("j_smiley").expect("有这张")];
    let without = one(&mut smiley, None);
    let with = one(&mut smiley, Some(Seal::Red));
    assert_eq!(without, 2.0 + 10.0, "对子 2 倍率加两张人头各 5");
    assert_eq!(
        with,
        2.0 + 15.0,
        "红封那张的人头效果也要重跑一次: 2 + 5*3"
    );
}

/// 看手牌的小丑: 男爵与射月按手里每张 K / Q 给, 致胜之拳只认点数最小的那张.
///
/// 它们和"打出去的牌"无关, 所以打出的牌型固定不变, 只看手里的牌怎么变 —— 这也让几条断言
/// 能直接落在倍率上.
#[test]
fn held_jokers_look_at_the_cards_left_in_hand() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::scoring::{HandCard, score_play_with_held};

    let mut run = aleeb_run();
    run.start();

    // 固定打出一对 5.
    let played: Vec<HandCard> = ["C_5", "D_5"]
        .iter()
        .map(|code| CardInstance::from_key(code).expect("能造出牌").to_hand_card())
        .collect();

    let with_held = |joker: &str, held: &[&str]| -> f64 {
        let held: Vec<HandCard> = held
            .iter()
            .map(|code| CardInstance::from_key(code).expect("能造出牌").to_hand_card())
            .collect();
        let mut jokers = [Joker::new(joker).expect("有这张")];
        score_play_with_held(
            &played,
            &held,
            &run.hands,
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut jokers,
        )
        .expect("对子能识别")
        .mult
    };

    // 一对 5 的基础倍率是 2.
    assert_eq!(with_held("j_baron", &[]), 2.0, "手里没牌就没有加成");

    // 男爵: 手里一张 K 乘 1.5, 两张乘两次.
    assert_eq!(with_held("j_baron", &["C_K"]), 3.0, "2 x 1.5");
    assert_eq!(with_held("j_baron", &["C_K", "D_K"]), 4.5, "2 x 1.5 x 1.5");
    assert_eq!(with_held("j_baron", &["C_Q"]), 2.0, "Q 不算");
    assert_eq!(with_held("j_baron", &["C_A"]), 2.0, "A 不算");

    // 射月: 手里每张 Q 给 +13 倍率.
    assert_eq!(with_held("j_shoot_the_moon", &["C_Q"]), 15.0, "2 + 13");
    assert_eq!(with_held("j_shoot_the_moon", &["C_Q", "D_Q"]), 28.0, "2 + 26");
    assert_eq!(with_held("j_shoot_the_moon", &["C_K"]), 2.0, "K 不算");

    // 致胜之拳: 只给点数最小的那张, 而且是"两倍点数"的倍率.
    // 手里 3 与 9, 只有 3 触发, 给 2 x 3 = 6.
    assert_eq!(with_held("j_raised_fist", &["C_3", "D_9"]), 8.0, "2 + 6");
    // 换成 8 与 9, 最小是 8, 给 2 x 8 = 16.
    assert_eq!(with_held("j_raised_fist", &["C_8", "D_9"]), 18.0, "2 + 16");
}

/// 回合末的手牌效果: 黄金牌与金封各给三块, 蓝封给一张"最后打出牌型"的行星牌.
///
/// 这三样都算在**结算栏**里 (所以金额出现在 `round_eval` 的总额中), 而不是直接进现金.
#[test]
fn end_of_round_hand_effects_pay_out() {
    use balatro_engine::cards::{Enhancement, Seal};

    let mut run = aleeb_run();
    run.start();

    // 送两张牌进手牌: 一张黄金牌, 一张蓝封牌.
    let mut gold = CardInstance::from_key("C_2").expect("能造出牌");
    gold.set_enhancement(Enhancement::Gold);
    let mut blue = CardInstance::from_key("D_2").expect("能造出牌");
    blue.seal = Some(Seal::Blue);
    run.hand.push(gold);
    run.hand.push(blue);

    // 打出一手, 让"最后打出的牌型"有值.
    let before = run.dollars;
    run.chips = 99_999.0;
    run.play(
        &[0, 1, 2, 3, 4],
        &EvalEnv::default(),
        BackEffect::Plain,
    )
    .expect("能出牌");

    // 打到目标之后 `play` 自己就会走回合收尾, 所以这里不该再调一次 `end_round`.
    let eval = run.round_eval.expect("回合末有结算栏");
    assert_eq!(run.dollars, before + 3.0, "黄金牌奖励在结算界面前到账");
    assert_eq!(eval.card_bonus, 0.0, "黄金牌不重复并入领取奖励");
    assert!(
        run.consumables.iter().any(|card| card.key.starts_with("c_")),
        "蓝封给了一张行星牌: {:?}",
        run.consumables
    );
}

/// 金封与黄金牌是**两条路**: 金封在打出去那一刻给钱, 黄金牌留到回合末算进结算栏.
///
/// 一开始我把两个都放在回合末, 结果"金封留在手里"也会给钱 —— 这条测试就是冲着那个错误写的.
#[test]
fn gold_seal_pays_when_played_not_at_round_end() {
    use balatro_engine::cards::Seal;

    // 情形一: 把带金封的牌打出去, 钱当场到手.
    let mut played = aleeb_run();
    played.start();
    let mut sealed = CardInstance::from_key("C_T").expect("能造出牌");
    sealed.seal = Some(Seal::Gold);
    played.hand[0] = sealed;
    let before = played.dollars;
    played.chips = 99_999.0;
    played.play(&[0, 1, 2, 3, 4], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(played.dollars, before + 3.0, "打出去的金封当场给三块");
    assert_eq!(
        played.round_eval.expect("有结算栏").card_bonus,
        0.0,
        "手里没有黄金牌, 结算栏里不该有牌给的钱"
    );

    // 情形二: 同样一张金封, 但留着不出手, 一分钱都不给.
    let mut held = aleeb_run();
    held.start();
    let mut kept = CardInstance::from_key("C_T").expect("能造出牌");
    kept.seal = Some(Seal::Gold);
    held.hand[0] = kept;
    let before = held.dollars;
    held.chips = 1.0; // 打不满目标, 只出一手就停
    held.play(&[4, 5, 6], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");
    assert_eq!(held.dollars, before, "留着没打出去的金封不给钱");
    assert!(
        held.hand.iter().any(|c| c.seal == Some(Seal::Gold)),
        "那张金封还在手里"
    );
}

/// 紫封在**弃牌时**给一张塔罗, 与回合末那批都不在一处.
#[test]
fn purple_seal_gives_a_tarot_when_discarded() {
    use balatro_engine::cards::Seal;

    let mut run = aleeb_run();
    run.start();
    assert!(run.consumables.is_empty(), "开局消耗槽是空的");

    let mut sealed = CardInstance::from_key("C_T").expect("能造出牌");
    sealed.seal = Some(Seal::Purple);
    run.hand[0] = sealed;
    let discards_before = run.discards_left;

    run.discard(&[0]).expect("弃一张");

    assert_eq!(run.consumables.len(), 1, "弃掉紫封得到一张塔罗");
    assert!(
        run.consumables[0].key.starts_with("c_"),
        "给的是一张塔罗: {:?}",
        run.consumables
    );
    assert_eq!(
        run.discards_left,
        discards_before - 1,
        "弃牌次数照常扣一次"
    );
}

/// 消耗槽满的时候紫封不给牌 —— 对应源码里那个 `card_limit` 判断.
#[test]
fn purple_seal_gives_nothing_when_consumable_slots_are_full() {
    use balatro_engine::cards::Seal;

    let mut run = aleeb_run();
    run.start();
    run.base_consumable_slots = 0;

    let mut sealed = CardInstance::from_key("C_T").expect("能造出牌");
    sealed.seal = Some(Seal::Purple);
    run.hand[0] = sealed;

    run.discard(&[0]).expect("弃一张");
    assert!(run.consumables.is_empty(), "没位置就不给");
}

/// 幸运牌的两份都靠掷骰 (1/5 给 +20 倍率, 1/15 给 20 块).
///
/// 骰子现在由**计分那一层**掷 (逐张参与计分的牌各掷一次, 顺序是倍率在前钱在后),
/// 所以这里不控制"中不中", 而是**先问骰子哪个种子会中**, 再拿那个种子跑一遍 ——
/// 这样验的是真实路径, 而不是一个人为摆出来的布尔值.
#[test]
fn lucky_card_pays_only_when_the_dice_hit() {
    use balatro_engine::cards::Enhancement;
    use balatro_engine::rng::Rng;
    use balatro_engine::scoring::score_play_with_rng;

    let mut run = aleeb_run();
    run.start();

    let lucky = || {
        let mut c = CardInstance::from_key("C_5").expect("能造出牌");
        c.set_enhancement(Enhancement::Lucky);
        c.to_hand_card()
    };

    // 找一个"倍率中、钱没中"的种子, 以及一个"钱中"的种子.
    let find_seed = |want_mult: bool, want_money: bool| -> String {
        (0..500)
            .map(|i| format!("LUCKY{i}"))
            .find(|seed| {
                let mut rng = Rng::new(seed);
                // 顺序与计分里一致: 倍率在前, 钱在后.
                let mult_hit = rng.pseudorandom("lucky_mult") < 0.2;
                let money_hit = rng.pseudorandom("lucky_money") < 1.0 / 15.0;
                mult_hit == want_mult && money_hit == want_money
            })
            .expect("五百个种子里总该有中的")
    };

    let score = |seed: &str| -> (f64, f64) {
        let cards = [lucky(), card("D_5")];
        let mut rng = Rng::new(seed);
        let r = score_play_with_rng(
            &cards,
            &[],
            &run.hands,
            &EvalEnv::default(),
            BackEffect::Plain,
            &mut [],
            &mut rng,
        )
        .expect("对子能识别");
        (r.total, r.dollars)
    };

    // 两次都没中: 与普通的一对 5 没差别.
    let (plain_total, plain_dollars) = score(&find_seed(false, false));
    assert_eq!(plain_total, 40.0, "一对 5: 10 + 5 + 5 筹码, 2 倍率");
    assert_eq!(plain_dollars, 0.0, "没中就不给钱");

    // 只中倍率: 倍率从 2 变成 22, 总分跟着涨.
    let (mult_total, dollars) = score(&find_seed(true, false));
    assert_eq!(mult_total, 20.0 * 22.0, "筹码 20 不变, 倍率 2 + 20");
    assert_eq!(dollars, 0.0);

    // 只中钱: 分不变, 但到手 20 块.
    let (money_total, dollars) = score(&find_seed(false, true));
    assert_eq!(money_total, plain_total, "钱那一份不影响分数");
    assert_eq!(dollars, 20.0);

    // 都中: 两样各给各的.
    let (both_total, dollars) = score(&find_seed(true, true));
    assert_eq!(both_total, 20.0 * 22.0);
    assert_eq!(dollars, 20.0);
}

/// 出牌时幸运牌会在计分前掷两次骰, 所以走整条流程不会崩, 钱也会真的进账.
#[test]
fn lucky_card_rolls_and_pays_through_play() {
    use balatro_engine::cards::Enhancement;

    // 掷骰是随机的, 所以这里只确认"跑得通且金额自洽", 具体命中与否交给上一条测.
    let mut run = aleeb_run();
    run.start();
    let mut lucky = CardInstance::from_key("C_T").expect("能造出牌");
    lucky.set_enhancement(Enhancement::Lucky);
    run.hand[0] = lucky;

    let before = run.dollars;
    run.chips = 1.0;
    let result = run
        .play(&[0, 1], &EvalEnv::default(), BackEffect::Plain)
        .expect("能出牌");

    assert!(
        result.dollars == 0.0 || result.dollars == 20.0,
        "幸运牌只可能给 0 或 20 块, 拿到 {}",
        result.dollars
    );
    assert_eq!(run.dollars, before + result.dollars, "钱按掷骰结果进账");
}

/// 女祭司给两张行星牌, 皇帝给两张塔罗, 审判给一张小丑.
///
/// 这三张是**生成牌**而不是改牌, 所以不看选中的牌; 数量还受消耗槽空位限制.
#[test]
fn tarots_that_grant_more_cards() {
    use balatro_engine::run::RunState;

    // 女祭司: 给两张行星牌, 张数受消耗槽空位限制.
    //
    // **空位要按"这张牌已经走了"算** —— 它正在被用掉, 不占格子. 默认上限是 2,
    // 所以手上是它自己加空位时, 要给得出**两张**. (原本这里写的是"只给得出一张",
    // 那是把原牌也算进占用了 —— 整局对拍的记录里同一张牌给了两张, 才发现的.)
    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_high_priestess".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    assert_eq!(run.consumables.len(), 2, "上限两格, 给得出两张");
    for key in common::consumable_keys(&run) {
        let category = balatro_engine::data::catalog::Catalog::get()
            .record(&key)
            .map(|proto| proto.category.clone())
            .unwrap_or_default();
        assert_eq!(category, "Planet", "{key} 应当是行星牌");
    }

    // 皇帝同理, 只是换成塔罗 (空位按"原牌已走"算, 所以两格就给得出两张).
    let mut run = aleeb_run();
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_emperor".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    assert_eq!(run.consumables.len(), 2, "上限两格, 给得出两张");

    let mut roomy = aleeb_run();
    roomy.start();
    roomy.base_consumable_slots = 3;
    roomy.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_emperor".to_owned()));
    roomy.use_consumable(0, &[]).expect("能用");
    assert_eq!(roomy.consumables.len(), 2, "腾出位置就给两张");
    for key in common::consumable_keys(&run) {
        let category = balatro_engine::data::catalog::Catalog::get()
            .record(&key)
            .map(|proto| proto.category.clone())
            .unwrap_or_default();
        assert_eq!(category, "Tarot", "{key} 应当是塔罗");
    }

    // 审判: 一张小丑, 进持有区而不是消耗槽.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_judgement".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    assert_eq!(run.jokers.len(), 1, "审判给一张小丑");
    assert!(run.consumables.is_empty(), "用掉的那张不留");

    // 槽位不够时少给: 一格就只给一张 (被用掉那张不占格子, 所以那一格是空的).
    let mut run = aleeb_run();
    run.start();
    run.base_consumable_slots = 1;
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_high_priestess".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    assert_eq!(run.consumables.len(), 1, "一格就给一张");
}

/// 幻灵里"加蜡封"的四张: 与塔罗那一批同构, 只是给的封不同.
#[test]
fn spectral_tarots_that_add_seals() {
    use balatro_engine::cards::Seal;

    for (key, want) in [
        ("c_talisman", Seal::Gold),
        ("c_deja_vu", Seal::Red),
        ("c_trance", Seal::Blue),
        ("c_medium", Seal::Purple),
    ] {
        let mut run = aleeb_run();
        run.start();
        run.consumables.push(balatro_engine::run::consumable::Consumable::plain(key.to_owned()));
        run.use_consumable(0, &[3]).expect("能用");
        assert_eq!(run.hand[3].seal, Some(want), "{key} 给的封");
        assert!(run.consumables.is_empty(), "用完就没了");
    }
}

/// 符印把整手牌换成同一个**随机**花色; 占卜把整手牌点数统一, 并且**手牌上限减一**.
///
/// 占卜这一条最容易看错 —— 名字像"点数降一级", 实际是"统一成一个点数".
#[test]
fn sigil_and_ouija_normalize_the_hand() {
    let mut run = aleeb_run();
    run.start();
    let suits_before: std::collections::HashSet<_> =
        run.hand.iter().map(|card| card.card.suit).collect();
    assert!(suits_before.len() > 1, "开局手牌花色应当是杂的");

    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_sigil".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    let suits: std::collections::HashSet<_> =
        run.hand.iter().map(|card| card.card.suit).collect();
    assert_eq!(suits.len(), 1, "符印之后只剩一种花色");

    // 占卜: 点数统一, 手牌上限减一.
    let mut run = aleeb_run();
    run.start();
    let hand_before = run.hand_size();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_ouija".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    let ranks: std::collections::HashSet<_> =
        run.hand.iter().map(|card| card.card.rank).collect();
    assert_eq!(ranks.len(), 1, "占卜之后只剩一种点数");
    assert_eq!(run.hand_size(), hand_before - 1, "手牌上限减一");
}

/// 神秘生物: 复制**第一张**选中的牌若干次, 手牌因此变多.
#[test]
fn cryptid_copies_the_first_selected_card() {
    let mut run = aleeb_run();
    run.start();
    let before = run.hand.len();
    let source = run.hand[2].token();

    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_cryptid".to_owned()));
    run.use_consumable(0, &[2]).expect("能用");

    assert_eq!(run.hand.len(), before + 2, "多出两张");
    let copies = run.hand.iter().filter(|card| card.token() == source).count();
    assert_eq!(copies, 3, "原来那张加两张复制");
}

/// 幻灵里"销毁一张再补新牌"的几张: 销毁的那张是彻底删掉 (不进弃牌堆), 补的牌各有各的点数.
///
/// 所以手牌张数的净变化是"补的张数 - 1", 整副牌也因此少一张.
#[test]
fn spectral_tarots_that_destroy_and_add_cards() {
    use balatro_engine::cards::Rank;
    use balatro_engine::run::RunState;

    let hand_after = |key: &str| -> Vec<balatro_engine::cards::CardInstance> {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        run.consumables.push(balatro_engine::run::consumable::Consumable::plain(key.to_owned()));
        run.use_consumable(0, &[]).expect("能用");
        run.hand.clone()
    };

    // 使魔: 销毁一张, 补三张人头牌 -> 净 +2.
    let hand = hand_after("c_familiar");
    assert_eq!(hand.len(), 10, "八张减一再补三张");
    let faces = hand
        .iter()
        .filter(|card| card.card.rank.is_face())
        .count();
    assert!(faces >= 3, "新补的三张都是人头牌, 实际有 {faces} 张");

    // 严峻: 补两张 A -> 净 +1.
    let hand = hand_after("c_grim");
    assert_eq!(hand.len(), 9, "八张减一再补两张");
    let aces = hand.iter().filter(|card| card.card.rank == Rank::Ace).count();
    assert!(aces >= 2, "新补的两张都是 A, 实际有 {aces} 张");

    // 咒语: 补四张数字牌 -> 净 +3.
    let hand = hand_after("c_incantation");
    assert_eq!(hand.len(), 11, "八张减一再补四张");

    // 这三张幻灵造出来的牌**都带一个随机强化**, 而且石头牌不在池子里.
    // 石头牌不给的理由是它的点数由强化自己顶掉, 参与"人头牌 / 数字牌"这件事就说不通了.
    for key in ["c_familiar", "c_grim", "c_incantation"] {
        let hand = hand_after(key);
        let enhanced = hand.iter().filter(|card| card.enhancement.is_some()).count();
        assert!(enhanced > 0, "{key} 造出来的牌一个强化都没有");
        assert!(
            !hand
                .iter()
                .any(|card| card.enhancement == Some(Enhancement::Stone)),
            "{key} 不该给出石头牌"
        );
    }

    // 火祭: 销毁五张换二十块 (牌不够就有什么删什么).
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    let before = run.dollars;
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_immolate".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    assert_eq!(run.dollars, before + 20.0, "换二十块");
    assert_eq!(run.hand.len(), 3, "八张删掉五张");
}

/// 生命十字章: 随机留一张小丑并**复制**一份, 其余非永恒的全部删掉.
///
/// 被挑中的那张可能是永恒的也可能不是; 永恒的**删不掉**, 所以它们总是留下来.
#[test]
fn ankh_keeps_one_joker_and_duplicates_it() {
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;

    let mut run = RunState::new("ALEEB", 8);
    run.start();
    for key in ["j_joker", "j_jolly", "j_sly"] {
        run.jokers.push(Joker::new(key).expect("有这张"));
    }
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_ankh".to_owned()));
    run.use_consumable(0, &[]).expect("能用");

    // 三个删掉两个, 再补一个复制品 -> 还是两个.
    assert_eq!(run.jokers.len(), 2, "留一张加一份复制");
    assert_eq!(
        run.jokers[0].key, run.jokers[1].key,
        "留下的两张是同一种"
    );
    assert!(
        ["j_joker", "j_jolly", "j_sly"].contains(&run.jokers[0].key.as_str()),
        "而且是原来那三种之一"
    );

    // 永恒的那张删不掉: 把它塞进去, 结果里应当还有它.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.jokers.push(Joker::new("j_joker").expect("有这张"));
    let mut eternal = Joker::new("j_jolly").expect("有这张");
    eternal.eternal = true;
    run.jokers.push(eternal);
    run.jokers.push(Joker::new("j_sly").expect("有这张"));
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_ankh".to_owned()));
    run.use_consumable(0, &[]).expect("能用");

    assert!(
        run.jokers.iter().any(|joker| joker.key == "j_jolly"),
        "永恒的删不掉: {:?}",
        run.jokers.iter().map(|j| &j.key).collect::<Vec<_>>()
    );
}

/// 妖法与灵质: 从"还没有版本"的小丑里挑一个给它加版本.
#[test]
fn hex_and_ectoplasm_add_editions() {
    use balatro_engine::cards::Edition;
    use balatro_engine::jokers::Joker;
    use balatro_engine::run::RunState;

    let run_with = |key: &str| -> RunState {
        let mut run = RunState::new("ALEEB", 8);
        run.start();
        for joker in ["j_joker", "j_jolly", "j_sly"] {
            run.jokers.push(Joker::new(joker).expect("有这张"));
        }
        run.consumables.push(balatro_engine::run::consumable::Consumable::plain(key.to_owned()));
        run.use_consumable(0, &[]).expect("能用");
        run
    };

    // 妖法给多彩.
    let run = run_with("c_hex");
    let editions: Vec<_> = run.jokers.iter().filter_map(|joker| joker.edition).collect();
    assert_eq!(editions, vec![Edition::Polychrome], "妖法给一张加多彩");

    // 灵质给负片.
    let run = run_with("c_ectoplasm");
    let editions: Vec<_> = run.jokers.iter().filter_map(|joker| joker.edition).collect();
    assert_eq!(editions, vec![Edition::Negative], "灵质给一张加负片");

    // 没有可加版本的小丑时不能使用, 拒绝后保留消耗牌.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_hex".to_owned()));
    assert!(run.use_consumable(0, &[]).is_err());
    assert!(run.jokers.is_empty());
    assert_eq!(run.consumables.len(), 1);
}

/// 光环给第一张选中的牌加版本, 而且用的是"必定出"那一档 —— 所以不该空手而归.
///
/// 五十个种子各试一次, 一次都不该落空.
#[test]
fn aura_always_gives_an_edition() {
    use balatro_engine::run::RunState;

    let mut missed = 0;
    for seed in ["ALEEB", "AAAAA", "ZZZZZ", "12345", "7GU9BJP9"] {
        let mut run = RunState::new(seed, 8);
        run.start();
        run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_aura".to_owned()));
        run.use_consumable(0, &[2]).expect("能用");
        if run.hand[2].edition.is_none() {
            missed += 1;
        }
    }
    assert_eq!(missed, 0, "必定出版的档位不该落空");
}

/// 幽灵给一张**稀有**小丑, 灵魂给一张**传奇**小丑, 黑洞给所有牌型各升一级.
#[test]
fn wraith_soul_and_black_hole() {
    use balatro_engine::data::catalog::Catalog;
    use balatro_engine::run::RunState;
    use balatro_engine::scoring::PokerHand;

    // 幽灵: 稀有 (3 级).
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_wraith".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    assert_eq!(run.jokers.len(), 1, "给了一张小丑");
    let rarity = Catalog::get()
        .record(&run.jokers[0].key)
        .and_then(|proto| proto.rarity);
    assert_eq!(rarity, Some(3), "幽灵给的是稀有: {}", run.jokers[0].key);

    // 灵魂: 传奇 (4 级).
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_soul".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    assert_eq!(run.jokers.len(), 1, "给了一张小丑");
    let rarity = Catalog::get()
        .record(&run.jokers[0].key)
        .and_then(|proto| proto.rarity);
    assert_eq!(rarity, Some(4), "灵魂给的是传奇: {}", run.jokers[0].key);

    // 黑洞: 每个牌型各升一级.
    let mut run = RunState::new("ALEEB", 8);
    run.start();
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_black_hole".to_owned()));
    run.use_consumable(0, &[]).expect("能用");
    for hand in PokerHand::BY_PRIORITY {
        assert_eq!(run.hands.get(hand).level, 2, "{hand:?} 该升到 2 级");
    }
}


/// 八张"强化型"塔罗: 用掉之后给选中的牌加上对应强化.
///
/// 这几张原来一张都没实现 —— 按名字分发, 名字不在表里, 于是用掉什么也不会发生.
#[test]
fn enhancement_tarots_actually_enhance() {
    use balatro_engine::cards::Enhancement;

    let improved = |key: &str, targets: &[usize]| -> Vec<Option<Enhancement>> {
        let mut run = aleeb_run();
        run.start();
        common::place_blind(&mut run);
        run.consumables
            .push(balatro_engine::run::consumable::Consumable::plain(key.to_owned()));
        // 用刚推进去的那一张 (这个局开局可能已经有别的消耗牌, 不能写死 0).
        let index = run.consumables.len() - 1;
        run.use_consumable(index, targets).expect("能用");
        run.hand
            .iter()
            .map(|card| card.enhancement)
            .filter(|enhancement| enhancement.is_some())
            .collect()
    };

    // 魔术师: 最多两张变幸运牌.
    let two = improved("c_magician", &[0, 1]);
    assert_eq!(two, vec![Some(Enhancement::Lucky), Some(Enhancement::Lucky)]);

    // 恶魔: 一张变黄金牌.
    let one = improved("c_devil", &[0]);
    assert_eq!(one, vec![Some(Enhancement::Gold)]);

    // 高塔: 一张变石头牌.
    let stone = improved("c_tower", &[0]);
    assert_eq!(stone, vec![Some(Enhancement::Stone)]);
}

/// 占卜师: 每用过一张塔罗涨 1 点倍率, 而且算的是**全局**用量 ——
/// 它进队时会取一次现值, 包括进队之前用掉的.
#[test]
fn fortune_teller_counts_tarots_used() {
    use balatro_engine::jokers::Joker;

    let mut run = aleeb_run();
    run.start();
    common::place_blind(&mut run);

    // 先进队: 此时全局用量是 0.
    run.jokers.push(Joker::new("j_fortune_teller").expect("有这张"));
    assert_eq!(run.tarots_used, 0, "还没用过塔罗");

    // 用一张塔罗: 全局用量 +1, 占卜师也 +1.
    run.consumables
        .push(balatro_engine::run::consumable::Consumable::plain("c_magician".to_owned()));
    let index = run.consumables.len() - 1;
    run.use_consumable(index, &[0]).expect("能用");
    assert_eq!(run.tarots_used, 1, "全局用量 +1");
    assert_eq!(run.jokers[0].mult, 1.0, "占卜师 +1 倍率");

    // 行星牌不算塔罗.
    run.consumables
        .push(balatro_engine::run::consumable::Consumable::plain("c_mercury".to_owned()));
    let index = run.consumables.len() - 1;
    run.use_consumable(index, &[]).expect("能用");
    assert_eq!(run.tarots_used, 1, "行星牌不计入塔罗用量");
    assert_eq!(run.jokers[0].mult, 1.0, "占卜师不涨");
}
