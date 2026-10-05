//! 游戏与 Steamodded 源码确认的消耗牌, 优惠券和复制语义回归.

use balatro_engine::cards::{CardInstance, Edition, Enhancement, Rank, Seal, Suit};
use balatro_engine::jokers::Joker;
use balatro_engine::run::consumable::Consumable;
use balatro_engine::run::RunState;

fn ready(seed: &str) -> RunState {
    let mut run = RunState::new(seed, 1);
    run.start_run();
    run.select_blind().unwrap();
    run
}

fn use_card(run: &mut RunState, key: &str, targets: &[usize]) {
    run.consumables.push(Consumable::plain(key));
    run.use_consumable(run.consumables.len() - 1, targets).unwrap();
}

#[test]
fn rejected_tarot_does_not_change_usage_growth_or_randomness() {
    let mut run = ready("AUDITATOMIC");
    run.add_joker(Joker::new("j_fortune_teller").unwrap());
    run.consumables.push(Consumable::plain("c_strength"));
    let digest = balatro_engine::run::digest(&run);
    let mult = run.jokers[0].mult;
    let mut expected_rng = run.rng.clone();
    assert!(run.use_consumable(0, &[0, 1, 2]).is_err());
    assert_eq!(run.tarots_used, 0);
    assert_eq!(run.jokers[0].mult, mult);
    assert_eq!(balatro_engine::run::digest(&run), digest);
    assert_eq!(run.rng.random(), expected_rng.random());
}

#[test]
fn cash_tarots_and_wraith_obey_nonpositive_cash_rules() {
    let mut run = ready("AUDITMONEY");
    run.dollars = -7.0;
    use_card(&mut run, "c_hermit", &[]);
    assert_eq!(run.dollars, -7.0);
    for cash in [-8.0, 25.0] {
        let mut run = ready("AUDITWRAITH");
        run.dollars = cash;
        use_card(&mut run, "c_wraith", &[]);
        assert_eq!(run.dollars, 0.0);
        assert_eq!(run.jokers.len(), 1);
    }
}

#[test]
fn spectral_usage_does_not_replace_fools_last_tarot_or_planet() {
    let mut run = ready("AUDITFOOL");
    use_card(&mut run, "c_mercury", &[]);
    use_card(&mut run, "c_black_hole", &[]);
    assert_eq!(run.last_tarot_planet.as_deref(), Some("c_mercury"));
    use_card(&mut run, "c_fool", &[]);
    assert_eq!(run.consumables.len(), 1);
    assert_eq!(run.consumables[0].key, "c_mercury");
    assert_eq!(run.last_tarot_planet.as_deref(), Some("c_fool"));
}

#[test]
fn unusable_consumables_are_rejected_without_being_spent() {
    for key in ["c_fool", "c_wheel_of_fortune", "c_hex", "c_ectoplasm", "c_ankh"] {
        let mut run = ready("AUDITELIGIBILITY");
        run.consumables.push(Consumable::plain(key));
        assert!(run.use_consumable(0, &[]).is_err(), "{key}");
        assert_eq!(run.consumables.len(), 1);
    }
    let mut run = ready("AUDITAURA");
    run.hand[0].edition = Some(Edition::Foil);
    run.consumables.push(Consumable::plain("c_aura"));
    assert!(run.use_consumable(0, &[0]).is_err());
    assert_eq!(run.hand[0].edition, Some(Edition::Foil));
    for key in ["c_familiar", "c_grim", "c_incantation", "c_immolate", "c_sigil", "c_ouija"] {
        let mut run = ready("AUDITEMPTYHAND");
        run.hand.truncate(1);
        run.consumables.push(Consumable::plain(key));
        assert!(run.use_consumable(0, &[]).is_err(), "{key}");
        assert_eq!(run.hand.len(), 1);
    }
    for key in ["c_judgement", "c_wraith", "c_soul"] {
        let mut run = ready("AUDITFULLJOKERS");
        for _ in 0..run.joker_capacity() {
            run.add_joker(Joker::new("j_joker").unwrap());
        }
        run.consumables.push(Consumable::plain(key));
        assert!(run.use_consumable(0, &[]).is_err(), "{key}");
        assert_eq!(run.consumables.len(), 1);
    }
}

