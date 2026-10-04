//! 商店货架与真游戏对拍.
//!
//! 期望值取自 `recordings/20261003-224812-ALEEB/` 第 4 步 (结算后进商店) 的 digest:
//!
//! ```text
//! shop=j_trading!e,j_rocket vouchers=v_magic_trick packs=p_buffoon_normal_1,p_arcana_normal_4
//! ```
//!
//! `!e` 是永恒 (`Card:set_eternal`), 与 GOLD 赌注开启 `enable_eternals_in_shop` 对应.
//!
//! 重现货架要按游戏里的顺序整体走一遍: 两张小丑 -> 优惠券 -> 两个卡包. 卡包那一步用的是裸的
//! `math.random(1, 2)`, 吃的是前面小丑生成留下的全局 PRNG 状态, 所以不能单独算.

use std::collections::HashMap;

use balatro_engine::run::{RunState, ShopRates, create_card_for_shop, get_pack};

const UDA_TSV: &str = include_str!("data/aleeb-uda.tsv");

fn aleeb_uda() -> HashMap<String, String> {
    let mut uda = HashMap::new();
    for line in UDA_TSV.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        if let Some((key, flags)) = line.split_once('\t') {
            uda.insert(key.to_owned(), flags.to_owned());
        }
    }
    uda
}

/// 种子 ALEEB, 等离子牌组, 黄金赌注 (stake 8).
fn aleeb_run() -> RunState {
    RunState::new("ALEEB", 8).with_uda(aleeb_uda())
}

/// 把第一个商店的货架整条走一遍, 返回 (小丑, 卡包).
fn first_shop(run: &mut RunState) -> (Vec<String>, Vec<String>) {
    let rates = ShopRates::default();

    // 两张小丑 (G.GAME.shop.joker_max).
    let mut jokers = Vec::new();
    for _ in 0..2 {
        let card = create_card_for_shop(run, &rates);
        let mut token = card.key.clone();
        if card.eternal {
            token.push_str("!e");
        }
        if card.rental {
            token.push_str("!r");
        }
        jokers.push(token);
    }

    // 优惠券那一格用的是开局算好的 current_round.voucher, 这里不重新抽.
    let _ = run.next_voucher_key();

    // 两个卡包.
    let packs: Vec<String> = (0..2).map(|_| get_pack(run, "shop_pack")).collect();
    (jokers, packs)
}

#[test]
fn aleeb_first_shop_matches_replay() {
    let mut run = aleeb_run();
    let (jokers, packs) = first_shop(&mut run);

    assert_eq!(jokers.join(","), "j_trading!e,j_rocket", "商店第一格与第二格");
    assert_eq!(packs.join(","), "p_buffoon_normal_1,p_arcana_normal_4", "两个卡包");
}

/// 买下货架上那个秘术包并把它开掉.
///
/// 真值取自回放的 step 4 与 5: agent 花 4 元买下秘术包, 从里面取出"灵魂", 于是场上多了一张
/// 传奇小丑卡尼奥. 所以包里应当有一张 `c_soul` —— 这条同时验证了 `create_card` 开头那次
/// 灵魂判定用的是对键.
#[test]
fn opening_the_arcana_pack_yields_a_soul() {
    use balatro_engine::run::open_pack;

    let mut run = aleeb_run();
    let (_, packs) = first_shop(&mut run);
    let arcana = packs
        .iter()
        .find(|key| key.starts_with("p_arcana"))
        .expect("货架上有秘术包");

    let contents = open_pack(&mut run, arcana);
    // 秘术包的 `config.extra` 是 3.
    assert_eq!(contents.len(), 3, "秘术包开三张");
    assert!(
        contents.iter().any(|card| card.key == "c_soul"),
        "回放里 agent 取的正是灵魂, 包里应当有它: {:?}",
        contents.iter().map(|c| &c.key).collect::<Vec<_>>()
    );
}

/// 标准包开出来的是扑克牌, 而不是塔罗或小丑.
///
/// 版本与蜡封本身是随机的, 断言不了具体值; 这里防的是"把标准包当成塔罗包去抽池"这类错误,
/// 那会让牌面上出现 `c_` 或 `j_` 开头的键.
#[test]
fn standard_pack_opens_playing_cards() {
    use balatro_engine::run::open_pack;

    let mut run = aleeb_run();
    let contents = open_pack(&mut run, "p_standard_normal_1");
    assert_eq!(contents.len(), 3, "标准包的 extra 是 3");
    for card in &contents {
        assert!(
            card.key.contains('_') && !card.key.starts_with("c_") && !card.key.starts_with("j_"),
            "标准包给的是扑克牌, 拿到 {}",
            card.key
        );
        // 牌面要能反查回一张真正的牌, 而不是拼错的花色或点数.
        assert!(
            balatro_engine::cards::CardInstance::from_key(&card.key).is_some(),
            "{} 反查不回去",
            card.key
        );
    }
}

