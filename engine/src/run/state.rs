//! 一局的可变状态.
//!
//! 只放候选池与抽取要用到的部分, 后面的模块按需再扩. 字段名尽量与游戏里的 `G.GAME` 对应,
//! 便于对照.

use std::collections::{HashMap, HashSet};

use crate::cards::CardInstance;
use crate::data::catalog::Prototype;
use crate::rng::Rng;

use super::blind::{Blind, BlindKind, RoundEval, scaling_for_stake};
use super::flow::Phase;
use super::shop::{OpenPack, Shop};
use crate::jokers::Joker;
use crate::scoring::{HandTable, PokerHand};

/// 按赌注与挑战来的一局修饰, 只放货架抽取读到的几项.
#[derive(Clone, Copy, Debug, Default)]
pub struct Modifiers {
    /// 赌注 4 起: 商店里的小丑可能带永恒.
    pub enable_eternals_in_shop: bool,
    /// 赌注 7 起: 可能带易腐.
    pub enable_perishables_in_shop: bool,
    /// 赌注 8 起: 可能带租赁.
    pub enable_rentals_in_shop: bool,
}

impl Modifiers {
    /// 按赌注等级 (1 起) 套上 `Game:start_run` 里那几条 `stake >= N` 规则.
    pub fn for_stake(stake: i64) -> Self {
        Modifiers {
            enable_eternals_in_shop: stake >= 4,
            enable_perishables_in_shop: stake >= 7,
            enable_rentals_in_shop: stake >= 8,
        }
    }
}

/// 一局里会被抽取逻辑读到的状态.
#[derive(Clone, Debug)]
pub struct RunState {
    pub rng: Rng,
    /// 当前底注, 对应 `G.GAME.round_resets.ante`. 池键末尾会拼上它.
    pub ante: i64,
    /// 赌注等级, 1 起.
    pub stake: i64,
    pub modifiers: Modifiers,
    /// 本局是否已经给过第一次商店的基础小丑包, 对应 `G.GAME.first_shop_buffoon`.
    pub first_shop_buffoon: bool,
    /// 本局已兑换的优惠券, 对应 `G.GAME.used_vouchers`.
    pub used_vouchers: HashSet<String>,
    /// 城堡那一回合盯的花色, 对应 `G.GAME.current_round.castle_card.suit`.
    ///
    /// 游戏在**每回合开始**都会掷一次 (`reset_castle_card`, 与偶像 / 邮件 / 上古一起, 四个都无条件跑),
    /// 键是 `cas{底注}`. 它虽然只有城堡自己用, 但**它的键是这四个里最后一个** ——
    /// 全局随机序列的位置由最后一次 `pseudorandom` 决定, 所以这一掷也会影响到别处.
    pub castle_suit: Option<crate::cards::Suit>,
    /// 上古小丑那一回合盯的花色, 对应 `G.GAME.current_round.ancient_card.suit`.
    /// 与城堡一样在每回合开始掷 (`reset_ancient_card`, 键 `anc{底注}`), 而且**要避开上一次那个花色**.
    pub ancient_suit: Option<crate::cards::Suit>,
    /// 邮件回扣那一回合盯的点数, 对应 `G.GAME.current_round.mail_card.id`.
    /// 与城堡 / 上古一样每回合开始掷 (键 `mail{底注}`).
    pub mail_rank: Option<crate::cards::Rank>,
    /// 爱豆那一回合盯的**具体一张牌** (花色 + 点数), 对应 `G.GAME.current_round.idol_card`.
    /// 与城堡的花色、邮件的点数同一套路, 键是 `idol{底注}`.
    pub idol_card: Option<(crate::cards::Suit, crate::cards::Rank)>,
    /// 上一次用掉的塔罗或行星 (愚者要复制它), 对应 `G.GAME.last_tarot_planet`.
    pub last_tarot_planet: Option<String>,
    /// 本局已出现过的小丑, 对应 `G.GAME.used_jokers`.
    pub used_jokers: HashSet<String>,
    /// 被禁用的原型键, 对应 `G.GAME.banned_keys`.
    pub banned_keys: HashSet<String>,
    /// 池子开关, 对应 `G.GAME.pool_flags`.
    pub pool_flags: HashSet<String>,
    /// 当前商店在售的优惠券键, 对应 `G.shop_vouchers.cards`.
    pub shop_vouchers: Vec<String>,
    /// 已经拿到手的标签, 对应 `G.GAME.tags`.
    pub tags: Vec<String>,
    /// 优惠券标签额外摆出来的那张券的键.
    pub extra_voucher_key: Option<String>,
    /// 这一局跳过过几个盲注, 对应 `G.GAME.skips`.
    pub skips: i64,
    /// 跳过小盲注 / 大盲注能拿到的标签, 对应 `round_resets.blind_tags`.
    ///
    /// 底注之内不换 —— 只有开局与底注提升时才重抽, 所以这两个键在一底里是固定的.
    pub blind_tags: [Option<String>; 2],
    /// 各牌型本局打出次数, 星球牌的 `softlock` 要看它.
    pub hands_played: HashMap<String, i64>,
    /// 存档进度: 原型键到 `"u"/"d"/"a"` 标记, 与回放文件 `snapshot.uda` 同格式.
    pub uda: HashMap<String, String>,

