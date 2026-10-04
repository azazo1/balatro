//! 扑克牌型判定.
//!
//! 抄自 `game/functions/misc_functions.lua` 的 `evaluate_poker_hand`, `get_X_same`, `get_flush`,
//! `get_straight` 与 `get_highest`.
//!
//! 游戏返回的是"每个牌型各有一组结果"的表, 末尾还会把高阶结果回填到低阶: 五条同时算四条,
//! 四条同时算三条, 三条同时算对子, 葫芦还会算两对. 那是给条件判断用的 "包含" 语义, 与
//! "本次实际打出的牌型" 不是一回事 (例如一张 `j_blackboard` 要判断的是这手牌里有没有对子,
//! 而不只是最终选中的牌型), 所以这里保留同样的结构.

use crate::cards::{PlayingCard, Suit};

/// 12 个独立牌型, 声明顺序即判定优先级 (高到低).
///
/// 皇家同花顺不是独立牌型, 只是同花顺在计分名单最低点数不小于 10 时的显示名.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PokerHand {
    FlushFive,
    FlushHouse,
    FiveOfAKind,
    StraightFlush,
    FourOfAKind,
    FullHouse,
    Flush,
    Straight,
    ThreeOfAKind,
    TwoPair,
    Pair,
    HighCard,
}

impl PokerHand {
    /// 判定优先级顺序, 与游戏里设置 `results.top` 的顺序一致.
    pub const BY_PRIORITY: [PokerHand; 12] = [
        PokerHand::FlushFive,
        PokerHand::FlushHouse,
        PokerHand::FiveOfAKind,
        PokerHand::StraightFlush,
        PokerHand::FourOfAKind,
        PokerHand::FullHouse,
        PokerHand::Flush,
        PokerHand::Straight,
        PokerHand::ThreeOfAKind,
        PokerHand::TwoPair,
        PokerHand::Pair,
        PokerHand::HighCard,
    ];

    pub fn index(self) -> usize {
        self as usize
    }

    /// 游戏里的键名, 例如 `Three of a Kind`. 与 `catalog.json` 的牌型表一致.
    pub fn key(self) -> &'static str {
        self.info().key
    }

    /// 按游戏里的键名反查, 认不出来给 `None`.
    pub fn from_key(key: &str) -> Option<PokerHand> {
        PokerHand::BY_PRIORITY
            .into_iter()
            .find(|hand| hand.info().key == key)
    }
}

/// 判定时看的一张牌.
///
/// 石头牌没有可用于牌型的点数与花色, 万能牌匹配所有花色: 两者都不改底牌本身的信息,
/// 所以记成标志位, 而不是改掉 `card`.
#[derive(Clone, Copy, Debug)]
pub struct HandCard {
    pub card: PlayingCard,
    pub stone: bool,
    pub wild: bool,
    /// 黄金牌 (金票要按"计分的黄金牌"给钱).
    pub gold: bool,
    /// 这张牌**带强化** (吸血鬼只吸带强化的牌).
    pub enhanced: bool,
    pub debuffed: bool,
    /// `ability.bonus + ability.perma_bonus`, 即卡面奖励与永久筹码之和.
    pub bonus: f64,
    /// 倍率牌给的倍率加成 (`ability.mult`).
    pub mult_bonus: f64,
    /// 玻璃牌的乘倍率 (`ability.x_mult`).
    pub x_mult: f64,
    /// 钢铁牌的乘倍率 (`ability.h_x_mult`). 它只在**这张牌留在手里**时生效.
    pub h_x_mult: f64,
    /// 这张计分牌要算几遍. 默认 1, 红封让它变成 2.
    pub repetitions: u32,
    /// 这张牌带金封: 它被打出时直接给三块.
    pub gold_seal: bool,
    /// 这张是幸运牌: 计分时要掷两次骰 (一次给倍率, 一次给钱).
    pub lucky: bool,
    /// 这张牌的版本. 闪箔加筹码, 镭射加倍率, 多彩乘倍率, 负片没有计分效果.
    ///
    /// 它只在**这张牌参与计分**时生效 —— 留在手里的牌不算 (游戏那边手牌区那一趟不取版本).
    pub edition: Option<crate::cards::Edition>,
}

