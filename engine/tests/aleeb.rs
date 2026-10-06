//! 目标点名的第一批验收对象: 种子 ALEEB 的开局发牌与首个商店.
//!
//! # 为什么单独放一个文件
//!
//! 其余逐步对拍都在比"引擎照着录像重放跟不跟得上". 而这里钉的是引擎**从零开始**跑出来的结果:
//! 建堆, 洗牌, 发牌, 以及那一面货架上摆了哪几件 —— 一条链从头发到尾.
//!
//! 期望值来自真游戏产出的 digest (那份 16 步录像的第 1 步与第 4 步), 不是引擎自己算出来再
//! 抄回来的 —— 抄自己等于没验. 所以下面每个数字都能在录像里找到出处.
//!
//! 后面几步 (开白送的包, 第二回合, 第二面货架) 由 `dump_replay` 里那条整体重放覆盖:
//! 它现在连 `money` 一起比, 而那正是以前唯一被整体跳过的一项.

mod common;

use balatro_engine::run::RunState;
use common::{aleeb_uda, hand_keys, place_blind};

/// 造一个 ALEEB 的局面并开局.
///
/// 牌组要用 `with_deck("b_plasma")` 而不是只给倍率: 计分那一层靠 `back_effect()` 认出等离子
/// 才会把筹码与倍率平均, 而等离子牌组的盲注目标是标准的两倍 —— 认不出来的话这一手只得 280 分,
/// 打不过 1200, 于是整条链从第一手就歪了.
fn started_run() -> RunState {
    let mut run = RunState::new("ALEEB", 8)
        .with_deck("b_plasma")
        .with_uda(aleeb_uda());
    run.start_run();
    run
}

/// 开局: 选完小盲注之后手上那八张.
///
/// 出处: 录像 `rec-20261003-222131-ALEEB` 第 1 步的 digest
/// `state=SELECTING_HAND ante=1 round=1 money=4 deck=44 hand=C_T,D_T,S_9,S_7,H_6,H_5,H_4,D_2`.
///
/// 手牌**顺序**也要对: 发牌之后按 `get_nominal` 降序重排过一遍, 排错了出牌与弃牌的下标全错,
/// 而那种错在只比"有哪些牌"的检查里看不出来.
#[test]
fn aleeb_opening_deal_matches_the_game() {
    let mut run = started_run();
    assert_eq!(run.dollars, 4.0, "开局有 4 块钱");
    assert_eq!(run.deck.len(), 52, "等离子牌组不多牌也不少牌");

    place_blind(&mut run);

    assert_eq!(
        hand_keys(&run),
        "C_T,D_T,S_9,S_7,H_6,H_5,H_4,D_2",
        "开局那八张 (含顺序)"
    );
    assert_eq!(run.deck.len(), 44, "牌堆从 52 抽给手上八张之后剩 44");
}

/// 首个商店: 弃一次, 出一次, 打完小盲注之后那一面的内容.
///
/// 出处: 同一份录像第 4 步的 digest
/// `state=SHOP ante=1 round=1 money=7 shop=j_trading!e,j_rocket vouchers=v_magic_trick packs=p_buffoon_normal_1,p_arcana_normal_4`.
///
/// 这一面货架是个综合信号, 它同时压在好几件事上: 池子裁剪, 稀有度那一掷, 版本那一掷,
/// 永恒那一掷 (黄金赌注才开), 以及**券与包的先后** —— 白送的那个小丑包读的是全局随机数的
/// 位置, 而那个位置取决于前面造了几张牌, 次序错了它就从 `_1` 变 `_2`.
#[test]
fn aleeb_first_shop_matches_the_game() {
    let mut run = started_run();
    place_blind(&mut run);

    // 录像里那两步: 先弃掉右半边四张, 再打出手上最左五张.
    run.discard(&[0, 1, 2, 7]).expect("弃得成");
    let env = balatro_engine::scoring::EvalEnv::default();
    let back = run.back_effect();
    run.play(&[0, 1, 2, 3, 4], &env, back).expect("出得成");

    assert_eq!(run.dollars, 4.0, "出牌本身不给钱, 收入全在结算那一步");

    // 第一回合结算: 4 -> 7. 这一项以前被对拍器整体跳过 (旧录像那一栏取的是结算动画中途的值),
    // 现在不再跳过, 所以这里给它一条不依赖旧录像的基线.
    let gained = run.cash_out().expect("结算得成");
    assert_eq!(run.dollars, 7.0, "结算之后 7 块 (录像里 money=7)");
    assert!(gained > 0.0, "这一回合确实进了账");

    let shop = run.shop.as_ref().expect("结算之后进商店");

    let jokers: Vec<String> = shop
        .jokers
        .iter()
        .map(|card| {
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
    assert_eq!(jokers.join(","), "j_trading!e,j_rocket", "货架上的两张小丑");

    assert_eq!(
        shop.vouchers.first().map(|card| card.key.as_str()),
        Some("v_magic_trick"),
        "券那一格"
    );
    assert_eq!(
        shop.packs
            .iter()
            .map(|card| card.key.as_str())
            .collect::<Vec<_>>()
            .join(","),
        "p_buffoon_normal_1,p_arcana_normal_4",
        "两个补充包 (第一个是白送的)"
    );
}
