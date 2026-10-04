//! 牌型的等级与基础值.
//!
//! 静态参数抄自 `game/game.lua` 的牌型表 (L2002 起), 升级规则抄自
//! `game/functions/common_events.lua` 的 `level_up_hand` (L464).
//!
//! 当前筹码与倍率是**从等级派生**的, 游戏并不单独维护累加值: 每次升级都按
//! `s_* + l_* * (level - 1)` 重算一遍. 所以这里也只存等级, 避免两处状态对不上.

use super::poker_hand::PokerHand;

/// 牌型的静态参数.
#[derive(Clone, Copy, Debug)]
pub struct HandInfo {
    /// 游戏里的键名, 例如 `Flush Five`.
    pub key: &'static str,
    /// 等级 1 的筹码与倍率.
    pub s_chips: f64,
    pub s_mult: f64,
    /// 每升一级的增量.
    pub l_chips: f64,
    pub l_mult: f64,
    /// 初始是否显示在牌型列表里. 三种隐藏牌型各打出一次后变可见.
    pub visible: bool,
}

impl PokerHand {
    /// 这个牌型的静态参数.
    pub fn info(self) -> HandInfo {
        use PokerHand::*;
        match self {
            FlushFive => HandInfo {
                key: "Flush Five",
                s_chips: 160.0,
                s_mult: 16.0,
                l_chips: 50.0,
                l_mult: 3.0,
                visible: false,
            },
            FlushHouse => HandInfo {
                key: "Flush House",
                s_chips: 140.0,
                s_mult: 14.0,
                l_chips: 40.0,
                l_mult: 4.0,
                visible: false,
            },
            FiveOfAKind => HandInfo {
                key: "Five of a Kind",
                s_chips: 120.0,
                s_mult: 12.0,
                l_chips: 35.0,
                l_mult: 3.0,
                visible: false,
            },
            StraightFlush => HandInfo {
                key: "Straight Flush",
                s_chips: 100.0,
                s_mult: 8.0,
                l_chips: 40.0,
                l_mult: 4.0,
                visible: true,
            },
            FourOfAKind => HandInfo {
                key: "Four of a Kind",
                s_chips: 60.0,
                s_mult: 7.0,
                l_chips: 30.0,
                l_mult: 3.0,
                visible: true,
            },
            FullHouse => HandInfo {
                key: "Full House",
                s_chips: 40.0,
                s_mult: 4.0,
                l_chips: 25.0,
                l_mult: 2.0,
                visible: true,
            },
            Flush => HandInfo {
                key: "Flush",
                s_chips: 35.0,
                s_mult: 4.0,
                l_chips: 15.0,
                l_mult: 2.0,
                visible: true,
            },
            Straight => HandInfo {
                key: "Straight",
                s_chips: 30.0,
                s_mult: 4.0,
                l_chips: 30.0,
                l_mult: 3.0,
                visible: true,
            },
            ThreeOfAKind => HandInfo {
                key: "Three of a Kind",
                s_chips: 30.0,
                s_mult: 3.0,
                l_chips: 20.0,
                l_mult: 2.0,
                visible: true,
            },
            TwoPair => HandInfo {
                key: "Two Pair",
                s_chips: 20.0,
                s_mult: 2.0,
                l_chips: 20.0,
                l_mult: 1.0,
                visible: true,
            },
            Pair => HandInfo {
                key: "Pair",
                s_chips: 10.0,
                s_mult: 2.0,
                l_chips: 15.0,
                l_mult: 1.0,
                visible: true,
            },
            HighCard => HandInfo {
                key: "High Card",
                s_chips: 5.0,
                s_mult: 1.0,
                l_chips: 10.0,
                l_mult: 1.0,
                visible: true,
            },
        }
    }
}

/// 一个牌型本局的进度.
#[derive(Clone, Copy, Debug)]
pub struct HandLevel {
    /// 等级. 可以降到 0, 没有上限.
    pub level: i32,
    /// 本局打出次数, 与本回合次数 (超新星等要看它们).
    pub played: u32,
    pub played_this_round: u32,
    /// 是否已显示在牌型列表里.
    pub visible: bool,
}

impl HandLevel {
    fn new(hand: PokerHand) -> Self {
        HandLevel {
            level: 1,
            played: 0,
            played_this_round: 0,
            visible: hand.info().visible,
        }
    }

    /// 本次出牌用的基础筹码.
    pub fn chips(&self, hand: PokerHand) -> f64 {
        let info = hand.info();
        (info.s_chips + info.l_chips * f64::from(self.level - 1)).max(0.0)
    }

    /// 本次出牌用的基础倍率.
    pub fn mult(&self, hand: PokerHand) -> f64 {
        let info = hand.info();
        (info.s_mult + info.l_mult * f64::from(self.level - 1)).max(1.0)
    }
}

/// 一局里 12 个牌型的等级与计数.
#[derive(Clone, Debug)]
pub struct HandTable {
    levels: [HandLevel; 12],
}

impl Default for HandTable {
    fn default() -> Self {
        Self::new()
    }
}

impl HandTable {
    pub fn new() -> Self {
        HandTable {
            levels: std::array::from_fn(|i| HandLevel::new(PokerHand::BY_PRIORITY[i])),
        }
    }

    pub fn get(&self, hand: PokerHand) -> &HandLevel {
        &self.levels[hand.index()]
    }

    pub fn get_mut(&mut self, hand: PokerHand) -> &mut HandLevel {
        &mut self.levels[hand.index()]
    }

    /// `level_up_hand`: 升若干级, 等级下限为 0. The Arm 降级时传负数.
    pub fn level_up(&mut self, hand: PokerHand, amount: i32) {
        let entry = self.get_mut(hand);
        entry.level = (entry.level + amount).max(0);
    }

    /// 新回合开始: 12 个牌型的"本回合打过几次"全部清零, 本局累计的 `played` 不动.
    ///
    /// 对应游戏 `new_round` 里那一轮 `v.played_this_round = 0`
    /// (`game/functions/state_events.lua` 的 L302-L305). 少了它, 老千小丑这类按
    /// "本回合打过同一牌型"触发的效果会一直带着前几回合的计数, 于是每一手都触发.
    pub fn reset_round(&mut self) {
        for level in &mut self.levels {
            level.played_this_round = 0;
        }
    }

    /// 打出一次: 本局计数加一, 本回合计数加一, 并把隐藏牌型变成可见.
    pub fn record_played(&mut self, hand: PokerHand) {
        let entry = self.get_mut(hand);
        entry.played += 1;
        entry.played_this_round += 1;
        entry.visible = true;
    }

    /// 本局**打得最多**的牌型, 对应游戏的 `most_played_poker_hand` (牛用它).
    ///
    /// 并列时取**最强**的那个 —— 游戏的判据是 `order` 越小越优先, 而 `order` 的顺序与
    /// 这里的 `BY_PRIORITY` 一模一样 (同花五张是 1, 高牌是 12), 所以按 `BY_PRIORITY`
    /// 遍历并保留第一个最大值就等价.
    pub fn most_played(&self) -> PokerHand {
        let mut best = PokerHand::HighCard;
        let mut best_played = 0;
        for (index, hand) in PokerHand::BY_PRIORITY.iter().enumerate() {
            let played = self.get(*hand).played;
            if index == 0 || played > best_played {
                best_played = played;
                best = *hand;
            }
        }
        best
    }
}