impl HandCard {
    /// 一张没有任何修饰的牌.
    pub fn plain(card: PlayingCard) -> Self {
        HandCard {
            card,
            stone: false,
            gold: false,
            enhanced: false,
            wild: false,
            debuffed: false,
            bonus: 0.0,
            mult_bonus: 0.0,
            x_mult: 0.0,
            h_x_mult: 0.0,
            repetitions: 1,
            gold_seal: false,
            lucky: false,
            edition: None,
        }
    }

    /// `Card:get_chip_bonus()`: 这张牌贡献的点数筹码.
    ///
    /// 石头牌忽略底牌点数, 只给自身奖励; 被削弱的牌一点不给.
    pub fn chip_bonus(&self) -> f64 {
        if self.debuffed {
            return 0.0;
        }
        if self.stone {
            return self.bonus;
        }
        self.card.rank.nominal() + self.bonus
    }

    /// `Card:get_chip_mult()`: 倍率牌给的那一份倍率加成.
    ///
    /// 幸运牌也走这里, 但它那一份要掷骰决定, 所以不在这里给 (见 `score_play` 的说明).
    pub fn mult_bonus(&self) -> f64 {
        if self.debuffed {
            return 0.0;
        }
        self.mult_bonus
    }

    /// `Card:get_chip_x_mult()`: 玻璃牌的乘倍率.
    pub fn x_mult(&self) -> f64 {
        if self.debuffed {
            return 0.0;
        }
        self.x_mult
    }

    /// `Card:get_chip_h_x_mult()`: 钢铁牌的乘倍率, 只在这张牌**留在手里**时才给.
    pub fn h_x_mult(&self) -> f64 {
        if self.debuffed {
            return 0.0;
        }
        self.h_x_mult
    }

    /// `Card:get_id()` 里可用的点数. 石头牌返回 `None`, 与游戏里它被排除出同点数组和顺子等价.
    pub fn id(&self) -> Option<u8> {
        if self.stone { None } else { Some(self.card.rank.id()) }
    }

    /// `Card:get_nominal()`, 只用于挑高牌.
    pub fn nominal(&self) -> f64 {
        self.card.nominal()
    }

    /// `Card:is_suit(suit, nil, true)`, 即同花判定用的那一种.
    fn is_suit_for_flush(&self, suit: Suit, env: &EvalEnv) -> bool {
        if self.stone {
            return false;
        }
        if self.wild && !self.debuffed {
            return true;
        }
        if env.smeared && self.card.suit.is_red() == suit.is_red() {
            return true;
        }
        self.card.suit == suit
    }
}

