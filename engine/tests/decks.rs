//! 十五副牌组各自的效果.
//!
//! 这些效果全在 `Back:apply_to_run` (`game/back.lua` L174) 里, 逐支对应. 它们**只在开局那一次**
//! 生效, 而且代价极不对等: 漏认一支不会报错, 只会让那一局悄悄少一个效果 —— 绿色牌组少那两笔
//! 余手钱, 或者画师牌组没多那两张手牌 —— 之后只有在算分的时候才以"怎么都对不上"的形式露出来,
//! 而那时离原因已经很远了.
//!
//! 所以这里按**牌组的 config 逐项**验: 原型里写了 `dollars` 就该多那十块钱, 写了 `joker_slot`
//! 就该多那一格. 数值一律从 `catalog.json` 现读, 这样加了新牌组 (或者改数值) 时测试跟着走,
//! 而不是把预期值抄一遍.

use balatro_engine::run::{BlindKind, RunState};
use balatro_engine::scoring::BackEffect;

/// 造一局, 用指定牌组, 走完开局.
fn run_with_deck(deck: &str) -> RunState {
    let mut run = RunState::new("ALEEB", 1).with_deck(deck);
    run.start_run();
    run
}

/// 牌组原型上某个数字字段的值, 缺省为 `None`.
fn config_number(deck: &str, field: &str) -> Option<f64> {
    balatro_engine::data::catalog::Catalog::get()
        .record(deck)
        .and_then(|proto| proto.config.clone())
        .and_then(|config| config.get(field).and_then(|v| v.as_f64()))
}

/// 十五副牌组的 `config` 里每一个数字字段都要在开局状态里看得见.
///
/// 用**基准局**作对照: 同一副牌组之外什么都不变, 所以每一项的差值就该等于 config 里的数.
#[test]
fn every_deck_applies_its_numeric_effects() {
    // 基准: 没有牌组 (空键), 于是它就是"什么都不加"的那一局.
    let base = run_with_deck("");

    for deck in [
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
    ] {
        let run = run_with_deck(deck);
        if let Some(value) = config_number(deck, "hands") {
            assert_eq!(
                run.hands_per_round - base.hands_per_round,
                value as i64,
                "{deck} 每回合出牌次数不对"
            );
        }
        if let Some(value) = config_number(deck, "discards") {
            assert_eq!(
                run.discards_per_round - base.discards_per_round,
                value as i64,
                "{deck} 每回合弃牌次数不对"
            );
        }
        if let Some(value) = config_number(deck, "dollars") {
            assert_eq!(
                run.dollars - base.dollars,
                value,
                "{deck} 起始现金不对"
            );
        }
        if let Some(value) = config_number(deck, "joker_slot") {
            assert_eq!(
                run.joker_slots as i64 - base.joker_slots as i64,
                value as i64,
                "{deck} 小丑槽位不对"
            );
        }
        if let Some(value) = config_number(deck, "consumable_slot") {
            assert_eq!(
                run.consumable_slots as i64 - base.consumable_slots as i64,
                value as i64,
                "{deck} 消耗牌槽位不对"
            );
        }
        if let Some(value) = config_number(deck, "hand_size") {
            assert_eq!(
                run.hand_size_bonus - base.hand_size_bonus,
                value as i64,
                "{deck} 手牌上限不对"
            );
        }
        if let Some(value) = config_number(deck, "spectral_rate") {
            assert_eq!(run.spectral_rate, value, "{deck} 幻灵出现权重不对");
        }
        if let Some(value) = config_number(deck, "extra_hand_bonus") {
            assert_eq!(
                run.money_per_hand, value,
                "{deck} 每剩一次出牌给的钱不对"
            );
        }
        if let Some(value) = config_number(deck, "extra_discard_bonus") {
            assert_eq!(
                run.money_per_discard, value,
                "{deck} 每剩一次弃牌给的钱不对"
            );
        }
        if let Some(value) = config_number(deck, "ante_scaling") {
            assert_eq!(run.ante_scaling, value, "{deck} 盲注目标倍数不对");
        }
    }
}

