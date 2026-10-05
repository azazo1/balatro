//! 小丑本体审计的关键回归, 期望来自实际游戏源码和 Steamodded 补丁.
mod common;

use balatro_engine::cards::{CardInstance, Enhancement, Suit};
use balatro_engine::data::json::Json;
use balatro_engine::jokers::{Joker, TriggerContext};
use balatro_engine::rng::Rng;
use balatro_engine::scoring::{BackEffect, EvalEnv, HandCard, HandTable, PokerHand, evaluate_poker_hand, score_play, score_play_with_held};
use common::card;

fn ctx<'a>(cards: &'a [HandCard], hands: &'a balatro_engine::scoring::EvaluatedHand, table: &'a HandTable) -> TriggerContext<'a> {
    TriggerContext {
        hand: hands.top().unwrap_or(PokerHand::HighCard), hands, cards, scoring: cards, held: &[],
        full_hand_len: cards.len(), played_this_round: 0, ancient_suit: None, idol_card: None,
        pareidolia: false, probability_extra: 0.0, consumable_room: 2, discards_left: 3,
        dollars: 10.0, joker_count: 1, joker_capacity: 5, stencil_count: 0, hands_left: 3,
        deck_len: 30, deck_total: 52, deck_stones: 0, deck_enhanced: 0, deck_steels: 0,
        smeared: false, starting_deck_size: 52, deck_nines: 4, planets_used: 0,
        discards_used: 0, boss_triggered: false, table,
    }
}

#[test]
fn stone_cards_have_neither_rank_suit_nor_faces_without_pareidolia() {
    let mut stone = card("H_K");
    stone.stone = true;
    stone.bonus = 50.0;
    let cards = [stone];
    let table = HandTable::new();
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let mut context = ctx(&cards, &hands, &table);
    let mut rng = Rng::new("STONE-AUDIT");
    assert!(!context.is_face(&stone));
    for key in ["j_triboulet", "j_smiley", "j_scary_face", "j_lusty_joker", "j_ancient", "j_idol"] {
        assert!(Joker::new(key).unwrap().individual(&stone, &context, &mut rng).is_none(), "{key}");
    }
    for key in ["j_fibonacci", "j_even_steven", "j_odd_todd", "j_scholar", "j_walkie_talkie", "j_8_ball"] {
        let mut low = stone;
        low.card.rank = balatro_engine::cards::Rank::Two;
        assert!(Joker::new(key).unwrap().individual(&low, &context, &mut rng).is_none(), "{key}");
    }
    assert_eq!(Joker::new("j_hack").unwrap().retrigger(&stone, &context), 0);
    context.pareidolia = true;
    assert!(context.is_face(&stone));
    assert!(Joker::new("j_smiley").unwrap().individual(&stone, &context, &mut rng).is_some());
}

#[test]
fn wild_and_smeared_use_effect_suits_without_giving_stones_suits() {
    let mut wild = card("C_7");
    wild.wild = true;
    let cards = [wild];
    let table = HandTable::new();
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let mut context = ctx(&cards, &hands, &table);
    let mut rng = Rng::new("SUIT-AUDIT");
    for key in ["j_greedy_joker", "j_lusty_joker", "j_wrathful_joker", "j_gluttenous_joker", "j_rough_gem", "j_onyx_agate", "j_arrowhead"] {
        assert!(Joker::new(key).unwrap().individual(&wild, &context, &mut rng).is_some(), "{key}");
    }
    context.smeared = true;
    assert!(Joker::new("j_arrowhead").unwrap().individual(&card("C_7"), &context, &mut rng).is_some());
    context.ancient_suit = Some(Suit::Spades);
    assert!(Joker::new("j_ancient").unwrap().individual(&wild, &context, &mut rng).is_some());
    context.idol_card = Some((Suit::Hearts, balatro_engine::cards::Rank::Seven));
    assert!(Joker::new("j_idol").unwrap().individual(&wild, &context, &mut rng).is_some());
    wild.stone = true;
    assert!(!context.is_suit(&wild, Suit::Hearts, true));
}

