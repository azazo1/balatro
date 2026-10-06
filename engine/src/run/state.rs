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

/// 手牌这一区的排序方式, 对应 `CardArea:sort` 支持的那两种.
///
/// 游戏那边存的是个字符串 (`'desc'` / `'suit desc'`), 这里只列真正会用到的两种 ——
/// 手牌区只有"按点数"与"按花色"两个按钮能改它.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HandSort {
    /// `desc`: 按 `get_nominal()` 降序 (默认).
    Value,
    /// `suit desc`: 按 `get_nominal('suit')` 降序, 也就是先看花色再看点数.
    Suit,
}

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
    /// 本局是否已经**出现过商店**, 也就是 `G.shop_jokers` 是否已经被建出来过.
    ///
    /// 它是给摘要用的, 不是一个游戏机制: 游戏的 `G.UIDEF.shop()` 建出 `G.shop_jokers` /
    /// `shop_vouchers` / `shop_booster` 之后**再没有把它们置回 nil**, 于是摘要里那三项
    /// (`shop` / `vouchers` / `packs`) 从第一次进商店起就一直有, 只是不再逛商店时是空的;
    /// 而第一次进商店**之前**那三项整段不出现.
    ///
    /// 这一点是反向对拍查出来的: 引擎原来不管在哪一阶段都把这三项写成空值, 于是回放第一步
    /// (还没进过商店) 就被游戏判成"状态不一致". 见 `digest()` 里的说明.
    pub shop_seen: bool,
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
    /// **这一底的券已经用掉了** —— 买下之后那一格就空着, 直到下个底注换新.
    ///
    /// 单看 `shop_vouchers` 空不空分不出两种情形: "这一底还没摆券" 与 "券已经被买走".
    /// 补丁版通过普通券的 spawn 标记区分, 这里用标志表达下一次铺货是否应生成普通券.
    pub voucher_spent: bool,
    /// 已经拿到手的标签, 对应 `G.GAME.tags`.
    pub tags: Vec<String>,
    /// 待铺货的优惠券标签键列表, 含 Double 标签产生的多个实例.
    pub extra_voucher_keys: Vec<String>,
    /// 这一局跳过过几个盲注, 对应 `G.GAME.skips`.
    pub skips: i64,
    /// 本局累计已出牌次数, 对应 `G.GAME.hands_played`.
    pub total_hands_played: i64,
    /// 成功回合累计剩余弃牌次数, 对应 `G.GAME.unused_discards`.
    pub unused_discards: i64,
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
    /// 这一局用的是哪副牌组 (`b_plasma` 这种), 开局时由 [`RunState::with_deck`] 记下.
    ///
    /// 有几个牌组的效果**不是开局那一次就能做完的** —— 例如字谜牌组是"打赢 Boss 时双倍标签",
    /// 那要等到回合结算. 所以键本身要留着, 不能只把 `config` 读出来就丢掉.
    pub deck_key: String,
    /// 牌组原型的 `config`, 与 [`RunState::deck_key`] 一起记.
    ///
    /// 留原始那一份而不是把每项都摊成字段, 是因为有几个牌组的效果只在**建堆**那一次用
    /// (无面牌删掉 K/Q/J, 错乱牌组重掷点数花色), 摊成字段反而多出一批"建完堆就没人再看"的状态.
    pub deck_config: crate::data::json::Json,
    /// 绿色牌组的"没有利息". 对应 `G.GAME.modifiers.no_interest`, 默认假.
    pub no_interest: bool,
    /// 手牌这一区当前的排序方式, 对应 `G.hand.config.sort`.
    ///
    /// 它是**长期设置**, 不是一次性动作: 右上角那两个按钮 (`sort_hand_value` / `sort_hand_suit`)
    /// 会把它改掉并排一次, 而之后**每次发牌**都照它排 —— 游戏里 `draw_card` 结尾那句
    /// `to:sort()` 不带参数, 于是 `CardArea:sort` 沿用 `config.sort`.
    ///
    /// 少了这一项, 按过一次"按花色排"之后引擎仍然按点数排: 手上的牌一模一样, 只是顺序不同,
    /// 而顺序本身是状态 (出牌与弃牌都按下标).
    pub hand_sort: HandSort,
    /// 下一次用**灵质**要永久减掉多少手牌上限, 对应 `G.GAME.ecto_minus`.
    ///
    /// 它从 1 起, **每用一次加一** —— 所以第一次减 1 张, 第二次减 2 张, 第三次减 3 张,
    /// 累计是 1, 3, 6... 而不是每次都减 1. 这是原版灵质真正的代价, 减出来的量永久保留.
    pub ecto_minus: i64,
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
    pub blind_hands_sub: i64,
    pub blind_discards_sub: i64,
    pub heart_chosen_sort_id: Option<u32>,
    pub heart_prepped: bool,
    /// 手牌上限的永久加成, 由牌组, 优惠券与小丑给.
    pub hand_size_bonus: i64,
    /// 杂耍标签给当前盲注的临时手牌上限, 成功结算时清零.
    pub temporary_hand_size_bonus: i64,
    /// 这一轮商店的重抽是否免费 (D6 标签给的).
    pub free_reroll: bool,
    /// 这一轮商店里的东西是否免费 (代金券标签给的).
    pub shop_free: bool,
    /// 允许欠到多少才不能再买, 对应 `G.GAME.bankrupt_at`, 默认 0 (也就是一分钱都不能欠).
    /// 信用卡小丑会把它减 20.
    pub bankrupt_at: f64,
    /// 本局用掉过几张行星牌 (卫星那类小丑要看).
    pub planets_used: usize,
    /// 卫星只计不同的行星原型, 与星座的总使用次数分开.
    pub unique_planets_used: HashSet<String>,
    /// 本赛局一共用过几张**塔罗** (`G.GAME.consumeable_usage_total.tarot`). 占卜师要看它,
    /// 而且它算的是**全局**数量 —— 包括在小丑进队之前用的那些.
    pub tarots_used: usize,
    /// 开局那副牌有多少张, 对应 `G.GAME.starting_deck_size`.
    ///
    /// 侵蚀那类"比开局少了几张"的小丑要比它, 所以建堆之后就记下来.
    pub starting_deck_size: usize,
    /// 建牌序号的计数器, 对应游戏里那个全局的 `G.sort_id`.
    ///
    /// 每造一张牌就加一 (`next_sort_id`), 所以它既给洗牌前的排序用, 也给手牌排序当兜底比较项.
    /// **必须单调递增**: 详见 `RunState::next_sort_id` 的说明.
    pub next_card_id: u32,
    /// 上一手打出的牌型, 供蓝封在回合末决定生成哪张行星牌.
    pub last_hand_played: Option<PokerHand>,
    /// 小丑槽位的**基数**: 初始 5, 再加券与卡牌给的加成. 默认 5.
    ///
    /// 它不是"还能放几个"的答案 —— 负片小丑会让槽位上限**加一**
    /// (游戏里 `Card:add_to_deck` 改的就是 `G.jokers.config.card_limit`),
    /// 所以算上限一律走 `joker_capacity()`, 别直接读这个字段.
    /// 名字上把"基数"写出来, 就是为了让每个读它的地方都得想一下该用哪一个.
    pub base_joker_slots: usize,
    /// 消耗牌槽位的基数 (同上, 负片消耗牌也让上限加一).
    pub base_consumable_slots: usize,
    /// 持有的小丑, 按从左到右的顺序. 成长值就存在这里, 所以它跨手牌保留.
    pub jokers: Vec<Joker>,
    /// 持有的消耗牌 (塔罗 / 行星 / 幻灵). 带版本 —— 珀克奥会往上加负片.
    pub consumables: Vec<super::consumable::Consumable>,
    /// 买下并开好的补充包, 挑完就清空. 对应游戏里的 `G.pack_cards`.
    pub open_pack: Option<OpenPack>,
    /// 开包前所在的阶段. 标签包应返回选盲注, 商店包返回商店.
    pub pack_return_phase: Phase,
    /// 当前这一底的货架, 离开商店时清空.
    pub shop: Option<Shop>,
    /// 这台机器上的牌型表: 各牌型的等级与已打出次数. 行星牌升的就是它.
    pub hands: HandTable,
    /// 本局是否已经通关.
    pub won: bool,
    /// 现在是不是"正在打某个盲注" —— 用它可以问"这一刻还有没有生效的盲注".
    ///
    /// 摆盲注时置真, 这一回合打完置假. 与游戏里的对应关系是: **盲注在被打赢的那一刻就被清空了** ——
    /// `Blind:defeat()` 的收尾是 `self:set_blind(nil, nil, true)`, 而 `reset` 传的是 `nil` (假),
    /// 于是那一支会把 `name` 置成空串, `chips` 归零 (`game/blind.lua`). 它由房回合结算那一步调用
    /// (`state_events.lua` 里 `G.GAME.blind:defeat()`).
    ///
    /// 于是"回合之间 (商店 / 开包) 没有生效的盲注"这件事, 在游戏里是靠**盲注被清空**体现的,
    /// 而不是靠某个标志. 引擎这边保留盲注对象 (结算还要读它的目标分数), 所以用一个标志表达同一件事.
    ///
    /// **为什么需要它**: 同一局里 (XXWF71H9) 蛇这个 Boss 在回合内只补 3 张牌
    /// (第 155 步玩家自己确认了 "打完 5 张后手牌只剩 6 张"), 但第 167 步在**商店里**开
    /// 秘术包时补的是整整一手 8 张. 原因就是上面那句清空: 蛇的判据写的是
    /// `G.GAME.blind.name == 'The Serpent'`, 而那时 `name` 已经是空串了.
    ///
    /// (注: Steamodded 也有个同名同义的 `in_blind`, 但它管的是 `Card:add_to_deck` 那几处
    /// `if G.GAME.blind then` 的守卫, 与蛇这条判据无关 —— 别把两件事混起来.)
    pub in_blind: bool,
}