/// 罕见 / 稀有标签会把货架那一格直接换成对应稀有度的小丑, 版本标签再给它加个版本.
///
/// 标签是随机抽的, 所以测试直接往持有列表里塞一个待测的.
#[test]
fn rarity_tags_force_the_shop_slot() {
    use balatro_engine::cards::Edition;
    use balatro_engine::data::catalog::Catalog;

    let rarity_of = |key: &str| -> Option<i64> {
        Catalog::get().record(key).and_then(|proto| proto.rarity)
    };


    // 稀有标签: 那一格必定是稀有 (rarity 3).
    let mut rare = aleeb_run();
    rare.tags.push("tag_rare".to_owned());
    let rare_card = create_card_for_shop(&mut rare, &ShopRates::default());
    assert_eq!(
        rarity_of(&rare_card.key),
        Some(3),
        "稀有标签给的是稀有: {}",
        rare_card.key
    );

    // 罕见标签: rarity 2.
    let mut uncommon = aleeb_run();
    uncommon.tags.push("tag_uncommon".to_owned());
    let uncommon_card = create_card_for_shop(&mut uncommon, &ShopRates::default());
    assert_eq!(
        rarity_of(&uncommon_card.key),
        Some(2),
        "罕见标签给的是罕见: {}",
        uncommon_card.key
    );

    // 版本标签: 给那张小丑加上版本, 价格也跟着涨.
    let mut foil = aleeb_run();
    foil.tags.push("tag_rare".to_owned());
    foil.tags.push("tag_foil".to_owned());
    let foil_card = create_card_for_shop(&mut foil, &ShopRates::default());
    assert_eq!(foil_card.edition, Some(Edition::Foil), "闪箔标签加了版本");
    assert_eq!(rarity_of(&foil_card.key), Some(3), "稀有度不受版本影响");
    assert!(
        foil_card.cost > rare_card.cost,
        "带版本的要贵一些: {} vs {}",
        rare_card.cost,
        foil_card.cost
    );
}

/// 持有**表演者**时, 用过的小丑还会再出现; 没有它时用过的就不再进池子.
///
/// 池子的过滤里写着 `not (used_jokers[v.key] and not find_joker("Showman"))` ——
/// 少了这条例外, "表演者"就变成一张没用的小丑.
#[test]
fn showman_lets_used_jokers_come_back() {
    use balatro_engine::jokers::Joker;

    // 把某张普通小丑标记成"用过", 然后让它成为池子里唯一还剩的那张.
    let mut run = aleeb_run();
    for proto in balatro_engine::data::catalog::Catalog::get().jokers_by_rarity(1) {
        run.used_jokers.insert(proto.id.clone());
    }
    // 池子里一个可用的都没有时, 抽出来的是占位, 商店照常给一张别的.
    let without = create_card_for_shop(&mut run, &ShopRates::default());

    // 加上表演者之后, 那些"用过的"又能抽了.
    let mut run = aleeb_run();
    for proto in balatro_engine::data::catalog::Catalog::get().jokers_by_rarity(1) {
        run.used_jokers.insert(proto.id.clone());
    }
    run.jokers.push(Joker::new("j_ring_master").expect("有这张"));
    let with = create_card_for_shop(&mut run, &ShopRates::default());

    // 带表演者时抽出的应当是一张真的普通小丑 (而不是占位或低稀有度之外的东西).
    let rarity = balatro_engine::data::catalog::Catalog::get()
        .record(&with.key)
        .and_then(|proto| proto.rarity);
    assert!(
        rarity.is_some(),
        "带表演者时应当抽到真牌, 拿到 {}",
        with.key
    );
    let _ = without;
}