/// 无面牌组: 整副牌没有 J / Q / K, 于是只有 40 张.
///
/// 这一项要**同时**看张数与内容 —— 只看张数的话, "删掉另外十二张"也能过.
#[test]
fn abandoned_deck_has_no_face_cards() {
    let run = run_with_deck("b_abandoned");
    assert_eq!(run.deck.len(), 40, "无面牌组该是 40 张");
    assert_eq!(run.starting_deck_size, 40, "开局张数要一起对上");
    assert!(
        run.deck.iter().all(|card| !card.card.rank.is_face()),
        "无面牌组里不该有人头牌"
    );

    // 四张 A 与四张 2 都还在 (删的是人头牌, 不是随便十二张).
    for rank in [balatro_engine::cards::Rank::Ace, balatro_engine::cards::Rank::Two] {
        assert_eq!(
            run.deck.iter().filter(|c| c.card.rank == rank).count(),
            4,
            "{rank:?} 该还剩四张"
        );
    }
}

/// 棋盘牌组: 梅花改成黑桃, 方块改成红桃 —— 于是整副牌只剩黑桃与红桃两种花色.
#[test]
fn checkered_deck_keeps_only_two_suits() {
    use balatro_engine::cards::Suit;

    let run = run_with_deck("b_checkered");
    assert_eq!(run.deck.len(), 52, "换花色不该改张数");
    for suit in [Suit::Clubs, Suit::Diamonds] {
        assert!(
            !run.deck.iter().any(|card| card.card.suit == suit),
            "棋盘牌组里不该还有 {suit:?}"
        );
    }
    for suit in [Suit::Spades, Suit::Hearts] {
        assert_eq!(
            run.deck.iter().filter(|card| card.card.suit == suit).count(),
            26,
            "{suit:?} 该有 26 张"
        );
    }
    // 点数分布不动: 每种点数仍然是四张.
    for rank in balatro_engine::cards::Rank::ALL {
        assert_eq!(
            run.deck.iter().filter(|card| card.card.rank == rank).count(),
            4,
            "{rank:?} 该还是四张"
        );
    }
}

/// 错乱牌组: 每一次都重掷点数与花色, 但**张数仍然是 52**, 而且同一张牌面可以重复出现.
///
/// 还有一点容易写错: 排序之后 `sort_id` 要互不相同 —— 它们是从"排序后的名次"来的,
/// 不是从原型的建牌序号来的 (重复抽到的牌面会共用同一个原型, 直接沿用原型的序号就会出现重号).
#[test]
fn erratic_deck_rerolls_every_card_but_keeps_the_count() {
    use std::collections::HashSet;

    let mut saw_duplicate = 0;
    for seed in ["ALEEB", "SEED1", "SEED2", "SEED3", "SEED4"] {
        let mut run = RunState::new(seed, 1).with_deck("b_erratic");
        run.start_run();
        assert_eq!(run.deck.len(), 52, "错乱牌组该还是 52 张");
        let ids: HashSet<u32> = run.deck.iter().map(|card| card.card.sort_id).collect();
        assert_eq!(ids.len(), 52, "建牌序号有重号");
        let faces: HashSet<String> = run.deck.iter().map(|card| card.card.key()).collect();
        if faces.len() < 52 {
            saw_duplicate += 1;
        }
    }
    // 52 次独立均匀抽取恰好全不重复的概率极低, 五个种子里至少有一个该出现重复牌面.
    // 没有这一条, "其实根本没重掷"也能过上面的断言.
    assert!(
        saw_duplicate > 0,
        "五个种子里都没出现重复牌面, 看起来错乱牌组没有真的重掷"
    );
}