#[test]
fn sigil_and_ouija_use_steamoddeds_nominal_pools() {
    let suits = [Suit::Spades, Suit::Hearts, Suit::Diamonds, Suit::Clubs];
    let ranks = [Rank::Two, Rank::Three, Rank::Four, Rank::Five, Rank::Six, Rank::Seven,
        Rank::Eight, Rank::Nine, Rank::Ten, Rank::Jack, Rank::Queen, Rank::King, Rank::Ace];
    for seed in ["AUDITPOOL1", "AUDITPOOL2", "AUDITPOOL3"] {
        let mut run = ready(seed);
        let mut reference = run.rng.clone();
        let expected = *reference.pick(&suits, "sigil");
        use_card(&mut run, "c_sigil", &[]);
        assert!(run.hand.iter().all(|card| card.card.suit == expected), "{seed}");
        let mut run = ready(seed);
        let mut reference = run.rng.clone();
        let expected = *reference.pick(&ranks, "ouija");
        let size = run.hand_size();
        use_card(&mut run, "c_ouija", &[]);
        assert!(run.hand.iter().all(|card| card.card.rank == expected), "{seed}");
        assert_eq!(run.hand_size(), size - 1);
    }
}

#[test]
fn summon_spectrals_follow_rank_suit_and_enhancement_rng_order() {
    let suits = [Suit::Spades, Suit::Hearts, Suit::Diamonds, Suit::Clubs];
    let faces = [Rank::Jack, Rank::Queen, Rank::King];
    let numbers = [Rank::Two, Rank::Three, Rank::Four, Rank::Five, Rank::Six,
        Rank::Seven, Rank::Eight, Rank::Nine, Rank::Ten];
    let enhancements = [Enhancement::Bonus, Enhancement::Mult, Enhancement::Wild,
        Enhancement::Glass, Enhancement::Steel, Enhancement::Gold, Enhancement::Lucky];
    for (key, append, count) in [("c_familiar", "familiar_create", 3),
        ("c_grim", "grim_create", 2), ("c_incantation", "incantation_create", 4)] {
        let mut run = ready("AUDITSUMMON");
        let hand_len = run.hand.len();
        let mut reference = run.rng.clone();
        let destroy_seed = reference.pseudoseed("random_destroy");
        let mut destroy_pool = run.hand.clone();
        destroy_pool.sort_by_key(|card| card.card.sort_id);
        let destroyed_id = destroy_pool[reference.pick_index(hand_len, destroy_seed)].card.sort_id;
        let survivors: Vec<_> = run.hand.iter().filter(|card| card.card.sort_id != destroyed_id)
            .map(|card| card.card.sort_id).collect();
        let expected: Vec<_> = (0..count).map(|_| {
            let rank = match key {
                "c_familiar" => *reference.pick(&faces, append),
                "c_grim" => Rank::Ace,
                _ => *reference.pick(&numbers, append),
            };
            let suit = *reference.pick(&suits, append);
            let enhancement = *reference.pick(&enhancements, "spe_card");
            (rank, suit, Some(enhancement))
        }).collect();
        use_card(&mut run, key, &[]);
        assert_eq!(run.hand.len(), hand_len - 1 + count);
        let survivor_ids: Vec<_> = run.hand[..hand_len - 1].iter().map(|card| card.card.sort_id).collect();
        assert_eq!(survivor_ids, survivors, "{key}");
        let actual: Vec<_> = run.hand[hand_len - 1..].iter()
            .map(|card| (card.card.rank, card.card.suit, card.enhancement)).collect();
        assert_eq!(actual, expected, "{key}");
    }
}

#[test]
fn immolate_shuffles_creation_order_without_using_random_destroy() {
    let mut run = ready("AUDITIMMOLATE");
    let mut reference = run.rng.clone();
    let mut shuffled = run.hand.clone();
    shuffled.sort_by_key(|card| card.card.sort_id);
    reference.pseudoshuffle(&mut shuffled, "immolate");
    let victims: Vec<_> = shuffled[..5].iter().map(|card| card.card.sort_id).collect();
    let expected: Vec<_> = run.hand.iter().filter(|card| !victims.contains(&card.card.sort_id))
        .map(|card| card.card.sort_id).collect();
    let cash = run.dollars;
    use_card(&mut run, "c_immolate", &[]);
    let actual: Vec<_> = run.hand.iter().map(|card| card.card.sort_id).collect();
    assert_eq!(actual, expected);
    assert_eq!(run.dollars, cash + 20.0);
    assert_eq!(run.rng.pseudorandom("random_destroy"), reference.pseudorandom("random_destroy"));
}

