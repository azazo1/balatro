//! 开局链路与真游戏对拍.
//!
//! 期望值取自 `recordings/20261003-224812-ALEEB/` 的第一条 digest: 种子 ALEEB, 等离子牌组,
//! 黄金赌注, 选完小盲注之后手牌是 `C_T,D_T,S_9,S_7,H_6,H_5,H_4,D_2`, 牌堆还剩 44 张.
//!
//! 这条链路把开局会用到的随机都串了起来, 任何一处调用顺序或参数不对都会在这里露出来.

use balatro_engine::cards::{PlayingCard, sort_by_nominal_desc, sort_by_sort_id, standard_deck};
use balatro_engine::rng::Rng;

/// 按开局的顺序洗完一副标准牌, 并发出第一手.
///
/// 两次洗牌分别对应 `Game:start_run` 的 `self.deck:shuffle()` 与进入 `DRAW_TO_HAND` 时的
/// `G.deck:shuffle('nr'..ante)`. 两次之间牌堆会重新按 `sort_id` 排序, 那是 `pseudoshuffle`
/// 开头那一步做的.
fn deal_opening_hand(seed: &str) -> (Vec<PlayingCard>, Vec<PlayingCard>) {
    let mut rng = Rng::new(seed);
    let mut deck = standard_deck();

    for key in ["shuffle", "nr1"] {
        sort_by_sort_id(&mut deck);
        rng.pseudoshuffle(&mut deck, key);
    }

    // 发牌取牌堆尾部: CardArea:remove_card 对 deck 类型取 _cards[#_cards].
    // 每抽一张, draw_card 的 sort 参数会让手牌按 nominal 降序重排一次, 所以这里照做.
    let mut hand: Vec<PlayingCard> = Vec::new();
    for _ in 0..8 {
        let card = deck.pop().expect("牌堆里应当还有牌");
        hand.push(card);
        sort_by_nominal_desc(&mut hand);
    }
    (hand, deck)
}

#[test]
fn plasma_gold_opening_hand_matches_replay() {
    let (hand, rest) = deal_opening_hand("ALEEB");

    let hand_keys: Vec<String> = hand.iter().map(|c| c.key()).collect();
    assert_eq!(
        hand_keys.join(","),
        "C_T,D_T,S_9,S_7,H_6,H_5,H_4,D_2",
        "手牌与回放第一条 digest 不一致"
    );
    assert_eq!(rest.len(), 44, "牌堆剩余张数应当与 digest 的 deck=44 一致");
}
