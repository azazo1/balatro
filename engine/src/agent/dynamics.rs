//! 会随局面变的值.
//!
//! 手册的效果文本对这类值只能写成占位 (`[本回合目标花色]`, `(当前为+[当前筹码]筹码)`), 因为同一个
//! 原型在不同回合的行为不一样. 内置 agent 为此单独有一个 `dynamics` 工具, 并要求"不要猜, 先查".
//!
//! 这些值直接决定这一步该打哪几张: 古老小丑认的花色每回合重掷, 押错的那手可能只有目标分的一半.

use crate::cards::{Rank, Suit};
use crate::run::RunState;


use super::summary::{hand_zh, number};

fn suit_zh(suit: Suit) -> &'static str {
    match suit {
        Suit::Clubs => "梅花",
        Suit::Diamonds => "方片",
        Suit::Hearts => "红桃",
        Suit::Spades => "黑桃",
    }
}

fn rank_zh(rank: Rank) -> &'static str {
    use Rank::*;
    match rank {
        Two => "2",
        Three => "3",
        Four => "4",
        Five => "5",
        Six => "6",
        Seven => "7",
        Eight => "8",
        Nine => "9",
        Ten => "10",
        Jack => "J",
        Queen => "Q",
        King => "K",
        Ace => "A",
    }
}

/// 摸牌堆或弃牌堆的统计. 算同花与顺子的命中率要用它.
pub struct Pile {
    pub total: usize,
    /// 按花色: `(花色, 张数)`, 只列非空的.
    pub suits: Vec<(Suit, usize)>,
    /// 按点数: `(点数, 张数)`, 只列非空的.
    pub ranks: Vec<(Rank, usize)>,
}

fn tally<'a>(cards: impl Iterator<Item = &'a crate::cards::CardInstance>) -> Pile {
    let mut total = 0usize;
    let mut suits = [0usize; 4];
    // 点数按下标 `id() - 2` 数 (2..9 是本身, J/Q/K 为 11/12/13, A 为 14), 于是天然就是
    // 读数顺序 2..9, 10, J, Q, K, A. 不用 `Rank::ALL` 的下标: 那是建牌顺序 (A 在 J 前,
    // 10 在最后), 对引擎有意义, 但列给人看像是有意排的古怪次序, 读起来要来回找.
    let mut ranks = [0usize; 13];
    for card in cards {
        total += 1;
        let suit_index = Suit::ALL
            .iter()
            .position(|candidate| *candidate == card.card.suit)
            .unwrap_or(0);
        suits[suit_index] += 1;
        ranks[card.card.rank.id() as usize - 2] += 1;
    }
    Pile {
        total,
        suits: Suit::ALL
            .iter()
            .zip(suits)
            .filter(|(_, count)| *count > 0)
            .map(|(suit, count)| (*suit, count))
            .collect(),
        ranks: Rank::ALL
            .iter()
            .map(|rank| (*rank, ranks[rank.id() as usize - 2]))
            .filter(|(_, count)| *count > 0)
            .collect::<Vec<_>>()
            .tap_sorted_by_id(),
    }
}

/// 收尾: 按 `Rank::id()` 排序. 写成 trait 只为让上面那个构造读起来还是一串.
trait TapSortedById {
    fn tap_sorted_by_id(self) -> Self;
}

impl TapSortedById for Vec<(Rank, usize)> {
    fn tap_sorted_by_id(mut self) -> Self {
        self.sort_by_key(|(rank, _)| rank.id());
        self
    }
}

/// 未见牌集合的统计. 背面手牌并入集合, 不借摸牌堆差值反推暗牌身份.
pub fn deck_pile(run: &RunState) -> Pile {
    tally(run.deck.iter().chain(run.hand.iter().filter(|card| card.face_down)))
}

/// 弃牌堆的统计 (这一回合弃掉与打出的牌).
pub fn discard_pile(run: &RunState) -> Pile {
    tally(run.discard_pile.iter())
}

/// 一行统计文本: `17 张 | 梅花 4, 方片 5, 红桃 4, 黑桃 4 | 点数 2:1 3:2 ...`.
///
/// 点数那一段只列**还有牌的点数**, 因为空白点数对"能不能凑顺子"是决定性信息.
pub fn pile_line(label: &str, pile: &Pile) -> String {
    let suits: Vec<String> = pile
        .suits
        .iter()
        .map(|(suit, count)| format!("{} {count}", suit_zh(*suit)))
        .collect();
    let ranks: Vec<String> = pile
        .ranks
        .iter()
        .map(|(rank, count)| format!("{}:{count}", rank_zh(*rank)))
        .collect();
    let mut line = format!("{label} {} 张", pile.total);
    if !suits.is_empty() {
        line.push_str(&format!(" | {}", suits.join(", ")));
    }
    if !ranks.is_empty() {
        line.push_str(&format!(" | 点数 {}", ranks.join(" ")));
    }
    line
}