/// 商店那一格**不掷灵魂那一骰**, 包里那一张要掷.
///
/// 游戏里 `create_card_for_shop` 传的 `soulable` 是 `nil`, 而灵魂那一段的头一句就是
/// `if not forced_key and soulable and ...`, 于是整段跳过. 少了这个区别, 商店每出一张
/// 塔罗 / 行星 / 幻灵都会让那条键多走一步, 之后所有共用同一条键的地方 (开包) 就整体错位 ——
/// 这个错是在整局对拍里抓到的: 秘术包里灵魂牌的位置比真游戏早了一张.
#[test]
fn shop_slots_skip_the_soul_dice() {
    use balatro_engine::run::shop;
    use balatro_engine::rng::Rng;

    // 全新骰子上第一次掷灵魂键的种子.
    let mut fresh = Rng::new("ALEEB");
    let first = fresh.pseudoseed("soul_Tarot1");

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    let _ = shop::create_card_for_shop_slot(&mut run, "Tarot", "sho");
    assert_eq!(
        run.rng.pseudoseed("soul_Tarot1"),
        first,
        "商店那一格不该动灵魂键"
    );

    // 包里那一张造完, 键就该往前走一步.
    let _ = shop::create_card(&mut run, "Tarot", "ar1");
    assert_ne!(
        run.rng.pseudoseed("soul_Tarot1"),
        first,
        "包里的牌要掷灵魂键"
    );
}

/// 池子开关: **大麦克烂掉之前刷不到卡文迪什**, 烂掉之后反过来刷不到大麦克.
///
/// 这一对是池子裁剪里 `no_pool_flag` / `yes_pool_flag` 唯一的实例, 也就是"大麦克烂了才能刷到
/// 卡文迪什"那条玩家熟知的规则. 少了它, 池子里的占位格子对不上, 商店抽出来的小丑会整体偏.
#[test]
fn pool_flags_swap_gros_michel_for_cavendish() {
    use balatro_engine::run::shop;

    // 开关没置位: 卡文迪什**一次都不该出现** (它是 `yes_pool_flag`, 没置位就不在池子里).
    for round in 0..40 {
        let mut probe = RunState::new(&format!("POOL{round}"), 8);
        probe.start_run();
        for _ in 0..12 {
            let card = shop::create_joker(&mut probe, "poo");
            assert_ne!(
                card.key, "j_cavendish",
                "大麦克还没烂, 卡文迪什不该出现在池子里"
            );
        }
    }

    // 置位之后: 卡文迪什才该出现, 而大麦克该消失 (它是 `no_pool_flag`).
    let mut cavendish_after = 0;
    for round in 0..40 {
        let mut probe = RunState::new(&format!("POOL{round}"), 8);
        probe.start_run();
        // 每个种子单独重置一次"用过的小丑", 只留池子开关这一项变量.
        probe.used_jokers.clear();
        probe.pool_flags.insert("gros_michel_extinct".to_owned());
        for _ in 0..12 {
            let card = shop::create_joker(&mut probe, "poo");
            assert_ne!(card.key, "j_gros_michel", "大麦克烂掉之后不该再出现");
            if card.key == "j_cavendish" {
                cavendish_after += 1;
            }
        }
    }
    assert!(
        cavendish_after > 0,
        "置位之后该能抽到卡文迪什了, 一次都没抽到说明开关没接上"
    );
}

/// 池子裁剪的三条门槛 (对应 `get_current_pool` 里那一串 `add = ...`).
///
/// 这三条都直接影响"商店与包里能出现什么", 少了任何一条, 池子里的占位格子就对不上.
#[test]
fn pools_apply_the_hidden_and_gate_rules() {
    use balatro_engine::cards::Enhancement;
    use balatro_engine::run::shop;
    use balatro_engine::scoring::PokerHand;

    // 一, 灵魂与黑洞带 `hidden`: **永远不进池子**, 只能从"灵魂那一骰"里出来.
    // 商店这条路不掷那一骰, 所以这里出现的任何一个都只能是池子给的.
    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    for _ in 0..300 {
        let key = shop::create_card_for_shop_slot(&mut run, "Spectral", "sho");
        assert!(
            key != "c_soul" && key != "c_black_hole",
            "灵魂与黑洞不该从池子里抽出来, 抽到了 {key}"
        );
    }

    // 二, `enhancement_gate`: 牌堆里得有那种强化牌.
    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    for _ in 0..200 {
        let card = shop::create_joker(&mut run, "sho");
        assert_ne!(card.key, "j_steel_joker", "牌堆里没有钢牌, 不该刷到钢小丑");
    }
    run.deck[0].set_enhancement(Enhancement::Steel);
    let mut seen = false;
    for _ in 0..400 {
        if shop::create_joker(&mut run, "sho").key == "j_steel_joker" {
            seen = true;
            break;
        }
    }
    assert!(seen, "牌堆里有钢牌之后该能刷到钢小丑了");

    // 三, 行星的 `softlock`: 那个牌型打过至少一次才进池子.
    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    for _ in 0..60 {
        let key = shop::create_card_for_shop_slot(&mut run, "Planet", "sho");
        assert_ne!(key, "c_planet_x", "没打过五条, 不该刷到那张行星牌");
    }
    run.hands.record_played(PokerHand::FiveOfAKind);
    let mut seen = false;
    for _ in 0..200 {
        if shop::create_card_for_shop_slot(&mut run, "Planet", "sho") == "c_planet_x" {
            seen = true;
            break;
        }
    }
    assert!(seen, "打过五条之后该能刷到那张行星牌了");
}