#[test]
fn flower_pot_assigns_one_suit_per_card_and_fills_wild_gaps() {
    let mut cards = [card("H_7"), card("D_7"), card("S_7"), card("H_7")];
    cards[3].wild = true;
    let table = HandTable::new();
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let mut context = ctx(&cards, &hands, &table);
    let joker = Joker::new("j_flower_pot").unwrap();
    let mut rng = Rng::new("FLOWER-AUDIT");
    assert_eq!(joker.joker_main(&context, &mut rng).unwrap().xmult_mod, 3.0);
    cards[3].debuffed = true;
    context = ctx(&cards, &hands, &table);
    assert!(joker.joker_main(&context, &mut rng).is_none());
    let mut smeared = [card("H_7"), card("H_8"), card("S_7"), card("S_8")];
    smeared[0].debuffed = true;
    context = ctx(&smeared, &hands, &table);
    context.smeared = true;
    assert_eq!(joker.joker_main(&context, &mut rng).unwrap().xmult_mod, 3.0);
}

#[test]
fn blackboard_and_seeing_double_respect_wild_stone_and_debuff_suits() {
    let table = HandTable::new();
    let cards = [card("H_A")];
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let mut context = ctx(&cards, &hands, &table);
    let mut wild = card("H_4"); wild.wild = true;
    let held = [wild]; context.held = &held;
    let mut rng = Rng::new("BLACK-AUDIT");
    assert!(Joker::new("j_blackboard").unwrap().joker_main(&context, &mut rng).is_some());
    let mut stone = card("S_4"); stone.stone = true;
    let held = [stone]; context.held = &held;
    assert!(Joker::new("j_blackboard").unwrap().joker_main(&context, &mut rng).is_none());
    let single = [wild]; context.scoring = &single;
    assert!(Joker::new("j_seeing_double").unwrap().joker_main(&context, &mut rng).is_none());
    let double = [wild, wild]; context.scoring = &double;
    assert!(Joker::new("j_seeing_double").unwrap().joker_main(&context, &mut rng).is_some());
    let one_black = [card("S_4")]; context.scoring = &one_black; context.smeared = true;
    assert!(Joker::new("j_seeing_double").unwrap().joker_main(&context, &mut rng).is_some());
}

#[test]
fn raised_fist_selects_the_rightmost_minimum_even_when_it_is_debuffed() {
    let cards = [card("C_A")];
    let held = [card("C_2"), card("D_2"), card("H_K")];
    let table = HandTable::new();
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let context = ctx(&cards, &hands, &table);
    let fist = Joker::new("j_raised_fist").unwrap();
    let mut rng = Rng::new("FIST-AUDIT");
    assert!(fist.held(&held[0], &held, &context, &mut rng).is_none());
    assert_eq!(fist.held(&held[1], &held, &context, &mut rng).unwrap().mult_mod, 4.0);
    let mut weakened = held; weakened[1].debuffed = true;
    assert!(fist.held(&weakened[0], &weakened, &context, &mut rng).is_none());
    assert!(fist.held(&weakened[1], &weakened, &context, &mut rng).is_none());
}

#[test]
fn discard_growth_is_per_card_and_never_goes_negative_or_grows_while_debuffed() {
    let mut green = Joker::new("j_green_joker").unwrap();
    green.on_discard(&[], None, false);
    assert_eq!(green.mult, 0.0);
    green.mult = 2.0;
    green.debuffed = true;
    green.on_discard(&[], None, false);
    assert_eq!(green.mult, 2.0);
    let mut wild = CardInstance::from_key("H_3").unwrap(); wild.set_enhancement(Enhancement::Wild);
    let mut stone = CardInstance::from_key("S_2").unwrap(); stone.set_enhancement(Enhancement::Stone);
    let mut weak = CardInstance::from_key("S_4").unwrap(); weak.debuffed = true;
    let cards = [CardInstance::from_key("S_5").unwrap(), CardInstance::from_key("C_6").unwrap(), wild, stone, weak];
    let mut castle = Joker::new("j_castle").unwrap();
    castle.on_discard_with_suits(&cards, Some(Suit::Spades), false, true);
    assert_eq!(castle.chips, 9.0);
    castle.debuffed = true;
    castle.on_discard_with_suits(&cards, Some(Suit::Spades), false, true);
    assert_eq!(castle.chips, 9.0);
}