impl RunState {
    /// 小丑槽位的**上限**, 也就是游戏的 `G.jokers.config.card_limit`.
    ///
    /// 基数之外要加上**每张负片小丑的一份** —— 游戏在 `Card:add_to_deck` 里对负片牌做
    /// `G.jokers.config.card_limit = G.jokers.config.card_limit + 1`, 从牌组里拿走时再减回来.
    ///
    /// 这里不照抄那对加减, 而是**从队里现数**: 两者等价 (那张牌在队里就有一份, 不在就没有),
    /// 但现数的写法不可能漂 —— 增删小丑的路径有买 / 开包 / 卖 / 妖法销毁 / 灵质销毁 /
    /// 隐形小丑复制 / 生命十字章等等十来条, 只要漏掉其中一条的减号, 上限就会悄悄偏,
    /// 而症状是"某个地方买不进去"或"某个地方多出一个位置", 很难往这里想.
    pub fn joker_capacity(&self) -> usize {
        self.base_joker_slots + negative_count(&self.jokers)
    }

    /// 消耗牌槽位的上限 (`G.consumeables.config.card_limit`), 口径同上.
    pub fn consumable_capacity(&self) -> usize {
        self.base_consumable_slots + negative_count(&self.consumables)
    }

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
            shop_seen: false,
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
            voucher_spent: false,
            tags: Vec::new(),
            extra_voucher_keys: Vec::new(),
            skips: 0,
            total_hands_played: 0,
            unused_discards: 0,
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
            deck_key: String::new(),
            deck_config: crate::data::json::Json::Null,
            no_interest: false,
            ecto_minus: 1,
            hand_sort: HandSort::Value,
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
            blind_hands_sub: 0,
            blind_discards_sub: 0,
            heart_chosen_sort_id: None,
            heart_prepped: false,
            hand_size_bonus: 0,
            temporary_hand_size_bonus: 0,
            base_joker_slots: 5,
            base_consumable_slots: 2,
            jokers: Vec::new(),
            consumables: Vec::new(),
            open_pack: None,
            pack_return_phase: Phase::Shop,
            shop: None,
            planets_used: 0,
            unique_planets_used: HashSet::new(),
            tarots_used: 0,
            starting_deck_size: 0,
            next_card_id: 0,
            last_hand_played: None,
            hands: HandTable::new(),
            won: false,
            in_blind: false,
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
    /// 逐个对应 `Back:apply_to_run` (`game/back.lua` L174) 里的各支. 契约是: **原型里写了什么,
    /// 这里就认什么** —— 漏认一项不会报错, 只会让那一局悄悄少一个效果 (绿色牌组少了那两笔
    /// 余手/弃牌钱, 或者画师牌组没多那两张手牌), 而且只有对拍时才会以"分数对不上"的形式露出来.
    ///
    /// 有两支**不能在这里做完**, 留给后面的步骤:
    /// - `consumables` / `voucher` / `vouchers`: 游戏里它们挂在 `E_MANAGER` 的事件上, 在建堆
    ///   之后才执行, 而且要消耗随机数 (造消耗牌会掷一次版本) —— 所以顺序不能提前. 见
    ///   [`RunState::apply_starting_deck_extras`].
    /// - `remove_faces` / `randomize_rank_suit` 与棋盘牌组的花色替换都作用在**牌堆内容**上,
    ///   那时还没有牌堆. 见 [`RunState::build_deck`].
    pub fn with_deck(mut self, deck_key: &str) -> Self {
        let config = crate::data::catalog::Catalog::get()
            .record(deck_key)
            .and_then(|proto| proto.config.clone())
            .unwrap_or(crate::data::json::Json::Null);
        self.deck_key = deck_key.to_owned();
        self.deck_config = config.clone();
        let number = |field: &str| config.get(field).and_then(crate::data::json::Json::as_f64);
        if let Some(scaling) = number("ante_scaling") {
            self.ante_scaling = scaling;
        }
        if let Some(hands) = number("hands") {
            self.hands_per_round += hands as i64;
        }
        if let Some(discards) = number("discards") {
            self.discards_per_round += discards as i64;
        }
        if let Some(dollars) = number("dollars") {
            self.dollars += dollars;
        }
        if let Some(slots) = number("joker_slot") {
            self.base_joker_slots = (self.base_joker_slots as i64 + slots as i64).max(0) as usize;
        }
        if let Some(slots) = number("consumable_slot") {
            self.base_consumable_slots =
                (self.base_consumable_slots as i64 + slots as i64).max(0) as usize;
        }
        if let Some(size) = number("hand_size") {
            self.hand_size_bonus += size as i64;
        }
        if let Some(rate) = number("spectral_rate") {
            self.spectral_rate = rate;
        }
        // 绿色牌组那两笔: 每剩一次出牌给两块, 每剩一次弃牌给一块.
        if let Some(bonus) = number("extra_hand_bonus") {
            self.money_per_hand = bonus;
        }
        if let Some(bonus) = number("extra_discard_bonus") {
            self.money_per_discard = bonus;
        }
        if config
            .get("no_interest")
            .and_then(crate::data::json::Json::as_bool)
            .unwrap_or(false)
        {
            self.no_interest = true;
        }
        self
    }