/// 魔术牌组: 开局带两张愚者, 外加水晶球 —— 而水晶球的效果是**多一个消耗牌格子**.
///
/// 券那一项要同时验"记下来了"与"效果生效了": 只记不施加的话, 货架权重仍然按没买券的算.
#[test]
fn magic_deck_starts_with_consumables_and_a_voucher() {
    let run = run_with_deck("b_magic");
    assert_eq!(run.consumables.len(), 2, "该带两张消耗牌");
    assert!(
        run.consumables.iter().all(|card| card.key == "c_fool"),
        "带的是愚者"
    );
    assert!(
        run.used_vouchers.contains("v_crystal_ball"),
        "水晶球要记进已兑换的券里"
    );
    // 基准 2 格, 水晶球加一格.
    assert_eq!(run.consumable_slots, 3, "水晶球该多给一个消耗牌格子");
}

/// 字谜牌组: 开局三张券, 效果都要生效 (塔罗与星球权重各变 9.6, 商店多摆一件).
#[test]
fn zodiac_deck_starts_with_three_vouchers() {
    let run = run_with_deck("b_zodiac");
    for key in ["v_tarot_merchant", "v_planet_merchant", "v_overstock_norm"] {
        assert!(run.used_vouchers.contains(key), "缺了 {key}");
    }
    // 这两张券是把权重**设定**成 `4 x extra`, 而 extra 是 9.6/4.
    assert_eq!(run.tarot_rate, 9.6, "塔罗权重不对");
    assert_eq!(run.planet_rate, 9.6, "星球权重不对");
    // 库存过剩多摆一件小丑.
    let base = run_with_deck("");
    assert_eq!(
        run.shop_size_bonus,
        base.shop_size_bonus + 1,
        "库存过剩该让货架多摆一件"
    );
}

/// 绿色牌组没有利息 —— 而且跳过的是**整个利息**, 不只是那个"本金五块"的门槛.
///
/// 利息是回合结算时才算的, 所以直接读字段没有意义: 要走完一整个回合. 目标分数压到 1,
/// 于是随便出一张牌就过, 省得为了凑分去搭一堆小丑.
#[test]
fn green_deck_pays_no_interest() {
    let settle = |deck: &str| -> balatro_engine::run::RoundEval {
        let mut run = run_with_deck(deck);
        run.select_blind();
        run.dollars = 100.0;
        // 一次出牌就过: 目标分数压到 1.
        if let Some(blind) = run.blind.as_mut() {
            blind.chips = 1.0;
        }
        run.play(&[0], &Default::default(), BackEffect::Plain)
            .expect("这一手该打得出去");
        run.round_eval.expect("这一手该把这一回合打完")
    };

    assert_eq!(settle("b_green").interest, 0.0, "绿色牌组不该有利息");
    // 对照组: 同一套操作换成标准牌组就该给利息.
    // 100 块时是 `min(floor(100/5), 25/5) = 5` —— 注意上限那 25 是**本金**上限,
    // 换算成钱是 25/5 x 利率 = 5 块.
    // 没有这一条的话, "利息算式整体坏掉"也能过上面那句断言.
    assert_eq!(settle("").interest, 5.0, "标准牌组该给满利息");
    // 绿色牌组那两笔余钱要还在: 每剩一次弃牌给一块.
    assert!(
        settle("b_green").discard_bonus > 0.0,
        "绿色牌组的弃牌余钱该还在"
    );
}

/// 等离子牌组的盲注目标是别人的两倍 —— 这一项在多份回放里被验证过, 留一条本地测试钉住它.
#[test]
fn plasma_deck_doubles_the_blind_target() {
    let plasma = run_with_deck("b_plasma");
    let plain = run_with_deck("");
    assert_eq!(plasma.ante_scaling, 2.0);
    assert_eq!(plain.ante_scaling, 1.0);

    // 让两个都摆上同一个盲注, 比目标分数.
    let target = |mut run: RunState| -> f64 {
        run.boss_key = None;
        run.blind_on_deck = BlindKind::Small;
        run.select_blind();
        run.blind.as_ref().expect("有盲注").chips
    };
    assert_eq!(target(plasma), target(plain) * 2.0, "等离子该是两倍");
}