/// 这一局里"每回合会重掷、且会影响这一手分数"的值. 只有还持有对应小丑时才列出来.
pub fn render(run: &RunState) -> String {
    let mut out: Vec<String> = Vec::new();
    let holds = |key: &str| {
        !run.jokers_face_down() && run.jokers
            .iter()
            .any(|joker| joker.key == key && !joker.debuffed)
    };

    // 古老小丑: 认一个花色, 该花色的计分牌各给一份乘倍率.
    if holds("j_ancient") {
        let suit = run
            .ancient_suit
            .map(|suit| suit_zh(suit).to_owned())
            .unwrap_or_else(|| "(本回合还没掷)".to_owned());
        out.push(format!("古老小丑认的花色: {suit}"));
    }
    // 偶像: 认一个花色 + 一个点数, 命中那张牌各给一份乘倍率.
    if holds("j_idol") {
        let text = run
            .idol_card
            .map(|(suit, rank)| format!("{}{}", suit_zh(suit), rank_zh(rank)))
            .unwrap_or_else(|| "(本回合还没掷)".to_owned());
        out.push(format!("偶像认的牌: {text}"));
    }
    // 邮件回扣: 命中点数的那张牌打出去给钱.
    if holds("j_mail") {
        let rank = run
            .mail_rank
            .map(|rank| rank_zh(rank).to_owned())
            .unwrap_or_else(|| "(本回合还没掷)".to_owned());
        out.push(format!("邮件回扣认的点数: {rank}"));
    }
    // 城堡: 每弃掉一张该花色的牌就涨筹码.
    if holds("j_castle") {
        let suit = run
            .castle_suit
            .map(|suit| suit_zh(suit).to_owned())
            .unwrap_or_else(|| "(本回合还没掷)".to_owned());
        out.push(format!("城堡认的花色: {suit}"));
    }
    // 待办清单: 认一个牌型, 打中才给加成.
    for (index, joker) in run.jokers.iter().enumerate() {
        if !run.jokers_face_down() && joker.key == "j_todo_list" {
            let hand = joker
                .todo_hand
                .map(|hand| hand_zh(hand).to_owned())
                .unwrap_or_else(|| "(本回合还没掷)".to_owned());
            out.push(format!("待办清单[{index}]认的牌型: {hand}"));
        }
    }
    // 盲注公牛: 打到"最常打出的牌型"时乘倍率.
    if holds("j_obelisk") {
        out.push(format!(
            "盲注公牛要用的最常打出牌型: {}",
            hand_zh(run.hands.most_played())
        ));
    }
    // 本局最后打过的牌型 (蓝封, 全息等按它给牌).
    if let Some(hand) = run.last_hand_played {
        out.push(format!("本局最后打出的牌型: {}", hand_zh(hand)));
    }

    // 小丑的成长值: 手册里这些是占位, 只有当前值说了算.
    for (index, joker) in run.jokers.iter().enumerate() {
        if run.jokers_face_down() {
            continue;
        }
        let live = super::summary::joker_current(joker);
        if !live.is_empty() {
            let name = crate::data::knowledge::describe(&joker.key)
                .map(|(name, _)| name.to_owned())
                .unwrap_or_else(|| joker.key.clone());
            out.push(format!("小丑[{index}] {name} 当前: {live}"));
        }
    }

    // 出牌次数与手牌上限不在这里报: 局面摘要那一段已经有, 两处都写只会让人以为它们不同.
    //
    // 容量: 买之前要看, 否则会买下放不下.
    out.push(format!(
        "小丑位 {}/{}, 消耗槽 {}/{}",
        run.jokers.len(),
        run.joker_capacity(),
        run.consumables.len(),
        run.consumable_capacity()
    ));
    // 利息: 经济决策要看还能不能保住那一档.
    if !run.no_interest {
        let interest = crate::run::interest(run.dollars, run.interest_rate, run.interest_cap);
        out.push(format!(
            "当前利息 ${} (每 $5 给 ${}, 上限 ${})",
            number(interest),
            number(run.interest_rate),
            number(run.interest_cap)
        ));
    }

    let deck_label = if run.hand.iter().any(|card| card.face_down) {
        "未见牌集合(摸牌堆及背面手牌)"
    } else {
        "摸牌堆"
    };
    out.push(pile_line(deck_label, &deck_pile(run)));
    out.push(pile_line("弃牌堆(本回合)", &discard_pile(run)));
    out.join("\n")
}