    /// 牌组自带的消耗牌与券 —— 对应 `Back:apply_to_run` 里挂在事件上的那几支.
    ///
    /// 由 [`RunState::start_run`] 在**建堆之后**调用, 顺序与游戏一致: 建堆 -> 开局的额外东西.
    ///
    /// 券要**两件事都做**: 记进 `used_vouchers` (于是池子里不再出它, 而且它的"解锁后续券"
    /// 关系成立) 与**施加它的效果** (`voucher::apply`). 只记不施加的话, 字谜牌组那三张券
    /// 就等于白送 —— 货架仍然是按没买券的权重抽的.
    pub fn apply_starting_deck_extras(&mut self) {
        let list = |field: &str| -> Vec<String> {
            match self.deck_config.get(field) {
                Some(crate::data::json::Json::Array(items)) => items
                    .iter()
                    .filter_map(|item| item.as_str().map(str::to_owned))
                    .collect(),
                _ => Vec::new(),
            }
        };
        // 券: `voucher` 是单张 (魔术 / 星云牌组), `vouchers` 是一组 (字谜牌组).
        // 单张那一支排在前面, 与 `Back:apply_to_run` 里那两段代码的先后一致.
        // 注意 `voucher` 在原型里是**裸字符串**而不是数组, 与 `vouchers` 的形态不同 ——
        // 只按数组解析的话它会被静静地当成"没有券", 而后果是整副货架的权重都偏了.
        let mut vouchers: Vec<String> = match self.deck_config.get("voucher") {
            Some(crate::data::json::Json::String(key)) => vec![key.clone()],
            _ => Vec::new(),
        };
        vouchers.extend(list("vouchers"));
        // 消耗牌的清单先取出来: 后面 `list` 还要借 `self`, 而循环体里要可变借.
        let consumables = list("consumables");
        for key in vouchers {
            self.used_vouchers.insert(key.clone());
            super::voucher::apply(self, &key);
        }
        // 消耗牌: 游戏那边是逐张 `create_card('Tarot', …, 强制键, 'deck')`.
        // 即使给了强制键, **版本那一掷照样要掷** (`poll_edition` 在强制分支之外),
        // 所以这里必须走造牌那条路, 不能直接往槽里塞一个键.
        for key in consumables {
            let created = super::shop::create_card_inner(
                self,
                "Tarot",
                "deck",
                true,
                Some(key.as_str()),
            );
            self.add_consumable(super::consumable::Consumable::plain(created));
        }
    }

