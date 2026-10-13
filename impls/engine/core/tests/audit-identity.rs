//! 已创建商店卡转移到持有区时保留出生身份, 新建/复制另行分配.
mod common;

use balatro_engine::run::{BlindKind, Phase, RunState};
use balatro_engine::run::shop::Shop;

#[test]
fn reverse_purchase_preserves_shelf_birth_ids_and_acorn_order() {
    let mut run = RunState::new("identity-transfer", 1);
    run.start_run();
    run.phase = Phase::Shop;
    run.dollars = 100.0;
    run.shop_size_bonus = 1;
    run.tarot_rate = 0.0;
    run.planet_rate = 0.0;
    run.playing_card_rate = 0.0;
    run.spectral_rate = 0.0;
    // 此例只检验两张既有对象的身份转移与洗牌, 排除 setting_blind 增删队员或禁用 Boss.
    for key in ["j_ceremonial", "j_riff_raff", "j_chicot"] {
        run.banned_keys.insert(key.into());
    }
    let shop = Shop::restock(&mut run);
    assert_eq!(shop.jokers.len(), 3);
    assert!(shop.jokers.iter().all(|card| card.key.starts_with("j_")));
    let stock = shop.jokers.clone();
    let birth_ids: Vec<_> = stock.iter().map(|card| card.sort_id).collect();
    assert!(birth_ids[0] > 0);
    assert!(birth_ids.windows(2).all(|pair| pair[0] < pair[1]));
    run.shop = Some(shop);

    // 买的是已有货架对象, 不是调用 add_joker 新建另一张同原型牌.
    run.buy(&stock[2]).unwrap();
    run.buy(&stock[0]).unwrap();
    assert_eq!(run.jokers.iter().map(|joker| joker.sort_id).collect::<Vec<_>>(),
        vec![birth_ids[2], birth_ids[0]]);
    assert_eq!(run.jokers.iter().map(|joker| joker.key.as_str()).collect::<Vec<_>>(),
        vec![stock[2].key.as_str(), stock[0].key.as_str()]);
    assert!(run.jokers[0].sort_id > run.jokers[1].sort_id,
        "出生先后不因逆序购买而重置");
    assert_eq!(run.shop.as_ref().unwrap().jokers.len(), 1);
    assert_eq!(run.shop.as_ref().unwrap().jokers[0].sort_id, birth_ids[1]);

    // 橡果每次洗牌前恢复真实出生顺序, 不以购买顺序或绝对全局编号建立基准.
    let mut expected_ids = vec![birth_ids[0], birth_ids[2]];
    let mut oracle = run.rng.clone();
    for _ in 0..3 {
        expected_ids.sort_unstable();
        oracle.pseudoshuffle(&mut expected_ids, "aajk");
    }
    run.blind_on_deck = BlindKind::Boss;
    run.boss_key = Some("bl_final_acorn".into());
    common::place_blind(&mut run);
    assert!(!run.blind.as_ref().unwrap().disabled);
    assert_eq!(run.jokers.iter().map(|joker| joker.sort_id).collect::<Vec<_>>(), expected_ids);
}