#[test]
fn ankh_strips_negative_only_from_the_created_copy() {
    let mut run = ready("AUDITANKH");
    let mut joker = Joker::new("j_joker").unwrap();
    joker.edition = Some(Edition::Negative);
    run.add_joker(joker);
    use_card(&mut run, "c_ankh", &[]);
    assert_eq!(run.jokers.len(), 2);
    assert_eq!(run.jokers[0].edition, Some(Edition::Negative));
    assert_eq!(run.jokers[1].edition, None);
}

#[test]
fn copy_onto_keeps_target_identity_and_new_copies_have_zero_original_nominal() {
    let mut target = CardInstance::from_key("C_2").unwrap();
    target.card.sort_id = 17;
    let mut source = CardInstance::from_key("D_A").unwrap();
    source.change_suit(Suit::Hearts);
    source.card.sort_id = 29;
    source.enhancement = Some(Enhancement::Glass);
    source.edition = Some(Edition::Polychrome);
    source.seal = Some(Seal::Red);
    source.perma_bonus = 15.0;
    source.played_this_ante = true;
    target.copy_onto(&source);
    assert_eq!(target.card.sort_id, 17);
    assert_eq!(target.card.original_suit, Suit::Clubs);
    assert_eq!(target.card.suit, Suit::Hearts);
    assert_eq!(target.perma_bonus, 15.0);
    assert_eq!(target.enhancement, source.enhancement);
    assert_eq!(target.seal, source.seal);
    assert_eq!(target.edition, source.edition);
    let copy = source.duplicate(31);
    assert_eq!(copy.card.sort_id, 31);
    assert!(copy.copy_original_suit_zero);
    assert!(copy.played_this_ante);
    assert!(target.played_this_ante);
    assert_eq!(copy.perma_bonus, source.perma_bonus);
    // 数值由 audit_copy.lua 执行补丁树真实函数所得,不靠复制 Rust 算式来生成预期.
    assert!((source.nominal(false) - 114.030_001_999_981_9).abs() < 1e-12);
    assert!((source.nominal(true) - 414.010_000_999_981_9).abs() < 1e-12);
    assert!((target.nominal(false) - 114.030_002_999_989_39).abs() < 1e-12);
    assert!((target.nominal(true) - 414.020_000_999_989_4).abs() < 1e-12);
    assert!((copy.nominal(false) - 114.030_000_999_980_67).abs() < 1e-12);
    assert!((copy.nominal(true) - 414.000_000_999_980_67).abs() < 1e-12);
    assert!(target.nominal(true) > copy.nominal(true));
    source.enhancement = Some(Enhancement::Stone);
    assert!((source.nominal(false) - -186.009_999_000_018_07).abs() < 1e-12);
    assert_eq!(source.nominal(true), source.nominal(false));
}

#[test]
#[ignore = "需要已有 LuaJIT 和 BALATRO_PATCHED_TREE 指定的 Lovely 补丁树"]
fn copy_and_sort_match_live_extracted_lua_functions() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let tree = std::env::var("BALATRO_PATCHED_TREE")
        .unwrap_or_else(|_| ".tmp/engine-audit/modded-tree".to_owned());
    let output = std::process::Command::new("luajit")
        .arg("engine/tests/lua/audit_copy.lua").arg(tree).current_dir(root)
        .output().expect("需要已有 LuaJIT, 不自动安装");
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let text = String::from_utf8(output.stdout).unwrap();
    let mut source = CardInstance::from_key("D_A").unwrap();
    source.change_suit(Suit::Hearts);
    source.card.sort_id = 29;
    let mut target = CardInstance::from_key("C_2").unwrap();
    target.card.sort_id = 17;
    target.copy_onto(&source);
    let duplicate = source.duplicate(31);
    for (name, card) in [("source", source), ("target", target), ("duplicate", duplicate)] {
        let line = text.lines().find(|line| line.starts_with(name)).unwrap();
        let fields: Vec<_> = line.split_whitespace().collect();
        let rank: f64 = fields[2].parse().unwrap();
        let suit: f64 = fields[3].parse().unwrap();
        assert!((card.nominal(false) - rank).abs() < 1e-12, "{name}");
        assert!((card.nominal(true) - suit).abs() < 1e-12, "{name}");
    }
    source.enhancement = Some(Enhancement::Stone);
    let fields: Vec<_> = text.lines().find(|line| line.starts_with("stone")).unwrap()
        .split_whitespace().collect();
    assert!((source.nominal(false) - fields[1].parse::<f64>().unwrap()).abs() < 1e-12);
    assert!((source.nominal(true) - fields[2].parse::<f64>().unwrap()).abs() < 1e-12);
}