    /// 这副牌背后面的计分效果, 对应游戏里的 `G.GAME.selected_back`.
    ///
    /// 现在只有等离子牌组有: 它把筹码与倍率**都换成两者的平均值**.
    ///
    /// 之所以做成"从牌组现算"而不是让调用方自己传: 这是同一副牌的两个说法, 而分开传的时候
    /// **没有东西会报错** —— 选了等离子牌组却按普通牌背算, 表现成"分数差一截",
    /// 与"牌组选错了"隔得很远. 计分那一层仍然收一个 `BackEffect` 参数 (它在计分中途拿不到
    /// 整个局面), 但手上已经有运行状态的调用方应当用它.
    pub fn back_effect(&self) -> crate::scoring::BackEffect {
        match self.deck_key.as_str() {
            "b_plasma" => crate::scoring::BackEffect::Plasma,
            _ => crate::scoring::BackEffect::Plain,
        }
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

/// "这张牌是不是负片" —— 小丑与消耗牌都有 `edition` 这个字段, 但它们是两个类型,
/// 数上限时都要用, 所以抽一个最小接口出来, 免得写两遍一样的东西.
trait NegativeEdition {
    fn is_negative(&self) -> bool;
}

impl NegativeEdition for Joker {
    fn is_negative(&self) -> bool {
        self.edition == Some(crate::cards::Edition::Negative)
    }
}

impl NegativeEdition for super::consumable::Consumable {
    fn is_negative(&self) -> bool {
        self.edition == Some(crate::cards::Edition::Negative)
    }
}

/// 数一遍这一组牌里有几张负片.
fn negative_count<T: NegativeEdition>(cards: &[T]) -> usize {
    cards.iter().filter(|card| card.is_negative()).count()
}