    /// 当前阶段.
    pub phase: Phase,
    /// 牌堆: 还没抽到手上的牌. 取牌从末尾拿.
    pub deck: Vec<CardInstance>,
    /// 手牌, 始终按牌面大小降序.
    pub hand: Vec<CardInstance>,
    /// 弃牌堆: 本回合弃掉与打出的牌.
    pub discard_pile: Vec<CardInstance>,
    /// 出牌区: 本次打出的牌, 计分期间停在这里.
    pub play_area: Vec<CardInstance>,
    /// 本回合剩余出牌次数.
    pub hands_left: i64,
    /// 本回合剩余弃牌次数.
    pub discards_left: i64,
    /// 本盲注已累计的得分.
    pub chips: f64,

    /// 当前现金, 对应 `G.GAME.dollars`.
    pub dollars: f64,
    /// 本底注内的回合序号: 1 小盲注, 2 大盲注, 3 Boss. 对应 `G.GAME.round`.
    pub round: i64,
    /// 摆在面前还没打的盲注, 对应 `G.GAME.blind_on_deck`.
    pub blind_on_deck: BlindKind,
    /// 这一底已经抽好的 Boss 原型键, 对应 `round_resets.blind_choices.Boss`.
    pub boss_key: Option<String>,
    /// 所有概率的倍数 (对应 `G.GAME.probabilities`: 七上八下那张小丑拿到后全部乘二).
    /// 概率判定一律用 `scale / odds`, 不要写死成 `1 / odds`.
    pub probability_scale: f64,
    /// 这一底已经重掷过 Boss 了吗 (导演剪辑版每底只能用一次).
    pub boss_rerolled: bool,
    /// 每个 Boss 这一局被抽中过几次, 对应 `G.GAME.bosses_used`. 抽签只在使用次数最少的那批里取.
    pub bosses_used: HashMap<String, i64>,
    /// 通关底注, 原版是 8.
    pub win_ante: i64,
    /// 本回合已用掉的弃牌次数.
    pub discards_used: i64,
    /// 本回合**打出过的牌型**, 按打出的先后排.
    ///
    /// 眼 (不能打重复牌型) 与嘴 (只能打一种牌型) 要看它; 蛇也要靠它判断"这一回合已经出过牌了没有"
    /// (它只对开局的发牌之外那几次抽牌生效).
    pub round_hand_types: Vec<crate::scoring::PokerHand>,
    /// 本回合面对的盲注.
    pub blind: Option<Blind>,
    /// 本回合的结算栏, 领过之后清空.
    pub round_eval: Option<RoundEval>,
    /// 难度档 (赌注 3 起为 2, 6 起为 3), 决定盲注目标查哪张表.
    pub scaling: i64,
    /// 牌组的 `ante_scaling`. 等离子牌组是 2, 所以它的盲注目标是别人的两倍.
    pub ante_scaling: f64,
    /// 小盲注是否不发固定奖金 (赌注 2 起).
    pub no_blind_reward: bool,
    /// 每剩一次出牌给多少钱, 默认 1. 绿色牌组会改成 2.
    pub money_per_hand: f64,
    /// 每剩一次弃牌给多少钱, 默认 0.
    pub money_per_discard: f64,
    /// 利息单价与本金上限.
    pub interest_rate: f64,
    pub interest_cap: f64,
    /// 商店的折扣百分比, 对应 `G.GAME.discount_percent`.
    pub discount_percent: f64,
    /// 商店多摆几件小丑 (`change_shop_size`), 库存过剩那两张券各加一.
    pub shop_size_bonus: usize,
    /// 商店各类商品的权重, 对应 `G.GAME.*_rate`. 券会改其中几项 (塔罗商人 / 星球商人 /
    /// 魔术 / 打磨那几对), 默认值与 `ShopRates::default` 一致.
    pub joker_rate: f64,
    pub tarot_rate: f64,
    pub planet_rate: f64,
    pub playing_card_rate: f64,
    pub spectral_rate: f64,
    /// 商店出版本的频率, 对应 `G.GAME.edition_rate`, 默认 1.
    pub edition_rate: f64,
    /// 商店涨价计数, 对应 `G.GAME.inflation`, 买过一次之后加一.
    pub inflation: f64,
    /// 这一底的商店重抽基准价, 对应 `round_resets.reroll_cost`, 默认 5.
    pub reroll_base_cost: f64,
    /// 本回合已经重抽过几次, 每抽一次涨价一元.
    pub rerolls: i64,
    /// 还剩几次免费重抽, 由混沌小丑在回合开始时给.
    pub free_rerolls: i64,
    /// 每回合能出几次牌, 对应牌组的 `config.hands` 加基础值. 默认 4, 蓝色牌组是 5.
    pub hands_per_round: i64,
    /// 每回合能弃几次牌. 默认 3, 赌注 5 起只剩 2.
    pub discards_per_round: i64,
    /// 手牌上限的临时扣减, 由镣铐 (The Manacle) 之类的 Boss 给.
    pub hand_size_sub: i64,
    /// 手牌上限的永久加成, 由杂耍标签这类给.
    pub hand_size_bonus: i64,
    /// 这一轮商店的重抽是否免费 (D6 标签给的).
    pub free_reroll: bool,
    /// 这一轮商店里的东西是否免费 (代金券标签给的).
    pub shop_free: bool,
    /// 允许欠到多少才不能再买, 对应 `G.GAME.bankrupt_at`, 默认 0 (也就是一分钱都不能欠).
    /// 信用卡小丑会把它减 20.
    pub bankrupt_at: f64,
    /// 本局用掉过几张行星牌 (卫星那类小丑要看).
    pub planets_used: usize,
    /// 本赛局一共用过几张**塔罗** (`G.GAME.consumeable_usage_total.tarot`). 占卜师要看它,
    /// 而且它算的是**全局**数量 —— 包括在小丑进队之前用的那些.
    pub tarots_used: usize,
    /// 开局那副牌有多少张, 对应 `G.GAME.starting_deck_size`.
    ///
    /// 侵蚀那类"比开局少了几张"的小丑要比它, 所以建堆之后就记下来.
    pub starting_deck_size: usize,
    /// 上一手打出的牌型, 供蓝封在回合末决定生成哪张行星牌.
    pub last_hand_played: Option<PokerHand>,
    /// 小丑槽位上限, 默认 5.
    pub joker_slots: usize,
    /// 消耗牌槽位上限, 默认 2.
    pub consumable_slots: usize,
    /// 持有的小丑, 按从左到右的顺序. 成长值就存在这里, 所以它跨手牌保留.
    pub jokers: Vec<Joker>,
    /// 持有的消耗牌 (塔罗 / 行星 / 幻灵). 带版本 —— 珀克奥会往上加负片.
    pub consumables: Vec<super::consumable::Consumable>,
    /// 买下并开好的补充包, 挑完就清空. 对应游戏里的 `G.pack_cards`.
    pub open_pack: Option<OpenPack>,
    /// 当前这一底的货架, 离开商店时清空.
    pub shop: Option<Shop>,
    /// 这台机器上的牌型表: 各牌型的等级与已打出次数. 行星牌升的就是它.
    pub hands: HandTable,
    /// 本局是否已经通关.
    pub won: bool,
}