#[test]
fn vouchers_change_current_round_counts_as_well_as_defaults() {
    for key in ["v_grabber", "v_nacho_tong", "v_hieroglyph"] {
        let mut run = ready("AUDITVOUCHERS");
        run.hands_left = 2;
        let expected = if key == "v_hieroglyph" { -1 } else { 1 };
        let before = run.hands_per_round;
        balatro_engine::run::voucher::apply(&mut run, key);
        assert_eq!(run.hands_left, 2 + expected);
        assert_eq!(run.hands_per_round, before + expected);
    }
    for key in ["v_wasteful", "v_recyclomancy", "v_petroglyph"] {
        let mut run = ready("AUDITVOUCHERS");
        run.discards_left = 1;
        let expected = if key == "v_petroglyph" { -1 } else { 1 };
        let before = run.discards_per_round;
        balatro_engine::run::voucher::apply(&mut run, key);
        assert_eq!(run.discards_left, 1 + expected);
        assert_eq!(run.discards_per_round, before + expected);
    }
}

#[test]
fn overstock_immediately_refills_the_expanded_shop_without_replacing_survivors() {
    let mut run = ready("AUDITOVERSTOCK");
    run.phase = balatro_engine::run::Phase::Shop;
    let mut shop = balatro_engine::run::shop::Shop::restock(&mut run);
    shop.jokers.truncate(1);
    let survivor = shop.jokers[0].clone();
    let voucher = shop.voucher.clone();
    let packs = shop.packs.clone();
    run.shop = Some(shop);
    let mut reference = run.clone();
    let rates = balatro_engine::run::voucher::rates_of(&reference);
    let expected: Vec<_> = (0..2).map(|_| balatro_engine::run::create_card_for_shop(&mut reference, &rates)).collect();
    balatro_engine::run::voucher::apply(&mut run, "v_overstock_norm");
    let shop = run.shop.unwrap();
    assert_eq!(shop.jokers.len(), 3);
    assert_eq!(shop.jokers[0], survivor);
    assert_eq!(shop.jokers[1..], expected);
    assert_eq!(shop.voucher, voucher);
    assert_eq!(shop.packs, packs);
}

#[test]
fn gift_cards_raise_consumable_sell_value_after_discount_and_edition_cost() {
    let mut run = ready("AUDITGIFTCARD");
    run.add_joker(Joker::new("j_gift").unwrap());
    run.add_joker(Joker::new("j_gift").unwrap());
    run.consumables.push(Consumable::plain("c_hermit"));
    run.chips = run.blind.as_ref().unwrap().chips;
    run.end_round();
    assert_eq!(run.consumables[0].extra_value, 2.0);
    assert_eq!(run.sell_consumable(0).unwrap(), 3.0);

    let mut run = ready("AUDITSELLVALUES");
    let mut card = Consumable::with_edition("c_mercury", Some(Edition::Negative));
    card.extra_value = 2.0;
    run.consumables.push(card);
    run.discount_percent = 50.0;
    assert_eq!(run.sell_consumable(0).unwrap(), 4.0);

    let mut run = ready("AUDITPERKEOGIFT");
    run.phase = balatro_engine::run::Phase::Shop;
    run.add_joker(Joker::new("j_blueprint").unwrap());
    run.add_joker(Joker::new("j_perkeo").unwrap());
    let mut card = Consumable::plain("c_hermit");
    card.extra_value = 4.0;
    run.consumables.push(card);
    run.next_round().unwrap();
    assert_eq!(run.consumables.len(), 3);
    for copy in &run.consumables[1..] {
        assert_eq!(copy.edition, Some(Edition::Negative));
        assert_eq!(copy.extra_value, 4.0);
    }
}