/// 判定要看的小丑状态.
#[derive(Clone, Copy, Debug, Default)]
pub struct EvalEnv {
    /// 有生效的四指: 同花与顺子的最低长度从 5 降到 4.
    pub four_fingers: bool,
    /// 飞溅: 打出的牌**全部**参与计分, 而不只是符合牌型的那几张.
    pub splash: bool,
    /// 概率的**额外**分子 (七上八下那张小丑让所有概率翻倍, 这里就是 1.0).
    /// 0.0 表示正常 (分子为 1) —— 用"额外量"而不是"倍数", 是为了让 `Default` 恰好就是正常值.
    /// 概率判定一律写成 `(1.0 + probability_extra) / odds`.
    pub probability_extra: f64,
    /// 消耗槽还剩几个位子 (八号球 / 叠加态要先看位子再掷骰).
    pub consumable_room: usize,
    /// 天文台 (优惠券): 消耗区里有几张**对应本手牌型**的行星牌, 每张给一次 ×1.5.
    ///
    /// 它落在**所有小丑效果之后** —— 游戏的计分循环写的是
    /// `G.jokers.cards[i] or G.consumeables.cards[i - #G.jokers.cards]`, 先小丑后消耗品.
    pub observatory_planets: usize,
    /// 有生效的捷径: 顺子允许单点间隔.
    pub shortcut: bool,
    /// 有生效的模糊小丑: 红桃与方片同类, 黑桃与梅花同类.
    pub smeared: bool,
    /// 这一回合还剩几次弃牌. 旗帜与神秘之峰那类要看局面, 走这里传进来.
    pub discards_left: i64,
    /// 当前现金. 斗牛那类要看.
    pub dollars: f64,
    /// 牌堆里还剩多少张. 蓝色小丑那类要看.
    pub deck_len: usize,
    /// 牌堆里 9 有几张, 本局用掉过几张行星牌, 这一回合弃过几次牌.
    /// 这三个都是回合末给钱那几张要的 (9 霄云外 / 卫星 / 延迟满足).
    pub deck_nines: usize,
    pub planets_used: usize,
    pub discards_used: i64,
    /// 燧石 (The Flint) 生效: 牌型的基础筹码与倍率各砍一半.
    pub flint: bool,
    /// 上古小丑这一回合盯的花色. 计分引擎要用它给那种花色的牌加乘倍率.
    pub ancient_suit: Option<crate::cards::Suit>,
    /// 爱豆这一回合盯的那张牌 (花色 + 点数).
    pub idol_card: Option<(crate::cards::Suit, crate::cards::Rank)>,
    /// 帕瑞多利亚: 手里有它时人人都是人头牌.
    pub pareidolia: bool,
    /// 这一局**还活着**的牌一共几张, 以及其中石头牌 / 带强化的各有几张.
    ///
    /// 口径是游戏的 `G.playing_cards`: 牌堆 + 手牌 + 弃牌堆 + 刚打出去那几张都算.
    /// 石头小丑 / 侵蚀 / 驾照要看它们.
    pub deck_total: usize,
    pub deck_stones: usize,
    pub deck_enhanced: usize,
    /// 开局那副牌有多少张 (`G.GAME.starting_deck_size`). 侵蚀要比它.
    pub starting_deck_size: usize,
    /// 这一回合还剩几次出牌. 杂技演员要它 (最后一手才算), 而且要在**减过之后**读.
    pub hands_left: i64,
    /// 小丑格子总数. 模具小丑要它 (空位越多乘得越高).
    pub joker_slots: usize,
}

/// 一次判定的全部结果, 下标用 [`PokerHand::index`].
#[derive(Clone, Debug, Default)]
pub struct EvaluatedHand {
    groups: [Vec<Vec<usize>>; 12],
    top: Option<PokerHand>,
}

impl EvaluatedHand {
    /// 某个牌型的组列表. 空表示这手牌不满足它.
    pub fn groups(&self, hand: PokerHand) -> &[Vec<usize>] {
        &self.groups[hand.index()]
    }

    /// 这手牌是否满足某个牌型, 包含回填后的结果.
    pub fn has(&self, hand: PokerHand) -> bool {
        !self.groups[hand.index()].is_empty()
    }

    /// 优先级最高的非空牌型, 也就是本次实际选中的牌型.
    pub fn top(&self) -> Option<PokerHand> {
        self.top
    }

    /// 选中牌型的第一组, 也就是初始计分名单.
    pub fn top_group(&self) -> Option<&Vec<usize>> {
        self.top.and_then(|h| self.groups(h).first())
    }
}