impl RunState {
    /// 开一局. `ante` 与 `stake` 从 1 起, 与游戏的开局一致.
    ///
    /// 起始次数来自 `get_starting_params` (出牌 4, 弃牌 3), 再套上 `Game:start_run` 里的赌注规则:
    /// 赌注 5 起弃牌次数减一, 所以黄金赌注 (8) 是 2 次.
    pub fn new(seed: &str, stake: i64) -> Self {
        let discards = if stake >= 5 { 2 } else { 3 };
        RunState {
            rng: Rng::new(seed),
            ante: 1,
            stake,
            modifiers: Modifiers::for_stake(stake),
            first_shop_buffoon: false,
            used_vouchers: HashSet::new(),
            castle_suit: None,
            ancient_suit: None,
            mail_rank: None,
            idol_card: None,
            last_tarot_planet: None,
            used_jokers: HashSet::new(),
            banned_keys: HashSet::new(),
            pool_flags: HashSet::new(),
            shop_vouchers: Vec::new(),
            tags: Vec::new(),
            extra_voucher_key: None,
            skips: 0,
            blind_tags: [None, None],
            hands_played: HashMap::new(),
            uda: HashMap::new(),
            phase: Phase::BlindSelect,
            deck: Vec::new(),
            hand: Vec::new(),
            discard_pile: Vec::new(),
            play_area: Vec::new(),
            hands_left: 4,
            discards_left: discards,
            chips: 0.0,
            dollars: 4.0,
            round: 0,
            blind_on_deck: BlindKind::Small,
            boss_key: None,
            probability_scale: 1.0,
            boss_rerolled: false,
            bosses_used: HashMap::new(),
            win_ante: 8,
            discards_used: 0,
            round_hand_types: Vec::new(),
            blind: None,
            round_eval: None,
            scaling: scaling_for_stake(stake),
            ante_scaling: 1.0,
            no_blind_reward: stake >= 2,
            money_per_hand: 1.0,
            money_per_discard: 0.0,
            interest_rate: 1.0,
            interest_cap: 25.0,
            discount_percent: 0.0,
            shop_size_bonus: 0,
            joker_rate: 20.0,
            tarot_rate: 4.0,
            planet_rate: 4.0,
            playing_card_rate: 0.0,
            spectral_rate: 0.0,
            edition_rate: 1.0,
            inflation: 0.0,
            reroll_base_cost: 5.0,
            rerolls: 0,
            free_rerolls: 0,
            free_reroll: false,
            shop_free: false,
            bankrupt_at: 0.0,
            hands_per_round: 4,
            discards_per_round: discards,
            hand_size_sub: 0,
            hand_size_bonus: 0,
            joker_slots: 5,
            consumable_slots: 2,
            jokers: Vec::new(),
            consumables: Vec::new(),
            open_pack: None,
            shop: None,
            planets_used: 0,
            tarots_used: 0,
            starting_deck_size: 0,
            last_hand_played: None,
            hands: HandTable::new(),
            won: false,
        }
    }