#[test]
fn creator_consumables_from_shop_and_pack_do_not_borrow_the_temporary_held_slot() {
    let mut run = ready("AUDITSOURCECAPACITY");
    run.phase = balatro_engine::run::Phase::Shop;
    run.consumables = vec![Consumable::plain("c_hermit"), Consumable::plain("c_mercury")];
    run.dollars = 100.0;
    run.last_tarot_planet = Some("c_mercury".to_owned());
    for key in ["c_emperor", "c_high_priestess", "c_fool"] {
        let card = balatro_engine::run::shop::ShopCard {
            key: key.to_owned(), edition: None, eternal: false, perishable: false,
            rental: false, couponed: false, enhancement: None, todo: None, cost: 3.0,
        };
        let before = balatro_engine::run::digest(&run);
        assert!(run.buy_and_use(&card).is_err(), "{key}");
        assert_eq!(balatro_engine::run::digest(&run), before);
    }
    // 自己在持有区时则允许满槽使用: 用掉的格子能容纳一张产物.
    run.consumables[0] = Consumable::plain("c_emperor");
    run.use_consumable(0, &[]).unwrap();
    assert_eq!(run.consumables.len(), 2);

    // 卡包里的使用者同样不是已持有牌,不能把临时 emplace 的格子算作释放位置.
    let mut run = ready("AUDITPACKCAPACITY");
    run.consumables = vec![Consumable::plain("c_hermit"), Consumable::plain("c_mercury")];
    run.last_tarot_planet = Some("c_mercury".to_owned());
    let contents = balatro_engine::run::open_pack(&mut run, "p_arcana_normal_1");
    run.phase = balatro_engine::run::Phase::BoosterOpened;
    for key in ["c_emperor", "c_high_priestess", "c_fool"] {
        let mut contents = contents.clone();
        contents[0].key = key.to_owned();
        run.open_pack = Some(balatro_engine::run::shop::OpenPack {
            key: "p_arcana_normal_1".to_owned(), size: contents.len(), choices_left: 1, contents,
        });
        let before = balatro_engine::run::digest(&run);
        assert!(run.take_and_use_from_pack(0, &[]).is_err(), "{key}");
        assert_eq!(balatro_engine::run::digest(&run), before);
        assert_eq!(run.open_pack.as_ref().unwrap().choices_left, 1);
    }
    // 已持有负片的使用者在效果期间冻结容量,生成后负片离场才降容量,允许暂时超槽.
    for key in ["c_emperor", "c_high_priestess", "c_fool"] {
        let mut run = ready("AUDITFROZENCAPACITY");
        run.last_tarot_planet = Some("c_mercury".to_owned());
        run.consumables = vec![Consumable::with_edition(key, Some(Edition::Negative)),
            Consumable::plain("c_hermit"), Consumable::plain("c_mercury")];
        assert_eq!(run.consumable_capacity(), 3);
        run.use_consumable(0, &[]).unwrap();
        assert_eq!(run.consumables.len(), 3, "{key}");
        assert_eq!(run.consumable_capacity(), 2);
    }
}

#[test]
fn consumable_destruction_emits_glass_and_face_removal_contexts() {
    let mut run = ready("AUDITDESTROYCONTEXT");
    run.add_joker(Joker::new("j_caino").unwrap());
    run.add_joker(Joker::new("j_glass").unwrap());
    run.hand[0].change_rank(Rank::King);
    run.hand[0].set_enhancement(Enhancement::Glass);
    let canio = run.jokers[0].caino_xmult;
    let glass = run.jokers[1].x_mult;
    use_card(&mut run, "c_hanged_man", &[0]);
    assert_eq!(run.jokers[0].caino_xmult, canio + 1.0);
    assert_eq!(run.jokers[1].x_mult, glass + 0.75);
}

#[test]
fn consumable_creation_emits_hologram_contexts() {
    let mut run = ready("AUDITCREATECONTEXT");
    run.add_joker(Joker::new("j_hologram").unwrap());
    let hologram = run.jokers[0].x_mult;
    use_card(&mut run, "c_cryptid", &[0]);
    assert_eq!(run.jokers[0].x_mult, hologram + 0.5);
}

#[test]
fn all_fifty_two_consumables_can_execute_with_valid_context() {
    use balatro_engine::data::catalog::Catalog;
    let mut count = 0;
    for kind in ["Tarot", "Planet", "Spectral"] {
        for prototype in Catalog::get().pool(kind) {
            let mut run = ready("AUDITALLCONSUMABLES");
            run.last_tarot_planet = Some("c_mercury".to_owned());
            run.add_joker(Joker::new("j_joker").unwrap());
            run.consumables.push(Consumable::plain(&prototype.id));
            let limit = prototype.config.as_ref().and_then(|config| config.get("max_highlighted"))
                .and_then(|value| value.as_f64());
            let targets = if prototype.id == "c_aura" {
                vec![0]
            } else if limit.is_some() {
                let count = prototype.config.as_ref().and_then(|config| config.get("min_highlighted"))
                    .and_then(|value| value.as_f64()).unwrap_or(1.0) as usize;
                (0..count).collect::<Vec<_>>()
            } else { Vec::new() };
            run.use_consumable(0, &targets).unwrap_or_else(|error| panic!("{}: {error:?}", prototype.id));
            assert!(!run.consumables.iter().any(|card| card.key == prototype.id), "{} 应已用掉", prototype.id);
            count += 1;
        }
    }
    assert_eq!(count, 52);
}