/// `evaluate_poker_hand`.
pub fn evaluate_poker_hand(hand: &[HandCard], env: &EvalEnv) -> EvaluatedHand {
    let five = get_x_same(5, hand);
    let four = get_x_same(4, hand);
    let three = get_x_same(3, hand);
    let two = get_x_same(2, hand);
    let flush = get_flush(hand, env);
    let straight = get_straight(hand, env);
    let highest = get_highest(hand);

    let mut out = EvaluatedHand {
        groups: std::array::from_fn(|_| Vec::new()),
        top: None,
    };

    if !five.is_empty() && !flush.is_empty() {
        out.groups[PokerHand::FlushFive.index()] = five.clone();
        out.top = out.top.or(Some(PokerHand::FlushFive));
    }

    if !three.is_empty() && !two.is_empty() && !flush.is_empty() {
        out.groups[PokerHand::FlushHouse.index()] = vec![concat_groups(&three[0], &two[0])];
        out.top = out.top.or(Some(PokerHand::FlushHouse));
    }

    if !five.is_empty() {
        out.groups[PokerHand::FiveOfAKind.index()] = five.clone();
        out.top = out.top.or(Some(PokerHand::FiveOfAKind));
    }

    if !flush.is_empty() && !straight.is_empty() {
        // 同花组在前, 再补上顺子里不在同花组中的牌: 是两组 4 张牌的并集.
        let mut merged = flush[0].clone();
        for &idx in &straight[0] {
            if !merged.contains(&idx) {
                merged.push(idx);
            }
        }
        out.groups[PokerHand::StraightFlush.index()] = vec![merged];
        out.top = out.top.or(Some(PokerHand::StraightFlush));
    }

    if !four.is_empty() {
        out.groups[PokerHand::FourOfAKind.index()] = four.clone();
        out.top = out.top.or(Some(PokerHand::FourOfAKind));
    }

    if !three.is_empty() && !two.is_empty() {
        out.groups[PokerHand::FullHouse.index()] = vec![concat_groups(&three[0], &two[0])];
        out.top = out.top.or(Some(PokerHand::FullHouse));
    }

    if !flush.is_empty() {
        out.groups[PokerHand::Flush.index()] = flush.clone();
        out.top = out.top.or(Some(PokerHand::Flush));
    }

    if !straight.is_empty() {
        out.groups[PokerHand::Straight.index()] = straight.clone();
        out.top = out.top.or(Some(PokerHand::Straight));
    }

    if !three.is_empty() {
        out.groups[PokerHand::ThreeOfAKind.index()] = three.clone();
        out.top = out.top.or(Some(PokerHand::ThreeOfAKind));
    }

    // 两对: 恰好两个对子, 或者一个三条加一个对子 (后者是葫芦, 也算两对).
    if two.len() == 2 || (three.len() == 1 && two.len() == 1) {
        let first = &two[0];
        let second = if two.len() >= 2 { &two[1] } else { &three[0] };
        out.groups[PokerHand::TwoPair.index()] = vec![concat_groups(first, second)];
        out.top = out.top.or(Some(PokerHand::TwoPair));
    }

    if !two.is_empty() {
        out.groups[PokerHand::Pair.index()] = two.clone();
        out.top = out.top.or(Some(PokerHand::Pair));
    }

    if !highest.is_empty() {
        out.groups[PokerHand::HighCard.index()] = highest.clone();
        out.top = out.top.or(Some(PokerHand::HighCard));
    }

    // 包含回填. 顺序不能换: 四条可能刚被五条覆盖, 三条又取四条, 对子再取三条.
    inherit(&mut out.groups, PokerHand::FiveOfAKind, PokerHand::FourOfAKind, 4);
    inherit(&mut out.groups, PokerHand::FourOfAKind, PokerHand::ThreeOfAKind, 3);
    inherit(&mut out.groups, PokerHand::ThreeOfAKind, PokerHand::Pair, 2);

    out
}

fn concat_groups(a: &[usize], b: &[usize]) -> Vec<usize> {
    let mut v = Vec::with_capacity(a.len() + b.len());
    v.extend_from_slice(a);
    v.extend_from_slice(b);
    v
}

/// 把 `from` 的前 `take` 组搬到 `to`, 只在 `from` 非空时覆盖.
fn inherit(
    groups: &mut [Vec<Vec<usize>>; 12],
    from: PokerHand,
    to: PokerHand,
    take: usize,
) {
    let src = groups[from.index()].clone();
    if src.is_empty() {
        return;
    }
    groups[to.index()] = (0..take).filter_map(|k| src.get(k).cloned()).collect();
}