    /// 套用牌组对盲注目标的缩放. 等离子牌组是 2, 标准牌组是 1.
    /// 这一局**还活着**的牌里有没有带某种强化的 (`enhancement_gate` 要问的就是这个).
    ///
    /// 口径与 `get_current_pool` 一致: 它遍历的是 `G.playing_cards`, 也就是牌堆 + 手牌 +
    /// 弃牌堆 + 刚打出去的那几张.
    pub fn has_enhancement(&self, enhancement_key: &str) -> bool {
        let Some(wanted) = crate::cards::Enhancement::from_key(enhancement_key) else {
            return false;
        };
        self.deck
            .iter()
            .chain(self.hand.iter())
            .chain(self.discard_pile.iter())
            .any(|card| card.enhancement == Some(wanted))
    }

    /// 这个牌型本局打过没有 (行星的 `softlock` 要问的就是这个).
    ///
    /// `hand_type` 传的是游戏那边的名字 (`"Five of a Kind"`), 认不出来就当没打过.
    pub fn hand_played_before(&self, hand_type: &str) -> bool {
        use crate::scoring::PokerHand;
        let hand = match hand_type {
            "Flush Five" => PokerHand::FlushFive,
            "Flush House" => PokerHand::FlushHouse,
            "Five of a Kind" => PokerHand::FiveOfAKind,
            "Straight Flush" => PokerHand::StraightFlush,
            "Four of a Kind" => PokerHand::FourOfAKind,
            "Full House" => PokerHand::FullHouse,
            "Flush" => PokerHand::Flush,
            "Straight" => PokerHand::Straight,
            "Three of a Kind" => PokerHand::ThreeOfAKind,
            "Two Pair" => PokerHand::TwoPair,
            "Pair" => PokerHand::Pair,
            "High Card" => PokerHand::HighCard,
            _ => return false,
        };
        self.hands.get(hand).played > 0
    }

