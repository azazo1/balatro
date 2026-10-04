//! 扑克牌.
//!
//! 一张牌的身份只有花色与点数; 增强, 蜡封, 版本, 成长值这些是"实例状态", 后面单独加.
//!
//! 牌的创建顺序决定 `sort_id`, 而 `CardArea:shuffle` 每轮都会先按 `sort_id` 排序再洗,
//! 所以 [`standard_deck`] 给出的顺序必须与游戏的建牌顺序一致, 否则同一个种子洗出来的牌不同.

use std::fmt;

/// 花色.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub enum Suit {
    Clubs,
    Diamonds,
    Hearts,
    Spades,
}

/// 点数.
///
/// 声明顺序是字符码顺序而不是点数大小顺序: 游戏的建牌顺序按 `花色字符 + 点数字符` 的字符串排序,
/// 字符码里 `2` < `9` < `A` < `J` < `K` < `Q` < `T`, 所以 `T` 排在最后.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub enum Rank {
    Two,
    Three,
    Four,
    Five,
    Six,
    Seven,
    Eight,
    Nine,
    Ace,
    Jack,
    King,
    Queen,
    Ten,
}

impl Suit {
    /// 花色字符, 与游戏里 `P_CARDS` 的 key 首字符相同.
    pub fn code(self) -> char {
        match self {
            Suit::Clubs => 'C',
            Suit::Diamonds => 'D',
            Suit::Hearts => 'H',
            Suit::Spades => 'S',
        }
    }

    /// 所有花色, 按字符码升序.
    pub const ALL: [Suit; 4] = [Suit::Clubs, Suit::Diamonds, Suit::Hearts, Suit::Spades];

    /// 按花色字符反查 (`C` -> 梅花). 认不出来给 `None`.
    pub fn from_code(code: char) -> Option<Suit> {
        Suit::ALL.into_iter().find(|suit| suit.code() == code)
    }

    /// `base.suit_nominal`: 同点数时区分花色的那一项.
    pub fn suit_nominal(self) -> f64 {
        match self {
            Suit::Diamonds => 0.01,
            Suit::Clubs => 0.02,
            Suit::Hearts => 0.03,
            Suit::Spades => 0.04,
        }
    }

    /// `base.suit_nominal_original`, 只在按花色排序 (`mod = 'suit'`) 时才起作用.
    pub fn suit_nominal_original(self) -> f64 {
        match self {
            Suit::Diamonds => 0.001,
            Suit::Clubs => 0.002,
            Suit::Hearts => 0.003,
            Suit::Spades => 0.004,
        }
    }

    /// 红桃与方片为红. 模糊小丑按这个把两色合并.
    pub fn is_red(self) -> bool {
        matches!(self, Suit::Hearts | Suit::Diamonds)
    }
}

impl Rank {
    /// 点数单字符, 十点写作 `T`.
    pub fn code(self) -> char {
        match self {
            Rank::Two => '2',
            Rank::Three => '3',
            Rank::Four => '4',
            Rank::Five => '5',
            Rank::Six => '6',
            Rank::Seven => '7',
            Rank::Eight => '8',
            Rank::Nine => '9',
            Rank::Ten => 'T',
            Rank::Jack => 'J',
            Rank::Queen => 'Q',
            Rank::King => 'K',
            Rank::Ace => 'A',
        }
    }

    /// 按点数单字符反查 (`T` -> 十点). 认不出来给 `None`.
    pub fn from_code(code: char) -> Option<Rank> {
        Rank::ALL.into_iter().find(|rank| rank.code() == code)
    }

    /// 点数序号, 对应游戏里的 `Card:get_id()`: A 是 14, J/Q/K 是 11/12/13, 其余按面值.
    ///
    /// 奇数托德那类"看点数奇偶"的小丑就靠它. 注意它与 `nominal` 不是一回事: `nominal`
    /// 是算筹码用的 (人头牌都是 10), 而这里是牌的身份.
    pub fn pip(self) -> u8 {
        match self {
            Rank::Ace => 14,
            Rank::Two => 2,
            Rank::Three => 3,
            Rank::Four => 4,
            Rank::Five => 5,
            Rank::Six => 6,
            Rank::Seven => 7,
            Rank::Eight => 8,
            Rank::Nine => 9,
            Rank::Ten => 10,
            Rank::Jack => 11,
            Rank::Queen => 12,
            Rank::King => 13,
        }
    }

    /// 所有点数, 按字符码升序, 也就是游戏的建牌顺序.
    pub const ALL: [Rank; 13] = [
        Rank::Two,
        Rank::Three,
        Rank::Four,
        Rank::Five,
        Rank::Six,
        Rank::Seven,
        Rank::Eight,
        Rank::Nine,
        Rank::Ace,
        Rank::Jack,
        Rank::King,
        Rank::Queen,
        Rank::Ten,
    ];

    /// `Card:get_id()` 的点数部分: `2` 到 `10` 是本身, `J/Q/K` 为 `11/12/13`, `A` 为 `14`.
    pub fn id(self) -> u8 {
        match self {
            Rank::Two => 2,
            Rank::Three => 3,
            Rank::Four => 4,
            Rank::Five => 5,
            Rank::Six => 6,
            Rank::Seven => 7,
            Rank::Eight => 8,
            Rank::Nine => 9,
            Rank::Ten => 10,
            Rank::Jack => 11,
            Rank::Queen => 12,
            Rank::King => 13,
            Rank::Ace => 14,
        }
    }

