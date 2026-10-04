//! 牌区里的一张牌.
//!
//! [`PlayingCard`] 是牌的身份 (花色点数加建牌序号), 这里往上加实例状态: 增强, 版本, 蜡封,
//! 卡面奖励, 以及被盲注削弱. 判定与计分要用的视图由 [`CardInstance::to_hand_card`] 给出.

use super::playing::PlayingCard;
use crate::scoring::HandCard;

/// 卡牌增强.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Enhancement {
    Bonus,
    Mult,
    Wild,
    Glass,
    Steel,
    Stone,
    Gold,
    Lucky,
}

impl Enhancement {
    /// 游戏里的内部键 (`m_bonus` 这类) 去掉前缀后的小写名.
    pub fn key(self) -> &'static str {
        match self {
            Enhancement::Bonus => "bonus",
            Enhancement::Mult => "mult",
            Enhancement::Wild => "wild",
            Enhancement::Glass => "glass",
            Enhancement::Steel => "steel",
            Enhancement::Stone => "stone",
            Enhancement::Gold => "gold",
            Enhancement::Lucky => "lucky",
        }
    }

    /// 按游戏里的内部键反查, 例如 `m_bonus` -> `Bonus`. 认不出来给 `None`.
    pub fn from_key(key: &str) -> Option<Enhancement> {
        let name = key.strip_prefix("m_")?;
        [
            Enhancement::Bonus,
            Enhancement::Mult,
            Enhancement::Wild,
            Enhancement::Glass,
            Enhancement::Steel,
            Enhancement::Stone,
            Enhancement::Gold,
            Enhancement::Lucky,
        ]
        .into_iter()
        .find(|candidate| candidate.key() == name)
    }
}

/// 蜡封.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Seal {
    Red,
    Blue,
    Gold,
    Purple,
}

impl Seal {
    pub fn key(self) -> &'static str {
        match self {
            Seal::Red => "red",
            Seal::Blue => "blue",
            Seal::Gold => "gold",
            Seal::Purple => "purple",
        }
    }
}

/// 卡牌版本. 商店里的小丑也会带这个, 所以单独放在卡牌层.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Edition {
    Foil,
    Holo,
    Polychrome,
    Negative,
}

impl Edition {
    /// 回放文件的 digest 里用的单字母标记, 见 `mods/bbreplay/replay/format.lua`.
    pub fn token(self) -> char {
        match self {
            Edition::Foil => 'f',
            Edition::Holo => 'h',
            Edition::Polychrome => 'p',
            Edition::Negative => 'n',
        }
    }
}

/// 牌区里的一张牌.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct CardInstance {
    pub card: PlayingCard,
    pub enhancement: Option<Enhancement>,
    pub edition: Option<Edition>,
    pub seal: Option<Seal>,
    /// 被当前盲注削弱. 仍参与牌型识别, 但自身计分与版本蜡封都停用.
    pub debuffed: bool,
    /// 蓝铃 (决战 Boss) 强行锁定的那张: 它在手里时**不能取消选中**, 所以每次出牌都要带上它.
    pub forced_selection: bool,
    /// 这一底注里有没有被打出去过. 柱子 (The Pillar) 靠它决定削哪些牌, 换底注时清空.
    pub played_this_ante: bool,
    /// `ability.bonus`: 卡面奖励筹码 (例如额外筹码牌).
    pub bonus: f64,
    /// `ability.perma_bonus`: 永久筹码 (徒步者之类加上的).
    pub perma_bonus: f64,
}

impl CardInstance {
    /// 一张没有修饰的牌.
    pub fn plain(card: PlayingCard) -> Self {
        CardInstance {
            card,
            enhancement: None,
            edition: None,
            seal: None,
            debuffed: false,
            forced_selection: false,
            played_this_ante: false,
            bonus: 0.0,
            perma_bonus: 0.0,
        }
    }

    pub fn is_stone(&self) -> bool {
        self.enhancement == Some(Enhancement::Stone)
    }

    pub fn is_wild(&self) -> bool {
        self.enhancement == Some(Enhancement::Wild)
    }

