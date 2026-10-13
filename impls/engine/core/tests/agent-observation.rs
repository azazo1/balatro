//! 观察边界, 盲注生命周期和通关动作门禁的关键行为回归.

use balatro_engine::agent::{action, dynamics, observation, summary};
use balatro_engine::agent::observation::{BlindStatus, ScoreVisibility};
use balatro_engine::cards::{CardInstance, Enhancement, Rank, Suit};
use balatro_engine::data::json::Json;
use balatro_engine::jokers::Joker;
use balatro_engine::run::{ActionError, BlindKind, Phase, RunState};
use balatro_engine::run::shop::{OpenPack, PackCard};
use balatro_engine::scoring::{BackEffect, EvalEnv, ScoreSource};

fn boss(key: &str, ante: i64) -> RunState {
    let mut run = RunState::new("OBSERVE", 8);
    run.start_run();
    run.ante = ante;
    run.blind_on_deck = BlindKind::Boss;
    run.boss_key = Some(key.to_owned());
    run.select_blind().unwrap();
    run.blind.as_mut().unwrap().chips = 1e12;
    run
}

#[test]
fn house_and_fish_keep_only_the_correct_draws_hidden() {
    let mut house = boss("bl_house", 1);
    assert!(house.hand.iter().all(|card| card.face_down));
    house.discard(&[0]).unwrap();
    assert_eq!(house.hand.iter().filter(|card| card.face_down).count(), 7);
    assert!(house.discard_pile.iter().all(|card| !card.face_down));
    house.jokers.push(Joker::new("j_luchador").unwrap());
    house.sell_joker(0).unwrap();
    assert!(house.blind.as_ref().unwrap().disabled);
    assert!(house.hand.iter().all(|card| !card.face_down));

    let mut fish = boss("bl_fish", 1);
    assert!(fish.hand.iter().all(|card| !card.face_down));
    fish.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
    assert_eq!(fish.hand.iter().filter(|card| card.face_down).count(), 1);
    let hidden = fish.hand.iter().position(|card| card.face_down).unwrap();
    fish.discard(&[hidden]).unwrap();
    assert!(fish.hand.iter().all(|card| !card.face_down));
}

#[test]
fn mark_wheel_and_disabled_blinds_respect_visibility_without_rng_drift() {
    let mut mark = boss("bl_mark", 1);
    assert!(mark.hand.iter().all(|card| card.face_down == card.card.rank.is_face()));
    let mut stone = CardInstance::from_key("H_K").unwrap();
    stone.enhancement = Some(Enhancement::Stone);
    mark.deck = vec![stone];
    mark.hand.clear();
    mark.draw_to_hand();
    assert!(!mark.hand[0].face_down);
    mark.jokers.push(Joker::new("j_pareidolia").unwrap());
    mark.deck = vec![stone];
    mark.hand.clear();
    mark.draw_to_hand();
    assert!(mark.hand.iter().all(|card| card.face_down));

    let mut wheel = boss("bl_wheel", 1);
    wheel.hand.clear();
    wheel.probability_scale = 7.0;
    let mut expected = wheel.rng.clone();
    for _ in 0..8 { expected.pseudorandom("wheel"); }
    wheel.draw_to_hand();
    assert!(wheel.hand.iter().all(|card| card.face_down));
    assert_eq!(wheel.rng.pseudorandom("wheel"), expected.pseudorandom("wheel"));
    wheel.blind.as_mut().unwrap().disabled = true;
    wheel.hand.clear();
    let mut expected = wheel.rng.clone();
    wheel.draw_to_hand();
    assert!(wheel.hand.iter().all(|card| !card.face_down));
    assert_eq!(wheel.rng.pseudorandom("wheel"), expected.pseudorandom("wheel"));
}

#[test]
fn hidden_identity_exchange_does_not_change_public_observation() {
    let mut run = boss("bl_house", 1);
    let before = summary::render(&run, &Default::default());
    let dynamics_before = dynamics::render(&run);
    let raw = balatro_engine::run::digest(&run);
    std::mem::swap(&mut run.hand[0], &mut run.deck[0]);
    run.hand[0].face_down = true;
    run.deck[0].face_down = false;
    assert_eq!(before, summary::render(&run, &Default::default()));
    assert_eq!(dynamics_before, dynamics::render(&run));
    assert_ne!(raw, balatro_engine::run::digest(&run));
}

#[test]
fn score_reports_mask_hidden_sources_but_keep_scoring_numbers() {
    for key in ["bl_house", "bl_final_acorn"] {
        let mut run = boss(key, 1);
        run.jokers.push(Joker::new("j_joker").unwrap());
        run.hand[1].enhancement = Some(Enhancement::Steel);
        let visibility = ScoreVisibility::capture(&run);
        let played = vec![run.hand[0]];
        let result = run.play(&[0], &EvalEnv::default(), BackEffect::Plain).unwrap();
        let mut changed = result.clone();
        let mut masked = 0;
        for step in &mut changed.steps {
            if visibility.hides(&step.source) {
                masked += 1;
                match &mut step.source {
                    ScoreSource::Held { card } => { card.suit = Suit::Diamonds; card.rank = Rank::Two; }
                    ScoreSource::Joker { key } => *key = "unobservable-joker".to_owned(),
                    _ => unreachable!(),
                }
            }
        }
        assert!(masked > 0);
        assert_eq!(summary::score_report(&result, &played, 1, &visibility),
            summary::score_report(&changed, &played, 1, &visibility));
        assert_eq!(result.total, changed.total);
        run.chips = 1e12;
        run.end_round();
        assert!(!run.jokers_face_down());
        assert_eq!(summary::score_report(&result, &played, 1, &visibility),
            summary::score_report(&changed, &played, 1, &visibility));
    }
}