    /// 牌面点数, 十到 K 记为 10, A 记为 11. 与游戏 `Card:set_base` 里的 `base.nominal` 一致.
    pub fn nominal(self) -> f64 {
        match self {
            Rank::Two => 2.0,
            Rank::Three => 3.0,
            Rank::Four => 4.0,
            Rank::Five => 5.0,
            Rank::Six => 6.0,
            Rank::Seven => 7.0,
            Rank::Eight => 8.0,
            Rank::Nine => 9.0,
            Rank::Ten | Rank::Jack | Rank::Queen | Rank::King => 10.0,
            Rank::Ace => 11.0,
        }
    }

    /// `base.face_nominal`. 人头牌有小量加成, A 也算在里, 这是手牌排序里 K > Q > J 的来源.
    pub fn face_nominal(self) -> f64 {
        match self {
            Rank::Jack => 0.1,
            Rank::Queen => 0.2,
            Rank::King => 0.3,
            Rank::Ace => 0.4,
            _ => 0.0,
        }
    }

    /// 是不是人头牌.
    pub fn is_face(self) -> bool {
        matches!(self, Rank::Jack | Rank::Queen | Rank::King)
    }

    /// 点数升一级, 供力量塔罗用: `2 -> 3 -> ... -> 9 -> T -> J -> Q -> K -> A -> 2`.
    ///
    /// **不能**用枚举的声明顺序推: 那是按字符码排的 (`2..9, A, J, K, Q, T`), 与点数顺序
    /// 并不一致. 对应 `card.lua` 里 Strength 那一段的
    /// `card.base.id == 14 and 2 or math.min(card.base.id+1, 14)`.
    pub fn up(self) -> Rank {
        match self {
            Rank::Two => Rank::Three,
            Rank::Three => Rank::Four,
            Rank::Four => Rank::Five,
            Rank::Five => Rank::Six,
            Rank::Six => Rank::Seven,
            Rank::Seven => Rank::Eight,
            Rank::Eight => Rank::Nine,
            Rank::Nine => Rank::Ten,
            Rank::Ten => Rank::Jack,
            Rank::Jack => Rank::Queen,
            Rank::Queen => Rank::King,
            Rank::King => Rank::Ace,
            Rank::Ace => Rank::Two,
        }
    }
}

/// 一张扑克牌的身份.
///
/// `sort_id` 是建牌时的全局序号, 对应游戏的 `Card.sort_id`: 洗牌前按它排序, 牌面大小完全相同时
/// 也靠它定序.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub struct PlayingCard {
    pub suit: Suit,
    pub rank: Rank,
    pub sort_id: u32,
}

impl PlayingCard {
    /// 游戏里 `P_CARDS` 的 key, 例如 `C_T`.
    pub fn key(self) -> String {
        format!("{}_{}", self.suit.code(), self.rank.code())
    }

    /// `Card:get_nominal(mod=nil)`: 手牌默认按它降序排列.
    ///
    /// 游戏里最后一项是 `0.000001 * (1 - Card.ID/1603301)`, `Card.ID` 来自全局 Node 计数器,
    /// 夹着界面元素一起增长, 无法独立复刻. 这里用建牌序号代替: 两者的相对大小一致, 而这一项
    /// 只在点数, 花色, 人头加成全都相同时才参与比较, 所以不影响这一层的结论.
    pub fn nominal(self) -> f64 {
        self.rank.nominal()
            + self.suit.suit_nominal()
            + self.suit.suit_nominal_original() * 0.0001
            + self.rank.face_nominal()
            + 0.000001 * self.unique_val()
    }

    fn unique_val(self) -> f64 {
        1.0 - f64::from(self.sort_id) / 1603301.0
    }
}

impl fmt::Display for PlayingCard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.key())
    }
}

/// 标准 52 张, 顺序即游戏的建牌顺序 (`sort_id` 升序): 先花色, 再点数, 都按字符码.
pub fn standard_deck() -> Vec<PlayingCard> {
    let mut deck = Vec::with_capacity(52);
    let mut sort_id = 1;
    for suit in Suit::ALL {
        for rank in Rank::ALL {
            deck.push(PlayingCard {
                suit,
                rank,
                sort_id,
            });
            sort_id += 1;
        }
    }
    deck
}

/// 按 `sort_id` 排序, 对应 `pseudoshuffle` 开头那一次 `table.sort`.
///
/// 牌本来就在这个顺序上时是空操作, 洗过一次之后才起作用, 所以每次洗牌之前都要调一次.
pub fn sort_by_sort_id(deck: &mut [PlayingCard]) {
    deck.sort_unstable_by_key(|c| c.sort_id);
}

/// 按牌面大小降序排列, 对应 `CardArea:sort('desc')`.
///
/// 手牌默认就是这个顺序 (`CardArea:init` 里 `config.sort or 'desc'`), 而 `draw_card` 每抽一张
/// 都会排一次, 所以发完牌的结果与"抽完再排一次"相同.
pub fn sort_by_nominal_desc(deck: &mut [PlayingCard]) {
    deck.sort_by(|a, b| b.nominal().total_cmp(&a.nominal()));
}