    /// 判定与计分用的视图.
    pub fn to_hand_card(&self) -> HandCard {
        // 强化牌在计分时各给一份东西: 奖励牌与石头牌给筹码, 倍率牌给倍率, 玻璃牌给乘倍率.
        // 这些数值都写在强化原型上 (`m_bonus` 是 30, `m_stone` 是 50, `m_mult` 是 4,
        // `m_glass` 是 2), 所以按强化现取, 不另存一份状态 —— 否则换强化时容易忘记同步.
        let (enh_bonus, mult_bonus, x_mult, h_x_mult) = match self.enhancement {
            Some(Enhancement::Bonus) => (30.0, 0.0, 0.0, 0.0),
            Some(Enhancement::Stone) => (50.0, 0.0, 0.0, 0.0),
            Some(Enhancement::Mult) => (0.0, 4.0, 0.0, 0.0),
            Some(Enhancement::Glass) => (0.0, 0.0, 2.0, 0.0),
            // 钢铁牌的 `config.h_x_mult` 是 1.5, 但要留在手里才算数.
            Some(Enhancement::Steel) => (0.0, 0.0, 0.0, 1.5),
            _ => (0.0, 0.0, 0.0, 0.0),
        };
        HandCard {
            card: self.card,
            stone: self.is_stone(),
            wild: self.is_wild(),
            gold: self.enhancement == Some(Enhancement::Gold),
            enhanced: self.enhancement.is_some(),
            debuffed: self.debuffed,
            bonus: enh_bonus + self.bonus + self.perma_bonus,
            mult_bonus,
            x_mult,
            h_x_mult,
            // 红封让这张牌再算一遍, 其余蜡封走的是回合结算那条路 (还没做).
            repetitions: if self.seal == Some(Seal::Red) { 2 } else { 1 },
            gold_seal: self.seal == Some(Seal::Gold),
            lucky: self.enhancement == Some(Enhancement::Lucky),
            edition: self.edition,
        }
    }

    /// 回放文件 digest 里的牌记号: `key` 加版本, 蜡封, 增强的后缀.
    ///
    /// 只做牌面这一层, 小丑的 `!e` / `!r` 由调用方按原型补.
    pub fn token(&self) -> String {
        let mut token = self.card.key();
        if let Some(edition) = self.edition {
            token.push('+');
            token.push(edition.token());
        }
        if let Some(seal) = self.seal {
            token.push('#');
            token.push_str(seal.key());
        }
        if let Some(enhancement) = self.enhancement {
            token.push('~');
            token.push_str(enhancement.key());
        }
        token
    }

    /// 按记号 (`C_T` 这种) 造一张普通牌, 供标准包里开出来的扑克牌用.
    ///
    /// `sort_id` 给 0: 它只在洗牌前用来定序, 而那时牌堆会被整体重排, 具体值不影响结果.
    pub fn from_key(key: &str) -> Option<CardInstance> {
        let (suit, rank) = key.split_once('_')?;
        Some(CardInstance::plain(crate::cards::PlayingCard {
            suit: crate::cards::Suit::from_code(suit.chars().next()?)?,
            rank: crate::cards::Rank::from_code(rank.chars().next()?)?,
            sort_id: 0,
        }))
    }

    /// 力量塔罗: 点数升一级, 同花色的牌换一张 (A 绕回 2, K 升到 A).
    ///
    /// 游戏那边是拿新牌原型调 `set_base`, 所以牌的 `sort_id` 保持不变 —— 它记的是"第几张牌",
    /// 与点数无关, 洗牌时的排序也继续用它.
    pub fn up_rank(&mut self) {
        self.card.rank = self.card.rank.up();
    }

    /// 改花色, 对应世界, 星星, 月亮, 太阳这几张.
    pub fn change_suit(&mut self, suit: crate::cards::Suit) {
        self.card.suit = suit;
    }

    /// 直接换点数, 对应幻灵里的占卜 (它把整手牌的点数统一成一个值).
    pub fn change_rank(&mut self, rank: crate::cards::Rank) {
        self.card.rank = rank;
    }

    /// 换上一种强化, 对应魔术师, 皇后, 教皇那批塔罗 (`mod_conv` 指向一张 `m_` 原型).
    ///
    /// 是**替换**不是叠加: 游戏那边就是拿新原型调 `set_ability`.
    pub fn set_enhancement(&mut self, enhancement: Enhancement) {
        self.enhancement = Some(enhancement);
    }
}