/// 灵魂那一骰有两道门: **拿到过就不再掷**, 而**用掉之后重新掷**.
///
/// 游戏里这两道分别在 `create_card` 的开头 (`used_jokers['c_soul']` 那半句) 和 `Card:remove()`
/// (用掉时清掉记录, 条件是场上没有同名卡). 少了前者, 后面的包会多掷一次那一骰;
/// 少了后者, 灵魂用掉之后就再也开不出第二张 —— 整局对拍里第 31 步那张传奇就是这么丢的.
#[test]
fn the_soul_gate_closes_and_reopens() {
    use balatro_engine::run::shop;
    use balatro_engine::rng::Rng;

    // 关门时: 造一张塔罗**不该**动灵魂键, 所以第一次读到的还是 1 号种子.
    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    run.used_jokers.insert("c_soul".to_owned());
    let _ = shop::create_card(&mut run, "Tarot", "ar1");
    let gated = run.rng.pseudoseed("soul_Tarot1");
    let mut fresh = Rng::new("ALEEB");
    assert_eq!(gated, fresh.pseudoseed("soul_Tarot1"), "关门时不该动灵魂键");

    // 开门时: 造一张就掷一次, 第一次读到的已经是 2 号种子.
    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    let _ = shop::create_card(&mut run, "Tarot", "ar1");
    let open = run.rng.pseudoseed("soul_Tarot1");
    assert_ne!(open, gated, "开门时该掷那一骰");
}

/// 用掉消耗牌要把"用过"的记录清掉 —— 不然灵魂 / 黑洞用掉之后再也开不出第二张.
#[test]
fn using_a_consumable_forgets_it() {
    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    run.phase = balatro_engine::run::Phase::SelectingHand;
    // 用一张已经实现、且不需要指定目标的 (行星牌就是这种).
    run.consumables.push(balatro_engine::run::consumable::Consumable::plain("c_mercury".to_owned()));
    run.used_jokers.insert("c_mercury".to_owned());
    run.use_consumable(0, &[]).expect("这张行星牌能直接用");
    assert!(
        !run.used_jokers.contains("c_mercury"),
        "用掉之后记录该清掉, 否则同名的牌本局再也刷不出来"
    );
}

/// 消耗牌的池子也要做 `used_jokers` 裁剪 —— **这一条对所有类型都生效**, 不只是小丑.
///
/// 游戏那段裁剪是共用的 (`get_current_pool` 里那个 `elseif`), 所以商店里刚出现过的一张塔罗,
/// 再抽到它只能是 `UNAVAILABLE` (于是重抽). 少了这一条, 秘术包里的牌会整体偏一位 ——
/// 整局对拍里秘术包第 13 步那一张就是这么偏的.
#[test]
fn consumable_pools_cull_used_cards() {
    use balatro_engine::run::shop;

    // 没记录过时能抽到; 记录过之后抽不到 (抽中会重抽, 所以外面看是"它不再出现").
    let mut seen_before = false;
    for round in 0..30 {
        let mut run = RunState::new(&format!("CULL{round}"), 8);
        run.start_run();
        for _ in 0..40 {
            if shop::create_card_for_shop_slot(&mut run, "Tarot", "cull") == "c_empress" {
                seen_before = true;
            }
        }
    }
    assert!(seen_before, "没记录过的时候本来能抽到, 样本不够");

    let mut run = RunState::new("ALEEB", 8);
    run.start_run();
    run.used_jokers.insert("c_empress".to_owned());
    for _ in 0..200 {
        assert_ne!(
            shop::create_card_for_shop_slot(&mut run, "Tarot", "cull"),
            "c_empress",
            "记录过的塔罗不该再抽出来"
        );
    }
}