/// `get_flush`: 按 黑桃 / 红桃 / 梅花 / 方片 的顺序找首个够张数的同花组.
fn get_flush(hand: &[HandCard], env: &EvalEnv) -> Vec<Vec<usize>> {
    const ORDER: [Suit; 4] = [Suit::Spades, Suit::Hearts, Suit::Clubs, Suit::Diamonds];
    let need = if env.four_fingers { 4 } else { 5 };
    if hand.len() > 5 || hand.len() < need {
        return Vec::new();
    }
    for suit in ORDER {
        let group: Vec<usize> = hand
            .iter()
            .enumerate()
            .filter(|(_, c)| c.is_suit_for_flush(suit, env))
            .map(|(i, _)| i)
            .collect();
        if group.len() >= need {
            return vec![group];
        }
    }
    Vec::new()
}

/// `get_straight`.
///
/// `j = 1` 时看的是点数 14 (A), 这样 `A,2,3,4,5` 也能连上; `j` 走到 14 时再看一次 A,
/// 于是 `10,J,Q,K,A` 同样成立. 捷径的跳过点也只允许一个, 且不允许发生在 `j = 14`,
/// 所以 A 不能首尾环绕.
fn get_straight(hand: &[HandCard], env: &EvalEnv) -> Vec<Vec<usize>> {
    let need = if env.four_fingers { 4 } else { 5 };
    if hand.len() > 5 || hand.len() < need {
        return Vec::new();
    }

    let mut by_id: [Vec<usize>; 15] = std::array::from_fn(|_| Vec::new());
    for (i, card) in hand.iter().enumerate() {
        if let Some(id) = card.id()
            && id > 1
            && id < 15
        {
            by_id[id as usize].push(i);
        }
    }

    let mut picked: Vec<usize> = Vec::new();
    let mut length = 0usize;
    let mut found = false;
    let mut skipped = false;
    for j in 1..=14usize {
        let id = if j == 1 { 14 } else { j };
        if !by_id[id].is_empty() {
            length += 1;
            skipped = false;
            picked.extend_from_slice(&by_id[id]);
        } else if env.shortcut && !skipped && j != 14 {
            skipped = true;
        } else {
            length = 0;
            skipped = false;
            if !found {
                picked.clear();
            }
            if found {
                break;
            }
        }
        if length >= need {
            found = true;
        }
    }

    if found { vec![picked] } else { Vec::new() }
}

/// `get_X_same`: 找恰好 `num` 张的同点数组, 从大点数到小点数返回.
fn get_x_same(num: usize, hand: &[HandCard]) -> Vec<Vec<usize>> {
    let mut by_id: [Option<Vec<usize>>; 15] = std::array::from_fn(|_| None);
    for i in (0..hand.len()).rev() {
        let Some(id) = hand[i].id() else { continue };
        let mut group = vec![i];
        for (j, other) in hand.iter().enumerate() {
            if j != i && other.id() == Some(id) {
                group.push(j);
            }
        }
        if group.len() == num {
            by_id[id as usize] = Some(group);
        }
    }

    let mut out = Vec::new();
    for i in (1..15).rev() {
        if let Some(group) = by_id[i].take() {
            out.push(group);
        }
    }
    out
}

/// `get_highest`: 挑出牌面最大的一张, 作为高牌的候选.
fn get_highest(hand: &[HandCard]) -> Vec<Vec<usize>> {
    let mut best: Option<usize> = None;
    for (i, card) in hand.iter().enumerate() {
        match best {
            None => best = Some(i),
            Some(b) if card.nominal() > hand[b].nominal() => best = Some(i),
            _ => {}
        }
    }
    match best {
        Some(i) => vec![vec![i]],
        None => Vec::new(),
    }
}