#[test]
fn completed_and_failed_blinds_do_not_mislabel_the_next_boss() {
    let mut run = boss("bl_house", 1);
    run.skipped_blinds[0] = true;
    run.chips = 1e12;
    run.end_round();
    assert_eq!(observation::blind_key(&run, 2).as_deref(), Some("bl_house"));
    assert_eq!(observation::blind_status(&run, 2), BlindStatus::Defeated);
    assert_eq!(observation::blind_status(&run, 0), BlindStatus::Skipped);
    run.cash_out().unwrap();
    assert_eq!(observation::blind_key(&run, 2), run.boss_key);
    for index in 0..3 { assert_eq!(observation::blind_status(&run, index), BlindStatus::Upcoming); }
    run.phase = Phase::BoosterOpened;
    run.pack_return_phase = Phase::Shop;
    assert_eq!(observation::blind_status(&run, 2), BlindStatus::Upcoming);
    run.phase = Phase::Shop;
    run.next_round().unwrap();
    assert_eq!(run.skipped_blinds, [false, false]);
    assert_eq!(observation::blind_status(&run, 0), BlindStatus::Select);

    let mut lost = RunState::new("OBSERVE", 8);
    lost.start_run();
    lost.select_blind().unwrap();
    lost.end_round();
    assert_eq!(lost.phase, Phase::GameOver);
    assert_eq!(observation::blind_status(&lost, 0), BlindStatus::Failed);
    assert_eq!(observation::blind_status(&lost, 1), BlindStatus::Upcoming);
}

#[test]
fn victory_blocks_actions_until_explicit_endless_without_losing_won() {
    let mut run = boss("bl_final_leaf", 8);
    run.chips = 1e12;
    run.end_round();
    assert!(run.won && run.win_overlay);
    assert_eq!(run.phase, Phase::RoundEval);
    let dollars = run.dollars;
    let raw = balatro_engine::run::digest(&run);
    assert!(matches!(run.cash_out(), Err(ActionError::NotAllowed(_))));
    let sort = Json::parse(r#"{"method":"sort_hand_value"}"#).unwrap();
    assert!(matches!(action::apply(&sort, &mut run, &Default::default()), Err(ActionError::NotAllowed(_))));
    assert_eq!(run.dollars, dollars);
    assert_eq!(balatro_engine::run::digest(&run), raw);
    let endless = Json::parse(r#"{"method":"endless"}"#).unwrap();
    action::apply(&endless, &mut run, &Default::default()).unwrap();
    assert!(run.won && !run.win_overlay);
    assert!(run.endless().is_err());
    run.cash_out().unwrap();
    assert_eq!(run.phase, Phase::Shop);
}

#[test]
fn spent_immediate_tags_leave_pending_tags_and_double_payout_intact() {
    let mut run = RunState::new("OBSERVE", 8);
    run.start_run();
    run.tags = vec!["tag_double".to_owned(), "tag_investment".to_owned()];
    run.total_hands_played = 7;
    run.blind_tags[0] = Some("tag_handy".to_owned());
    let dollars = run.dollars;
    run.skip_blind().unwrap();
    assert_eq!(run.dollars, dollars + 14.0);
    assert_eq!(run.tags, ["tag_investment"]);
    assert!(run.skipped_blinds[0]);
}

#[test]
fn voucher_tags_are_consumed_only_when_the_extra_vouchers_reach_the_shop() {
    let mut run = RunState::new("OBSERVE", 8);
    run.start_run();
    run.tags.push("tag_investment".to_owned());
    run.blind_tags[0] = Some("tag_voucher".to_owned());
    run.skip_blind().unwrap();
    assert!(run.tags.iter().any(|tag| tag == "tag_voucher"));
    assert_eq!(run.extra_voucher_keys.len(), 1);
    run.select_blind().unwrap();
    run.chips = 1e12;
    run.end_round();
    run.cash_out().unwrap();
    assert_eq!(run.shop.as_ref().unwrap().vouchers.len(), 2);
    assert!(run.extra_voucher_keys.is_empty());
    assert_eq!(run.tags, ["tag_investment"]);
}

#[test]
fn pack_stickers_are_observable_and_copying_does_not_copy_facing() {
    let mut run = RunState::new("OBSERVE", 8);
    run.phase = Phase::BoosterOpened;
    run.open_pack = Some(OpenPack {
        key: "p_buffoon_normal_1".to_owned(), choices_left: 1, size: 1,
        contents: vec![PackCard { sort_id: 1, key: "j_joker".to_owned(), edition: None, seal: None,
            enhancement: None, todo: None, eternal: false, perishable: false, rental: false }],
    });
    let plain = summary::render(&run, &Default::default());
    run.open_pack.as_mut().unwrap().contents[0].perishable = true;
    assert_ne!(plain, summary::render(&run, &Default::default()));

    let mut target = CardInstance::from_key("H_K").unwrap();
    target.face_down = true;
    let source = CardInstance::from_key("S_A").unwrap();
    target.copy_onto(&source);
    assert!(target.face_down);
    let copy = target.duplicate(500);
    assert!(!copy.face_down);
    assert_eq!(copy.card.sort_id, 500);
}

#[test]
fn replay_validates_endless_instead_of_skipping_it_as_observation() {
    let header = Json::parse(r#"{"seed":"OBSERVE","deck":"RED","stake":"GOLD","uda":{}}"#).unwrap();
    let step = Json::parse(r#"{"method":"endless","ok":false}"#).unwrap();
    let report = balatro_engine::replay::check(&header, &[step], false);
    assert!(report.failure.is_none());
    assert_eq!(report.matched_refusals, 1);
    assert_eq!(report.skipped_observations, 0);
}