#[test]
fn ride_the_bus_ignores_faces_that_do_not_score() {
    let cards = [card("C_K"), card("C_2"), card("D_2")];
    let table = HandTable::new();
    let mut jokers = [Joker::new("j_ride_the_bus").unwrap()];
    let result = score_play(&cards, &table, &EvalEnv::default(), BackEffect::Plain, &mut jokers).unwrap();
    assert_eq!(jokers[0].mult, 1.0);
    assert_eq!(result.mult, 3.0);
}

#[test]
fn wee_growth_applies_in_the_same_hand_and_for_each_retrigger() {
    let mut two = card("H_2"); two.repetitions = 2;
    let mut jokers = [Joker::new("j_wee").unwrap()];
    let result = score_play(&[two], &HandTable::new(), &EvalEnv::default(), BackEffect::Plain, &mut jokers).unwrap();
    assert_eq!(jokers[0].chips, 16.0);
    assert_eq!(result.chips, 25.0);
}

#[test]
fn steel_joker_uses_a_single_whole_deck_multiplier_not_held_card_powers() {
    let env = EvalEnv { deck_steels: 3, ..EvalEnv::default() };
    let result = score_play(&[card("H_A")], &HandTable::new(), &env, BackEffect::Plain, &mut [Joker::new("j_steel_joker").unwrap()]).unwrap();
    assert!((result.mult - 1.6).abs() < 1e-10);
}

#[test]
fn mime_repeats_other_held_joker_effects_not_just_steel() {
    let result = score_play_with_held(&[card("H_A")], &[card("H_Q")], &HandTable::new(), &EvalEnv::default(), BackEffect::Plain,
        &mut [Joker::new("j_mime").unwrap(), Joker::new("j_shoot_the_moon").unwrap()]).unwrap();
    assert_eq!(result.mult, 27.0);
}

#[test]
fn identical_card_values_do_not_share_first_card_identity() {
    let king = card("H_K");
    let cards = [king, king];
    let result = score_play(&cards, &HandTable::new(), &EvalEnv::default(), BackEffect::Plain,
        &mut [Joker::new("j_hanging_chad").unwrap(), Joker::new("j_photograph").unwrap()]).unwrap();
    // 第一张 K 算三次, 第二张只算一次, 照片只在第一张的三次触发.
    assert_eq!(result.chips, 50.0);
    assert_eq!(result.mult, 16.0);
    let held = [card("C_2"), card("C_2")];
    let table = HandTable::new();
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let context = ctx(&cards, &hands, &table);
    let fist = Joker::new("j_raised_fist").unwrap();
    let mut rng = Rng::new("CLONE-AUDIT");
    assert!(fist.held(&held[0], &held, &context, &mut rng).is_none());
    assert_eq!(fist.held(&held[1], &held, &context, &mut rng).unwrap().mult_mod, 4.0);
}

#[test]
fn debuff_stops_round_growth_and_cavendish_has_a_destruction_roll() {
    let mut rng = Rng::new("ROUND-AUDIT");
    for key in ["j_egg", "j_invisible", "j_turtle_bean", "j_hit_the_road", "j_popcorn", "j_gros_michel", "j_cavendish"] {
        let mut joker = Joker::new(key).unwrap(); joker.debuffed = true; joker.x_mult = 3.0;
        let before = (joker.extra_value, joker.invis_rounds, joker.extra, joker.x_mult, joker.mult);
        assert!(!joker.end_of_round_effect(&mut rng, 10000.0));
        assert_eq!((joker.extra_value, joker.invis_rounds, joker.extra, joker.x_mult, joker.mult), before, "{key}");
    }
    let mut cavendish = Joker::new("j_cavendish").unwrap();
    assert!(cavendish.end_of_round_effect(&mut rng, 10000.0));
}