    pub fn with_deck_scaling(mut self, ante_scaling: f64) -> Self {
        self.ante_scaling = ante_scaling;
        self
    }

    /// 记一份存档进度标记, 格式同 `snapshot.uda` 的值 (例如 `"ud"`).
    pub fn with_uda(mut self, uda: HashMap<String, String>) -> Self {
        self.uda = uda;
        self
    }

    /// 按牌组的 `config` 调参数.
    ///
    /// 目前认两项: `ante_scaling` (等离子牌组的盲注目标是别人的两倍) 与 `hands`
    /// (蓝色牌组多给一次出牌). 认不出来的牌子原样返回, 不报错 —— 牌组只会多给好处,
    /// 漏认一项会让对拍失败, 但不会让引擎算错别的东西.
    pub fn with_deck(mut self, deck_key: &str) -> Self {
        let config = crate::data::catalog::Catalog::get()
            .record(deck_key)
            .and_then(|proto| proto.config.clone())
            .unwrap_or(crate::data::json::Json::Null);
        if let Some(scaling) = config.get("ante_scaling").and_then(crate::data::json::Json::as_f64)
        {
            self.ante_scaling = scaling;
        }
        if let Some(hands) = config.get("hands").and_then(crate::data::json::Json::as_f64) {
            self.hands_per_round += hands as i64;
        }
        if let Some(discards) = config
            .get("discards")
            .and_then(crate::data::json::Json::as_f64)
        {
            self.discards_per_round += discards as i64;
        }
        self
    }

    /// 原型此刻是否"解锁".
    ///
    /// 照抄 `replay/snapshot.lua` 的恢复规则与 `get_current_pool` 的判断:
    /// 存档里没有这一项时用原型自己的初始值; 存档里有标记但没有 `u` 时, 只有原型本来就写了
    /// `unlocked` 字段才会被明确置为未解锁, 否则保持"没有这个字段"的状态. 而池子判的是
    /// `v.unlocked ~= false`, 所以"没有字段"也算通过.
    pub fn unlocked(&self, proto: &Prototype) -> bool {
        match self.uda.get(&proto.id) {
            Some(flags) => {
                let flagged = flags.contains('u');
                if flagged || proto.initially_unlocked.is_some() {
                    flagged
                } else {
                    true
                }
            }
            None => proto.unlocked_default(),
        }
    }

    /// 原型此刻是否"已发现".
    pub fn discovered(&self, proto: &Prototype) -> bool {
        self.uda
            .get(&proto.id)
            .map(|flags| flags.contains('d'))
            .unwrap_or(false)
    }
}