#[test]
fn matador_main_pays_only_for_the_actual_triggered_flag_and_active_joker() {
    let cards = [card("H_A")];
    let table = HandTable::new();
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let mut context = ctx(&cards, &hands, &table);
    let mut matador = Joker::new("j_matador").unwrap();
    let mut rng = Rng::new("MATADOR-AUDIT");
    assert!(matador.joker_main(&context, &mut rng).is_none());
    context.boss_triggered = true;
    let effect = matador.joker_main(&context, &mut rng).unwrap();
    assert_eq!(effect.dollars, 8.0);
    assert!(!effect.is_empty());
    // 使用当前配置值, 而非主调度写死的金额或只处理一次 any.
    matador.extra = 9.0;
    assert_eq!(matador.joker_main(&context, &mut rng).unwrap().dollars, 9.0);
    matador.debuffed = true;
    assert!(matador.joker_main(&context, &mut rng).is_none());
}

#[test]
fn rocket_boss_growth_uses_config_and_stops_while_debuffed() {
    let cards = [card("H_A")];
    let table = HandTable::new();
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let context = ctx(&cards, &hands, &table);
    let mut rocket = Joker::new("j_rocket").unwrap();
    assert_eq!(rocket.dollar_bonus(&context), 1.0);
    // 普通回合末不成长, 只有调用方明确的 Boss 结算才增加奖金.
    rocket.end_of_round_effect(&mut Rng::new("ROCKET-AUDIT"), 1.0);
    assert_eq!(rocket.dollar_bonus(&context), 1.0);
    rocket.end_of_round_boss_effects();
    assert_eq!(rocket.dollar_bonus(&context), 3.0);
    rocket.debuffed = true;
    rocket.end_of_round_boss_effects();
    rocket.debuffed = false;
    assert_eq!(rocket.dollar_bonus(&context), 3.0);
    rocket.config = Json::parse(r#"{"extra":{"dollars":3,"increase":7}}"#).unwrap();
    rocket.end_of_round_boss_effects();
    assert_eq!(rocket.dollar_bonus(&context), 10.0);
}

#[test]
fn campfire_only_resets_on_an_active_boss_end_round_hook() {
    let mut campfire = Joker::new("j_campfire").unwrap();
    campfire.x_mult = 2.5;
    campfire.end_of_round_effect(&mut Rng::new("CAMPFIRE-AUDIT"), 1.0);
    assert_eq!(campfire.x_mult, 2.5);
    campfire.debuffed = true;
    campfire.end_of_round_boss_effects();
    assert_eq!(campfire.x_mult, 2.5);
    campfire.debuffed = false;
    campfire.end_of_round_boss_effects();
    assert_eq!(campfire.x_mult, 1.0);
    campfire.end_of_round_boss_effects();
    assert_eq!(campfire.x_mult, 1.0);
}

#[test]
fn loyalty_cycle_advances_during_debuff_and_seance_accepts_containing_hands() {
    let cards = [card("H_A")];
    let table = HandTable::new();
    let hands = evaluate_poker_hand(&cards, &EvalEnv::default());
    let context = ctx(&cards, &hands, &table);
    let mut loyalty = Joker::new("j_loyalty_card").unwrap();
    loyalty.debuffed = true;
    for _ in 0..4 { loyalty.before(&context); }
    loyalty.debuffed = false; loyalty.before(&context);
    assert_eq!(loyalty.joker_main(&context, &mut Rng::new("LOYAL-AUDIT")).unwrap().xmult_mod, 4.0);
    let mut seance = Joker::new("j_seance").unwrap();
    seance.config = Json::parse(r#"{"extra":{"poker_hand":"Pair"}}"#).unwrap();
    let pair = [card("C_2"), card("D_2"), card("H_2")];
    let hands = evaluate_poker_hand(&pair, &EvalEnv::default());
    let context = ctx(&pair, &hands, &table);
    let effect = seance.joker_main(&context, &mut Rng::new("SEANCE-AUDIT")).unwrap();
    assert_eq!(effect.create_consumable, Some(("Spectral", "sea")));
    assert!(!effect.is_empty());
}
