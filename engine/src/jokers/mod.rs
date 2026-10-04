//! 小丑.
//!
//! 一张小丑在计分时的行为由三部分决定: 触发时机 (哪个 `context` 字段), 判定条件, 以及返回
//! 哪些数值. 这套机制在 `game/card.lua` 的 `Card:calculate_joker` 里, 是一长串顺序 `if`,
//! **命中即返回**, 所以判断顺序不能重排 —— 泛化分支 (只看数值字段) 排在具名分支前面.
//!
//! 这一层先做通用数值小丑与少数几张具名的:
//!
//! - `ability.mult` 之类的成长值加到倍率上;
//! - `t_mult` / `t_chips` 配上 `type` (牌型名), 命中该牌型才生效;
//! - `x_mult` 是乘倍率;
//! - 卡尼奥的成长值.
//!
//! 绝大多数原版小丑都能落进上面几条, 剩下的按 `docs/rewrite/joker-effects-*.md` 逐条补.

use crate::data::json::Json;
use crate::scoring::{EvaluatedHand, HandCard, PokerHand};

use crate::cards::{Rank, Suit};

/// 小丑触发时机, 对应 `Card:calculate_joker` 收到的 `context`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Trigger {
    /// 出牌前 (`context.before`).
    Before,
    /// 出牌后 (`context.after`).
    After,
    /// 主效果, 出牌结算的最后一段 (`joker_main`).
    JokerMain,
    /// 逐张牌 (`context.individual`).
    Individual { in_play: bool },
    /// 重触发次数统计 (`context.repetition`).
    Repetition { in_play: bool },
    /// 其他小丑对它的结算 (`context.other_joker`).
    OtherJoker,
    /// 回合结束时 (`context.end_of_round`).
    EndOfRound,
}

/// 一次触发时能看到的局面.
///
/// `hands` 是这手牌满足的**全部**牌型结果 (不只是最终选中的那个), 因为不少小丑判的是
/// "这手牌里有没有对子"这种包含关系. 例如三条也能满足 `Pair`, 葫芦还能满足 `Two Pair`.
#[derive(Clone, Copy, Debug)]
pub struct TriggerContext<'a> {
    /// 本次选中的牌型.
    pub hand: PokerHand,
    /// 这手牌满足的全部牌型.
    pub hands: &'a EvaluatedHand,
    /// 打出的牌, 与 `hands` 里下标对应. 看人头牌或张数的小丑要它.
    pub cards: &'a [HandCard],
    /// **参与计分**的那几张牌, 按计分顺序. 照片小丑要它 —— 它只看"第一张人头牌".
    pub scoring: &'a [HandCard],
    /// 留在手里的牌. 黑板要它 (手里全是黑桃或梅花才乘倍率).
    pub held: &'a [HandCard],
    /// 打出的牌张数.
    pub full_hand_len: usize,
    /// 这一手牌型在这回合**之前**已经打过几次 (`G.GAME.hands[hand].played_this_round`).
    ///
    /// 牌卡夏普那类"这手型打过就乘"的小丑要看它. 注意引擎是在**计分之后**才累加次数的,
    /// 所以这里拿到的是"之前打过的次数"; 游戏那边的判断是"含这一手在内 > 1", 两者等价 ——
    /// 这个等价靠 `HandTable::reset_round` 在每回合开始时清零来维持, 别把它摘了.
    pub played_this_round: u32,
    /// 上古小丑这一回合盯的花色 (`G.GAME.current_round.ancient_card.suit`).
    pub ancient_suit: Option<crate::cards::Suit>,
    /// 爱豆这一回合盯的那张牌 (花色 + 点数).
    pub idol_card: Option<(crate::cards::Suit, crate::cards::Rank)>,
    /// 帕瑞多利亚: 手里有它时**人人都是人头牌**.
    pub pareidolia: bool,
    /// 概率的额外分子 (七上八下让所有概率翻倍时是 1.0, 平时是 0.0).
    pub probability_extra: f64,
    /// 消耗槽还剩几个位子. 八号球 / 叠加态那类**先看有没有位子, 有位子才掷骰** ——
    /// 顺序不能反: 没位子时不掷, 随机序列因此不同.
    pub consumable_room: usize,
    /// 这一回合还剩几次弃牌 (旗帜与神秘之峰要看).
    pub discards_left: i64,
    /// 当前现金 (斗牛要看).
    pub dollars: f64,
    /// 持有几张小丑, 含自己 (抽象小丑要看).
    pub joker_count: usize,
    /// 小丑格子的**上限** (模具小丑要看空位). 含负片小丑加出来的那一份.
    pub joker_capacity: usize,
    /// 队里有**几张模具小丑**. 模具自己的乘倍率是"空位 + 队里模具张数",
    /// 所以它得知道队里一共有几张自己 —— 这一项由计分那一层数好传进来.
    pub stencil_count: usize,
    /// 这一回合还剩几次出牌 (杂技演员要看"这是不是最后一手").
    pub hands_left: i64,
    /// 牌堆里还剩多少张 (蓝色小丑要看).
    pub deck_len: usize,
    /// 这一局还活着的牌一共几张, 其中石头牌 / 带强化的各有几张
    /// (石头小丑 / 侵蚀 / 驾照要看), 以及开局那副牌有多少张 (侵蚀要比它).
    pub deck_total: usize,
    pub deck_stones: usize,
    pub deck_enhanced: usize,
    pub starting_deck_size: usize,
    /// 牌堆里 9 有几张 (9 霄云外要看).
    pub deck_nines: usize,
    /// 本局用掉过几张行星牌 (卫星要看).
    pub planets_used: usize,
    /// 这一回合弃过几次牌 (延迟满足要看).
    pub discards_used: i64,
    /// 各牌型本局打过的次数 (方尖碑要看: 它比的是"这一手是不是打得最多的那种").
    pub table: &'a crate::scoring::HandTable,
}

impl TriggerContext<'_> {
    /// 打出的牌里有没有人头牌 (J / Q / K). 搭乘巴士与迈达斯面具看这个.
    pub fn has_face_card(&self) -> bool {
        self.cards.iter().any(|c| self.is_face(c))
    }
}

/// 小丑返回的效果. 与游戏里那张表的字段一一对应, 没生效的项留默认值.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct JokerEffect {
    /// 加到倍率上.
    pub mult_mod: f64,
    /// 加到筹码上.
    pub chip_mod: f64,
    /// 乘到倍率上.
    pub xmult_mod: f64,
    /// 直接给的钱 (`p_dollars`). 璞玉那类"每张方片给一块"走这里.
    pub dollars: f64,
    /// 这次效果顺手造出来的消耗牌: (池类型, 追加键). 计分层只**报告要造什么**,
    /// 真正去造由**调用方**拿着 `Creation` 做 —— 计分那一趟本身不碰运行状态.
    /// 至于"什么时候造", 是在同一个循环里**立刻**造, 这样随机序列与游戏一致.
    pub create_consumable: Option<(&'static str, &'static str)>,
    /// 飘字用的说明, 目前不参与计算.
    pub message: Option<String>,
}

impl JokerEffect {
    /// 有没有真的改动数值.
    pub fn is_empty(&self) -> bool {
        self.mult_mod == 0.0
            && self.chip_mod == 0.0
            && self.xmult_mod == 0.0
            && self.dollars == 0.0
    }
}

impl TriggerContext<'_> {
    /// 这张牌算不算人头牌. 与游戏的 `Card:is_face` 一一对应:
    /// **失效的牌先判否**, 然后看点数是不是 J/Q/K, 最后才轮到帕瑞多利亚把所有人都算成人头牌.
    pub fn is_face(&self, card: &HandCard) -> bool {
        if card.debuffed {
            return false;
        }
        card.card.rank.is_face() || self.pareidolia
    }

}

/// 一张小丑.
///
/// 成长值放在这里, 原型的固定参数留在 `config` 里 (与游戏的 `ability` 与
/// `config.center.config` 对应), 需要时再取.
#[derive(Clone, Debug)]
pub struct Joker {
    pub key: String,
    /// 原型上的初始参数, 例如 `{"t_mult": 12, "type": "Three of a Kind"}`.
    pub config: Json,
    /// `ability.mult`: 基础倍率加成, 会被成长类小丑改.
    pub mult: f64,
    /// `ability.x_mult`: 乘倍率, 大于 1 时生效.
    pub x_mult: f64,
    /// `ability.t_mult`: 命中指定牌型才加的倍率.
    pub t_mult: f64,
    /// `ability.t_chips`: 命中指定牌型才加的筹码.
    pub t_chips: f64,
    /// 尤里克 (传奇) 还剩多少张弃牌才涨一次. 初值取 `extra.discards` (23), 每弃一张减一.
    pub yorick_discards: f64,
    /// 无面者这一次弃牌该给多少块钱 (给完由调用方清零).
    pub faceless_dollars: f64,
    /// 待办清单这一回合指定的牌型 (`G.GAME.current_round` 之外, 它挂在牌自己身上).
    pub todo_hand: Option<crate::scoring::PokerHand>,
    /// 卖出价上的加成 (蛋每回合 +3, 礼物卡按回合数长) —— 与原型价分开记.
    pub extra_value: f64,
    /// 隐形小丑已经过了几个回合 (攒到 `extra` (2) 就能卖掉复制一个小丑).
    pub invis_rounds: f64,
    /// 成长出来的筹码 (`extra.chips`), 方形小丑与跑步选手用它.
    pub chips: f64,
    /// `ability.type`: `t_mult` / `t_chips` 要求的牌型, 空表示不限.
    pub kind: Option<PokerHand>,
    /// 卡尼奥的成长值, 每摧毁一张人头牌加 `extra`.
    pub caino_xmult: f64,
    /// `ability.extra`: 多数成长类小丑的步长.
    pub extra: f64,
    /// 当前基础标价, 折扣与版本变化会重算. 卖价另外加上成长值.
    pub cost: f64,
    /// 拿到这张牌之后出过几手. 积分卡这类"按次数循环"的小丑要看.
    pub hands_since_gained: u32,
    /// 这张小丑被削弱了吗. 易腐到期就会变成这样, 效果全部停用.
    ///
    /// 削弱是**每张小丑各自**的属性 (绯红之心只关掉一张), 所以放在小丑自己身上,
    /// 而不是放在共享的触发上下文里.
    pub debuffed: bool,
    /// 这张小丑的版本 (闪箔 / 镭射 / 多彩 / 负片). 幻灵的妖法与灵质会给它加.
    pub edition: Option<crate::cards::Edition>,
    /// 永恒: 不能被销毁也不能被卖掉. 生命十字章那类"删掉其余的"要看它.
    pub eternal: bool,
    /// 租赁小丑: 每个回合末扣一次租金 (`G.GAME.rental_rate`, 默认三块).
    pub rental: bool,
    /// 易腐小丑剩下的回合数, 0 表示不是易腐的.
    /// 每回合末减一, 减到 0 就**变成被削弱** (效果全停, 但小丑还在队里).
    pub perish_tally: i64,
    /// 建牌序号, 对应游戏的 `Card.sort_id` (小丑也是 `Card`, 吃的是**同一个**全局计数器).
    ///
    /// 平时看不出它有什么用 —— 队里的小丑本来就是按入队顺序排的. 但它有两个用途:
    ///
    /// 1. **琥珀橡果 (决战 Boss) 洗小丑之前会按它排序** (`pseudoshuffle` 开头那一次
    ///    `table.sort`), 而那次洗牌会**连做三次**: 每次都从"按序号排好"的队形开始. 少了排序,
    ///    三次洗牌就会层层叠加, 洗出来的顺序与游戏不同 —— 而小丑的先后决定计分顺序
    ///    (谁先给谁加成), 所以这不是"看不见的差别".
    /// 2. 手动调换小丑顺序 (`rearrange`) 之后, 队形与序号不再一致, 排序才真正起作用.
    pub sort_id: u32,
}

impl Joker {
    /// 成长的卖价加成不参与除二, 与 Card:set_cost 一致.
    pub fn sell_price(&self) -> f64 {
        (self.cost / 2.0).floor().max(1.0) + self.extra_value
    }

    /// 按原型建一张小丑 (还没上过任何成长).
    pub fn new(key: &str) -> Option<Joker> {
        let proto = crate::data::catalog::Catalog::get().record(key)?;
        Some(Joker::from_prototype(proto))
    }

    pub fn from_prototype(proto: &crate::data::catalog::Prototype) -> Joker {
        let config = proto.config.clone().unwrap_or(Json::Null);
        let number = |field: &str| config.get(field).and_then(Json::as_f64).unwrap_or(0.0);
        Joker {
            key: proto.id.clone(),
            t_mult: number("t_mult"),
            t_chips: number("t_chips"),
            // 尤里克从 0 开始计数, 第一次用到时再取初值 (见 `on_discard`).
            yorick_discards: 0.0,
            faceless_dollars: 0.0,
            todo_hand: None,
            extra_value: 0.0,
            invis_rounds: 0.0,
            // `type` 是牌型名, 转换失败就当成不限.
            kind: config
                .get("type")
                .and_then(Json::as_str)
                .and_then(PokerHand::from_key),
            // 海龟豆的 `extra` 是个对象 (`{h_size: 5, h_mod: 1}`), 而它那个 `h_size` 每回合掉一点,
            // 所以把"当前值"存在 `extra` 这个数字字段里, 与其他成长型小丑同一套路.
            extra: if proto.id == "j_turtle_bean" {
                config
                    .get("extra")
                    .and_then(|e| e.get("h_size"))
                    .and_then(Json::as_f64)
                    .unwrap_or(5.0)
            } else {
                number("extra")
            },
            // 由调用方按实际标价填, 这里给一个基于原型价的默认值.
            cost: proto.base_cost.unwrap_or(0.0),
            hands_since_gained: 0,
            edition: None,
            debuffed: false,
            eternal: false,
            rental: false,
            perish_tally: 0,
            chips: if matches!(config.get("extra"), Some(Json::Object(_))) {
                config
                    .get("extra")
                    .and_then(|e| e.get("chips"))
                    .and_then(Json::as_f64)
                    .unwrap_or(0.0)
            } else {
                0.0
            },
            caino_xmult: if proto.id == "j_caino" { 1.0 } else { 0.0 },
            mult: number("mult"),
            // 原型里这一项写作 `Xmult` (大写 X), 不是 `x_mult` —— 13 张用它的牌都靠这里读,
            // 早先按小写读, 结果它们全都读成 0, 也就是乘倍率一直没生效.
            // `Card:set_ability` 里 `x_mult` **默认就是 1** —— 没写 `Xmult` 的牌也应当是 1,
            // 而不是 0. 这一条原来写的是"直接读, 读不到就是 0", 于是所有**靠成长**用乘倍率的小丑
            // (尤里克 / 天涯路 / 拉面 / 疯狂...) 都从 0 起算, 涨了半天还是不到 1, 于是永远不生效.
            // 通用分支付账的条件是"大于 1", 所以把默认值从 0 改成 1 不会让任何一张牌白白生效.
            x_mult: match number("Xmult") {
                0.0 => 1.0,
                value => value,
            },
            sort_id: 0,
            config,
        }
    }

    /// 这张小丑有没有可能改动某个牌型的数值.
    fn matches_hand(&self, hands: &EvaluatedHand) -> bool {
        match self.kind {
            Some(kind) => hands.has(kind),
            None => true,
        }
    }

    /// 读 `config.extra` 里的一个数字.
    ///
    /// `extra` 的形态随小丑而变: 备用裤子与搭乘巴士是裸数字, 方形小丑是 `{chips, chip_mod}`,
    /// 绿色小丑是 `{hand_add, discard_sub}`. 裸数字时就直接用它, 否则按字段名取.
    fn extra_number(&self, field: &str) -> f64 {
        match self.config.get("extra") {
            Some(Json::Number(n)) => *n,
            Some(extra) => extra.get(field).and_then(Json::as_f64).unwrap_or(0.0),
            None => 0.0,
        }
    }


    /// 出牌前 (`context.before`): 成长类小丑在这里改自己的值, 改动**本次计分就生效**,
    /// 因为主效果排在后面才读.
    ///
    /// 返回的只是给飘字看的说明, 数值本身已经写回 `self`.
    pub fn before(&mut self, ctx: &TriggerContext) -> Option<JokerEffect> {
        if self.debuffed {
            return None;
        }

        // 出过的这一手先记上 —— 积分卡按"拿到之后打了几手"循环.
        self.hands_since_gained += 1;

        // 方尖碑: 如果这一手打的是"本局唯一打得最多的牌型"就重置成 1, 否则涨 0.2.
        //
        // 比较基准是**含这一手**的计数: 游戏在 `evaluate_play` 开头就给本次牌型 `played += 1`,
        // 而引擎在计分**之后**才累加, 所以这里要补上那一次. 边界就在这一位上 ——
        // 出牌前高牌 10 / 对子 9, 再打对子时游戏看到的是"10 与高牌并列"仍算增长;
        // 对子本来是 10 时, 新计数 11 成为唯一最高, 才重置 (手册 §4.4 的三个例子).
        // 判定用的是 `>=`: 别的牌型只要"不比这一手少"就算压住了它.
        if self.key == "j_obelisk" {
            let mine = ctx.table.get(ctx.hand).played + 1;
            let beaten = crate::scoring::PokerHand::BY_PRIORITY
                .iter()
                .filter(|hand| **hand != ctx.hand)
                .any(|hand| ctx.table.get(*hand).played >= mine);
            if beaten {
                self.x_mult += self.extra_number("extra");
            } else if self.x_mult > 1.0 {
                self.x_mult = 1.0;
            }
        }

        match self.key.as_str() {
            // 备用裤子: 打出两对或葫芦时 +extra 倍率 (extra = 2).
            "j_trousers" => {
                if ctx.hands.has(PokerHand::TwoPair) || ctx.hands.has(PokerHand::FullHouse) {
                    self.mult += self.extra;
                    return Some(JokerEffect::default());
                }
            }
            // 绿色小丑: 每次出牌 +1 倍率; 弃牌时的 -1 在 `discard` 分支, 这里不做.
            "j_green_joker" => {
                self.mult += 1.0;
                return Some(JokerEffect::default());
            }
            // 方形小丑: 打出的牌**正好四张**时 +4 筹码. 注意看的是打出的张数,
            // 不是参与计分的张数, 所以打四张凑高牌也算.
            "j_square" => {
                if ctx.full_hand_len == 4 {
                    self.chips += self.extra_number("chip_mod");
                    return Some(JokerEffect::default());
                }
            }
            // 跑步选手: 打出顺子时 +15 筹码.
            // `Straight` 这一组在同花顺与皇家同花顺时也会被记上, 所以只判它就够了.
            "j_runner" => {
                if ctx.hands.has(PokerHand::Straight) {
                    self.chips += self.extra_number("chip_mod");
                    return Some(JokerEffect::default());
                }
            }
            // 搭乘巴士: 这手牌里没有面牌就 +1 倍率, 有面牌则一路白费, 直接清零.
            "j_ride_the_bus" => {
                if ctx.has_face_card() {
                    self.mult = 0.0;
                } else {
                    self.mult += self.extra;
                }
            }
            _ => {}
        }
        None
    }

    /// 弃牌时 (`context.discard`).
    ///
    /// - 绿色小丑: 每次弃牌掉 1 点倍率;
    /// - 城堡: 弃掉的牌里**有那一回合盯的花色**就长大一次 (`chip_mod` 点筹码).
    ///
    /// 这两个钩子原来**一次都没被调用过** —— 绿小丑只涨不掉, 城堡整个没实现.
    pub fn on_discard(
        &mut self,
        discarded: &[crate::cards::CardInstance],
        castle_suit: Option<crate::cards::Suit>,
        pareidolia: bool,
    ) {
        if self.key == "j_green_joker" {
            self.mult -= 1.0;
        }
        if self.key == "j_castle"
            && let Some(suit) = castle_suit
            && discarded.iter().any(|card| card.card.suit == suit)
        {
            self.chips += self.extra_number("chip_mod");
        }
        // 拉面: 每弃**一张**牌就掉 0.01 倍率 (它自己那个 `x_mult`).
        if self.key == "j_ramen" {
            let step = self.extra_number("extra");
            for _ in 0..discarded.len() {
                self.x_mult -= step;
            }
        }
        // 天涯路: 每弃**一张 J** 就涨一次 (`extra` = 0.5); 回合末归 1.
        if self.key == "j_hit_the_road" && self.x_mult <= 0.0 {
            self.x_mult = 1.0;
        }
        if self.key == "j_hit_the_road" {
            let jacks = discarded
                .iter()
                .filter(|card| card.card.rank == crate::cards::Rank::Jack && !card.debuffed)
                .count();
            self.x_mult += jacks as f64 * self.extra;
        }
        // 无面者: 这一次弃掉的牌里有**至少三张人头牌**就给钱 (游戏在那批的最后一张上判一次).
        if self.key == "j_faceless" {
            // 弃牌这条路拿不到计分那套上下文, 所以帕瑞多利亚的标志单独传进来.
            let faces = discarded
                .iter()
                .filter(|card| !card.debuffed && (card.card.rank.is_face() || pareidolia))
                .count();
            if faces as f64 >= self.extra_number("faces") {
                self.faceless_dollars = self.extra_number("dollars");
            }
        }
        // 尤里克 (传奇): 每弃**一张**牌计数减一, 减到剩最后一张时重置并乘倍率 +1.
        if self.key == "j_yorick" {
            if self.yorick_discards <= 0.0 {
                self.yorick_discards = self.extra_number("discards");
            }
            // **先判后减** —— 游戏那边就是 `if yorick_discards <= 1 then 重置+涨 else 减一`,
            // 所以每满 23 张才涨一次. 顺序写反会早一张涨, 而且看不出来.
            for _ in 0..discarded.len() {
                if self.yorick_discards <= 1.0 {
                    self.yorick_discards = self.extra_number("discards");
                    self.x_mult += self.extra_number("xmult");
                } else {
                    self.yorick_discards -= 1.0;
                }
            }
        }
    }

    /// 本轮计分结束后 (`context.after`).
    ///
    /// 这里只改**下一轮**要用的值, 所以它相对牌背处理的先后不影响本轮总分.
    /// 返回 `true` 表示这张小丑用完就没了 (冰淇淋融化, 汽水喝完), 调用方要把它移出持有区.
    ///
    /// `_ctx` 目前用不上, 留着是为了与其他几个阶段的签名一致.
    pub fn after(&mut self, ctx: &TriggerContext) -> bool {
        if self.debuffed {
            return false;
        }
        match self.key.as_str() {
            // 小不点 (Wee Joker): 这一手里**每一张计分的 2** 长 8 点.
            // 放在 `after` (计分结束之后) 而不是计分之中: 手牌级的付账在计分**之前**跑,
            // 所以这一手的成长要到**下一手**才付账 —— 先付账后成长, 顺序不能反.
            "j_wee" => {
                let twos = ctx
                    .scoring
                    .iter()
                    .filter(|card| card.card.rank == crate::cards::Rank::Two)
                    .count();
                self.chips += twos as f64 * self.extra_number("chip_mod");
            }
            // 冰淇淋: 每回合融 5 点, 融到 0 就没了.
            // 注意先判自毁再减, 所以最后剩下的那 5 点仍然算在最后一次计分里.
            "j_ice_cream" => {
                let step = self.extra_number("chip_mod");
                if self.chips - step <= 0.0 {
                    return true;
                }
                self.chips -= step;
            }
            // 汽水: 每回合掉一次重触发次数, 用完就没了.
            "j_selzer" => {
                if self.extra - 1.0 <= 0.0 {
                    return true;
                }
                self.extra -= 1.0;
            }
            _ => {}
        }
        false
    }

    /// 原型 `extra.suit` 里的花色, 认不出来返回 `None`.
    ///
    /// 四张花色小丑共用这一段: 它们的差别只有这一个字段.
    fn extra_suit(&self) -> Option<Suit> {
        let name = self
            .config
            .get("extra")
            .and_then(|extra| extra.get("suit"))
            .and_then(Json::as_str)?;
        match name {
            "Diamonds" => Some(Suit::Diamonds),
            "Hearts" => Some(Suit::Hearts),
            "Spades" => Some(Suit::Spades),
            "Clubs" => Some(Suit::Clubs),
            _ => None,
        }
    }

    /// 看**另一张**小丑的效果 (`context.other_joker`).
    ///
    /// 棒球卡那类"因为我队里有某类小丑, 所以我给加成"的走这里. 它对每一张别的小丑各触发一次,
    /// 所以最终的倍数与队里有几张符合条件的有关.
    pub fn other_joker(&self, other: &Joker) -> Option<JokerEffect> {
        // 调用方已经排除了"自己看自己", 这里不用再判一次.
        if self.key != "j_baseball" {
            return None;
        }
        // 棒球卡: 队里每张**罕见** (2 级) 小丑让倍率乘 1.5.
        let rarity = crate::data::catalog::Catalog::get()
            .record(&other.key)
            .and_then(|proto| proto.rarity);
        if rarity == Some(2) {
            return Some(JokerEffect {
                xmult_mod: self.extra,
                ..JokerEffect::default()
            });
        }
        None
    }

    /// 这张小丑让某张计分牌**多算几遍** (`context.repetition`).
    ///
    /// 游戏那边先把"每张小丑给几次"收成一个列表, 再把整段逐卡效果重跑那么多次, 所以这里
    /// 返回的是**额外**次数 (不含那张牌本身那一次). 红封给的那一次在牌上, 不在这里.
    pub fn retrigger(&self, card: &HandCard, ctx: &TriggerContext) -> u32 {
        if self.debuffed {
            return 0;
        }
        let extra = self.extra.max(0.0) as u32;
        match self.key.as_str() {
            // 袜子与巴斯金: 人头牌多算一遍.
            "j_sock_and_buskin" if ctx.is_face(card) => extra,
            // 烂脱口秀演员: 点数 2 / 3 / 4 / 5 的牌多算一遍.
            "j_hack"
                if matches!(
                    card.card.rank,
                    Rank::Two | Rank::Three | Rank::Four | Rank::Five
                ) =>
            {
                extra
            }
            // 黄昏: 这一回合**最后一手**里每张牌都多算一遍.
            "j_dusk" if ctx.hands_left <= 0 => extra,
            // 挂账: 只有这一手里的**第一张**计分牌多算一遍.
            "j_hanging_chad" => {
                if ctx.scoring.first().is_some_and(|view| view.card == card.card) {
                    extra
                } else {
                    0
                }
            }
            // 汽水: 直到喝完为止, 每张牌都多算一遍 (`extra` 是剩余次数, 不参与"几次"的计算).
            "j_selzer" if self.extra > 0.0 => 1,
            _ => 0,
        }
    }

    /// 回合末那几张自己的事 (`context.end_of_round`). 返回 `true` 表示这张小丑就此销毁.
    ///
    /// 与 [`Joker::after`] 的区别在**频率**: `after` 是**每出一手**就跑 (冰淇淋),
    /// 这个是**每回合末**跑一次 (大麦克的销毁骰, 爆米花的退化).
    pub fn end_of_round_effect(&mut self, rng: &mut crate::rng::Rng, probability_scale: f64) -> bool {
        // 蛋: 每过一个回合给自己涨一点**卖出价** (不是筹码, 是卖掉时多拿的钱).
        if self.key == "j_egg" {
            self.extra_value += self.extra;
        }
        // 隐形小丑: 每过一个回合攒一点 ("过两回合后卖掉可复制一个小丑").
        if self.key == "j_invisible" {
            self.invis_rounds += 1.0;
        }
        // 海龟豆: 每回合掉一点手牌上限; 掉到 0 就自毁 (游戏是先判后减).
        if self.key == "j_turtle_bean" {
            let step = self.extra_number("h_mod");
            if self.extra - step <= 0.0 {
                return true;
            }
            self.extra -= step;
        }
        // 天涯路: 回合结束回到 1 倍 (游戏在 `end_of_round` 那一支里做).
        if self.key == "j_hit_the_road" && self.x_mult > 1.0 {
            self.x_mult = 1.0;
        }
        if self.debuffed {
            return false;
        }
        match self.key.as_str() {
            // 大麦克: 每回合末掷 1/6, 中了就烂掉 (掷中的那次它已经给过这一回合的倍率了).
            "j_gros_michel" => {
                let odds = self.extra_number("odds");
                odds > 0.0 && rng.pseudorandom("gros_michel") < probability_scale / odds
            }
            // 爆米花: 每回合末掉 4 点倍率, 掉到 0 就没了.
            "j_popcorn" => {
                let step = self.extra;
                if self.mult - step <= 0.0 {
                    return true;
                }
                self.mult -= step;
                false
            }
            _ => false,
        }
    }

    /// 回合末给的那笔钱, 对应 `Card:calculate_dollar_bonus`.
    ///
    /// 与"计分时给钱"不同: 这个在回合结算时给, 所以不看这一手打了什么, 只看局面.
    pub fn dollar_bonus(&self, ctx: &TriggerContext) -> f64 {
        if self.debuffed {
            return 0.0;
        }
        match self.key.as_str() {
            // 黄金小丑: 固定数额.
            "j_golden" => self.extra,
            // 9 霄云外: 牌堆里每张 9 给一份.
            "j_cloud_9" => self.extra * ctx.deck_nines as f64,
            // 火箭: 给的是成长值 (每回合自己涨).
            "j_rocket" => self.extra_number("dollars"),
            // 卫星: 本局用过的行星牌越多给得越多.
            "j_satellite" => self.extra * ctx.planets_used as f64,
            // 延迟满足: 这一回合**一次都没弃牌**且还有弃牌余量时, 按余量给;
            // 其余情况落到下面那条 `0.0`.
            "j_delayed_grat" if ctx.discards_used == 0 && ctx.discards_left > 0 => {
                self.extra * ctx.discards_left as f64
            }
            _ => 0.0,
        }
    }

    /// 手牌阶段触发 (`context.cardarea == G.hand`): 看的是**留在手里**的那张牌.
    ///
    /// `other` 是正在被判的那张手牌, `held` 是全部留在手里的牌 —— 致胜之拳要看到整手才知道
    /// 哪张点数最小. 这个阶段排在逐卡计分之后, 主效果之前.
    pub fn held(
        &self,
        other: &HandCard,
        held: &[HandCard],
        ctx: &TriggerContext,
        rng: &mut crate::rng::Rng,
    ) -> Option<JokerEffect> {
        match self.key.as_str() {
            // 模仿: 把手里这张牌**自己的**效果再触发一次 —— 实现上就是把它那个乘倍率再乘一遍.
            // 手里牌的效果主要就是钢铁牌那一类 (×1.5), 照这样再乘一次正好是 ×1.5 两次.
            "j_mime" => {
                let again = other.h_x_mult();
                if again > 0.0 {
                    return Some(JokerEffect {
                        xmult_mod: again,
                        ..JokerEffect::default()
                    });
                }
            }
            // 预留车位: 手里每张**人头牌**各掷一次 (键 `parking`, 概率 1/odds), 中了给一块.
            // 位置就在"手牌那一趟", 与游戏一致; 而且**先看牌面再掷** —— 顺序反了随机序列就错.
            "j_reserved_parking" => {
                if ctx.is_face(other) {
                    let odds = self.extra_number("odds");
                    if odds > 0.0
                        && rng.pseudorandom("parking") < (1.0 + ctx.probability_extra) / odds
                    {
                        return Some(JokerEffect {
                            dollars: self.extra_number("dollars"),
                            ..JokerEffect::default()
                        });
                    }
                    // 没掷中也要**掷过了**: 上面那次 `pseudorandom` 已经推进了随机序列.
                }
            }
            // 射月: 手里每张 Q 给 +13 倍率.
            "j_shoot_the_moon" => {
                if other.card.rank == Rank::Queen && !other.debuffed {
                    return Some(JokerEffect {
                        mult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 男爵: 手里每张 K 给 x1.5.
            "j_baron" => {
                if other.card.rank == Rank::King && !other.debuffed {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 钢铁小丑: 手里每张钢铁牌让倍率乘 1.2 (即 `1 + 0.2 x 张数`).
            // 它看的是**手里**的钢铁牌, 所以走这一阶段而不是主效果.
            "j_steel_joker" => {
                if other.h_x_mult > 0.0 {
                    return Some(JokerEffect {
                        xmult_mod: 1.0 + self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 致胜之拳: 只有手里**点数最小**的那张给 "两倍点数" 的倍率.
            //
            // 游戏那边是从头扫一遍, 只在"更小"时替换, 所以同点数时留下的是靠左的那张;
            // 石头牌被排除在外 (它没有点数).
            "j_raised_fist" => {
                let smallest = held
                    .iter()
                    .filter(|card| !card.stone)
                    .min_by(|a, b| a.card.rank.pip().cmp(&b.card.rank.pip()))?;
                if std::ptr::eq(smallest, other) && !other.debuffed {
                    return Some(JokerEffect {
                        mult_mod: 2.0 * other.card.rank.nominal(),
                        ..JokerEffect::default()
                    });
                }
            }
            _ => {}
        }
        None
    }

    /// 幸运猫的成长: 一张**刚成功触发过**的幸运牌被计分时涨一份乘倍率.
    ///
    /// 这条不在 `individual` 的返回值里, 因为它是**改自己**而不是给这一手加分:
    /// 涨完的值由稍后的主效果 (泛化的 `x_mult > 1` 那一条) 读走, 所以同一手就生效.
    /// 游戏那边写在 `context.individual` 分支里, 判的是同一张牌上的 `lucky_trigger` 标志;
    /// 被削弱的幸运猫不长 (`Card:calculate_joker` 开头就挡掉), 别的小丑也不长.
    ///
    /// 返回是否真的涨了, 数值本身已经写回 `self` (给调用方和测试看的只是这个判断).
    pub fn grow_on_lucky_trigger(&mut self) -> bool {
        if self.debuffed || self.key != "j_lucky_cat" {
            return false;
        }
        let step = self.extra_number("extra");
        if step == 0.0 {
            return false;
        }
        self.x_mult += step;
        true
    }

    /// 逐张计分牌触发 (`context.individual`).
    ///
    /// 与 `joker_main` 的区别在于**粒度**: 这里对每一张参与计分的牌各判一次, 而不是整手判一次.
    /// 笑脸与奇数托德都走这条, 所以它们的效果随计分牌张数增长.
    pub fn individual(
        &self,
        card: &HandCard,
        ctx: &TriggerContext,
        rng: &mut crate::rng::Rng,
    ) -> Option<JokerEffect> {
        match self.key.as_str() {
            // 特里布莱 (传奇): 每张计分的 **K 或 Q** 乘一次倍率 (2 倍).
            // 它在**逐张**那一趟里, 所以打出 K 和 Q 的两对会被乘四次.
            "j_triboulet" => {
                if matches!(card.card.rank, Rank::King | Rank::Queen) {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 血石: 每张**红桃**计分时掷一次 (1/2), 中了乘 1.5 倍.
            // 队里有几张血石就各掷各的, 所以掷骰放在这里 (而不是由调用方预掷).
            "j_bloodstone" => {
                if card.card.suit == Suit::Hearts {
                    let odds = self.extra_number("odds");
                    if odds > 0.0
                        && rng.pseudorandom("bloodstone") < (1.0 + ctx.probability_extra) / odds
                    {
                        return Some(JokerEffect {
                            xmult_mod: self.extra_number("Xmult"),
                            ..JokerEffect::default()
                        });
                    }
                }
            }
            // 生意: 每张**人头牌**计分时掷一次 (1/2), 中了给两块.
            // 分子是 `G.GAME.probabilities.normal`, 不能写死成 1 (七上八下会把它乘二).
            "j_business" => {
                let odds = self.extra;
                if ctx.is_face(card)
                    && odds > 0.0
                    && rng.pseudorandom("business") < (1.0 + ctx.probability_extra) / odds
                {
                    return Some(JokerEffect {
                        dollars: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 璞玉: 每张**方片**计分时给一块钱 (游戏那边走 `p_dollars`).
            "j_rough_gem" => {
                if card.card.suit == Suit::Diamonds {
                    return Some(JokerEffect {
                        dollars: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 缟玛瑙: 每张**梅花**计分时给 +7 倍率.
            "j_onyx_agate" => {
                if card.card.suit == Suit::Clubs {
                    return Some(JokerEffect {
                        mult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 箭头: 每张**黑桃**计分时给 +50 筹码.
            "j_arrowhead" => {
                if card.card.suit == Suit::Spades {
                    return Some(JokerEffect {
                        chip_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 照片: 这一手里**第一张人头牌**被计分时给乘倍率.
            // 游戏那边每张牌都从头扫一遍计分名单找"第一张人头牌", 这里照做.
            "j_photograph" => {
                let first = ctx
                    .scoring
                    .iter()
                    .find(|view| ctx.is_face(view));
                if first.is_some_and(|view| view.card == card.card) {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 笑脸: 每张人头牌给 +5 倍率.
            "j_smiley" => {
                if ctx.is_face(card) {
                    return Some(JokerEffect {
                        mult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 斐波那契: 点数为 A / 2 / 3 / 5 / 8 的牌各给 +8 倍率.
            "j_fibonacci" => {
                let pip = card.card.rank.pip();
                if matches!(pip, 1 | 2 | 3 | 5 | 8 | 14) {
                    return Some(JokerEffect {
                        mult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 恐怖面孔: 每张人头牌给 +30 筹码.
            "j_scary_face" => {
                if ctx.is_face(card) {
                    return Some(JokerEffect {
                        chip_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 偶数史蒂文: 偶数点的牌各给 +4 倍率 (人头牌不算, 它们的点数序号是 11 到 13).
            "j_even_steven" => {
                let pip = card.card.rank.pip();
                if pip <= 10 && pip.is_multiple_of(2) {
                    return Some(JokerEffect {
                        mult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 学者: 每张 A 给 +20 筹码与 +4 倍率.
            "j_scholar" => {
                if card.card.rank == Rank::Ace {
                    return Some(JokerEffect {
                        chip_mod: self.extra_number("chips"),
                        mult_mod: self.extra_number("mult"),
                        ..JokerEffect::default()
                    });
                }
            }
            // 对讲机: 点数为 10 或 4 的牌各给 +10 筹码与 +4 倍率.
            "j_walkie_talkie" => {
                if matches!(card.card.rank, Rank::Ten | Rank::Four) {
                    return Some(JokerEffect {
                        chip_mod: self.extra_number("chips"),
                        mult_mod: self.extra_number("mult"),
                        ..JokerEffect::default()
                    });
                }
            }
            // 四张花色小丑 (贪婪 / 色欲 / 愤怒 / 暴食): 每张该花色的计分牌给 +3 倍率.
            // 它们的原型都带 `extra.suit`, 所以按花色取, 不写死四个分支.
            "j_greedy_joker" | "j_lusty_joker" | "j_wrathful_joker" | "j_gluttenous_joker" => {
                if let Some(suit) = self.extra_suit()
                    && card.card.suit == suit
                {
                    return Some(JokerEffect {
                        mult_mod: self.extra_number("s_mult"),
                        ..JokerEffect::default()
                    });
                }
            }
            // 爱豆: 每张**正好是它这一回合盯的那张牌**的计分牌各乘一次 `extra` (2).
            "j_idol" => {
                if let Some((suit, rank)) = ctx.idol_card
                    && card.card.suit == suit
                    && card.card.rank == rank
                {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 八号球: 每张**计分**的 8 各掷一次 (键 `8ball`, 概率 1/4), 中了造一张塔罗.
            // 先看消耗槽有没有位子 —— 没位子时**连骰子都不掷**, 顺序反了随机序列就不一样.
            "j_8_ball" => {
                if card.card.rank == Rank::Eight && ctx.consumable_room > 0 {
                    let odds = self.extra;
                    if odds > 0.0
                        && rng.pseudorandom("8ball") < (1.0 + ctx.probability_extra) / odds
                    {
                        return Some(JokerEffect {
                            create_consumable: Some(("Tarot", "8ba")),
                            ..JokerEffect::default()
                        });
                    }
                }
            }
            // 金票: 每张**计分**的黄金牌给 4 块.
            "j_ticket" => {
                if card.gold {
                    return Some(JokerEffect {
                        dollars: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 上古小丑: 每张**这一回合定的花色**的计分牌各乘一次 `extra` (1.5).
            // 它和城堡一样在回合开始掷花色, 只是城堡管弃牌、它管计分.
            "j_ancient" => {
                if let Some(suit) = ctx.ancient_suit
                    && card.card.suit == suit
                {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 奇数托德: 点数为 3 / 5 / 7 / 9 或 A 的牌各给 +31 筹码.
            // A 要单独列出来 —— 它的点数序号是 14, 不满足"落在 3..9 的奇数"那一条.
            "j_odd_todd" => {
                let pip = card.card.rank.pip();
                if (pip <= 10 && pip % 2 == 1) || pip == 14 {
                    return Some(JokerEffect {
                        chip_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            _ => {}
        }
        None
    }

    /// 主效果 (`joker_main`).
    ///
    /// 顺序照 `Card:calculate_joker`: 先看 `x_mult`, 再看 `t_mult` / `t_chips`,
    /// 最后才是具名分支. 命中就返回, 不再往下判.
    pub fn joker_main(
        &self,
        ctx: &TriggerContext,
        rng: &mut crate::rng::Rng,
    ) -> Option<JokerEffect> {
        if self.debuffed {
            return None;
        }

        // `ability.x_mult > 1`: 泛化分支, 任何满足的小丑都走这里.
        if self.key != "j_seeing_double" && self.x_mult > 1.0 && self.matches_hand(ctx.hands) {
            return Some(JokerEffect {
                xmult_mod: self.x_mult,
                ..JokerEffect::default()
            });
        }

        // 看**局面**而不是看牌的那几张: 它们各自读一个当前值.
        match self.key.as_str() {
            // 旗帜: 每剩一次弃牌给 +30 筹码.
            "j_banner" => {
                return Some(JokerEffect {
                    chip_mod: self.extra * ctx.discards_left.max(0) as f64,
                    ..JokerEffect::default()
                });
            }
            // 神秘之峰: 一次弃牌都没剩时给 +15 倍率.
            "j_mystic_summit" => {
                if ctx.discards_left <= 0 {
                    return Some(JokerEffect {
                        mult_mod: self.extra_number("mult"),
                        ..JokerEffect::default()
                    });
                }
            }
            // 斗牛: 每块钱给 +2 筹码 (欠钱时按 0 算).
            "j_bull" => {
                return Some(JokerEffect {
                    chip_mod: self.extra * ctx.dollars.max(0.0),
                    ..JokerEffect::default()
                });
            }
            // 积分卡: 拿到之后每打六手给一次 x4, 落在第 5 / 11 / 17 ... 手上.
            // 游戏那边的算式是 `(4 - n) % 6 == 5`, 而 Lua 的取模结果跟模数同号,
            // 化简下来就是 `n % 6 == 5`.
            "j_loyalty_card" => {
                let every = self.extra_number("every") as u32;
                if every > 0 && self.hands_since_gained % (every + 1) == every {
                    return Some(JokerEffect {
                        xmult_mod: self.extra_number("Xmult"),
                        ..JokerEffect::default()
                    });
                }
            }
            // 特技演员: 固定 +250 筹码 (代价是手牌上限减二, 那一笔在进场时算).
            "j_stuntman" => {
                return Some(JokerEffect {
                    chip_mod: self.extra_number("chip_mod"),
                    ..JokerEffect::default()
                });
            }
            // 石头小丑: 整副牌里每张**石头牌**给 +25 筹码 (口径是"这一局还活着的全部牌").
            "j_stone" => {
                return Some(JokerEffect {
                    chip_mod: self.extra * ctx.deck_stones as f64,
                    ..JokerEffect::default()
                });
            }
            // 侵蚀: 比**开局那副牌**少几张就给几份倍率 (打出去又被销毁的牌才算少).
            "j_erosion" => {
                let missing = ctx.starting_deck_size.saturating_sub(ctx.deck_total);
                if missing > 0 {
                    return Some(JokerEffect {
                        mult_mod: self.extra * missing as f64,
                        ..JokerEffect::default()
                    });
                }
            }
            // 驾照: 整副牌里有 **16 张以上**带强化 (非基础) 的牌时乘三倍.
            "j_drivers_license" => {
                if ctx.deck_enhanced >= 16 {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 印错: 每次触发从 0 到 23 之间**取一个整数**加进倍率 (键 `misprint`).
            // 它是整数不是小数, 所以要用 `pseudorandom_int_range`.
            "j_misprint" => {
                let min = self.extra_number("min");
                let max = self.extra_number("max");
                return Some(JokerEffect {
                    mult_mod: rng.pseudorandom_int_range("misprint", min, max),
                    ..JokerEffect::default()
                });
            }
            // 大麦克: 固定 +15 倍率 (它在回合末还有一次 1/6 的销毁骰, 那笔不在这里).
            "j_gros_michel" => {
                return Some(JokerEffect {
                    mult_mod: self.extra_number("mult"),
                    ..JokerEffect::default()
                });
            }
            // 爆米花: 加的是**成长值** (每回合末掉 4 点, 掉完就没了).
            "j_popcorn" => {
                if self.mult > 0.0 {
                    return Some(JokerEffect {
                        mult_mod: self.mult,
                        ..JokerEffect::default()
                    });
                }
            }
            // 眼观双路: 计分牌里**有梅花, 而且红桃 / 方片 / 黑桃里至少还有一种**时乘两倍.
            //
            // 注意它**不是**"四种花色齐" (那是花盆) —— 源码里的判据是
            // `(红桃 > 0 或 方片 > 0 或 黑桃 > 0) 且 梅花 > 0`.
            // 百搭牌不直接算数, 而是按"梅花 -> 方片 -> 黑桃 -> 红桃"的顺序去**补还缺的那种**,
            // 每张只补一种. 少了这一步, 手里有百搭牌时就会判错.
            "j_seeing_double" => {
                let mut counts: [usize; 4] = [0; 4];
                let index = |suit: Suit| Suit::ALL.iter().position(|s| *s == suit).expect("四种之一");
                // 第一趟: 百搭牌不参与.
                for card in ctx.scoring {
                    if !card.wild && !card.debuffed {
                        counts[index(card.card.suit)] += 1;
                    }
                }
                // 第二趟: 每张百搭牌补一种还缺的花色.
                for card in ctx.scoring {
                    if card.wild && !card.debuffed {
                        for suit in [Suit::Clubs, Suit::Diamonds, Suit::Spades, Suit::Hearts] {
                            if counts[index(suit)] == 0 {
                                counts[index(suit)] = 1;
                                break;
                            }
                        }
                    }
                }
                let others =
                    counts[index(Suit::Hearts)] + counts[index(Suit::Diamonds)] + counts[index(Suit::Spades)];
                if counts[index(Suit::Clubs)] > 0 && others > 0 {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 花盆: **参与计分的牌**凑齐四种花色时乘三倍. 百搭牌不算数 (游戏那边显式跳过
            // `Wild Card`), 因为它的花色是随场景变的.
            "j_flower_pot" => {
                let all = [
                    Suit::Spades,
                    Suit::Hearts,
                    Suit::Diamonds,
                    Suit::Clubs,
                ]
                .iter()
                .all(|suit| {
                    ctx.scoring
                        .iter()
                        .any(|card| !card.wild && card.card.suit == *suit)
                });
                if all {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 提靴带: 每满五块钱给 +2 倍率 (取整, 不满五块的那部分不算).
            "j_bootstraps" => {
                let step = self.extra_number("dollars");
                let times = (ctx.dollars / step).floor();
                if times >= 1.0 {
                    return Some(JokerEffect {
                        mult_mod: self.extra_number("mult") * times,
                        ..JokerEffect::default()
                    });
                }
            }
            // 杂技演员: 这一回合的**最后一手**乘三倍. 出牌次数是在算分前减的,
            // 所以最后一手在这里看到的是 0.
            "j_acrobat" => {
                if ctx.hands_left <= 0 {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 模具小丑: 空着的小丑格子有几个就乘几倍, 再加上"队里模具小丑的张数" ——
            // 每张模具自己也算一格, 所以它在队里时那个空位没有被浪费.
            "j_stencil" => {
                let empty = ctx.joker_capacity.saturating_sub(ctx.joker_count);
                let factor = empty + ctx.stencil_count;
                if factor > 0 {
                    return Some(JokerEffect {
                        xmult_mod: factor as f64,
                        ..JokerEffect::default()
                    });
                }
            }
            // 半张小丑: 打出的牌**不超过三张**时给 +20 倍率.
            "j_half" => {
                if ctx.full_hand_len <= self.extra_number("size") as usize {
                    return Some(JokerEffect {
                        mult_mod: self.extra_number("mult"),
                        ..JokerEffect::default()
                    });
                }
            }
            // 黑板: 手里**每一张**都是黑桃或梅花时乘倍率.
            // 手里一张牌都没有时游戏那边的判据 (`黑牌数 == 总牌数`) 也成立, 这里照做.
            "j_blackboard" => {
                if ctx
                    .held
                    .iter()
                    .all(|card| matches!(card.card.suit, Suit::Spades | Suit::Clubs))
                {
                    return Some(JokerEffect {
                        xmult_mod: self.extra,
                        ..JokerEffect::default()
                    });
                }
            }
            // 超新星: 这一手牌型**本局打过几次**就加几点倍率.
            // 原型里的 `extra` 是 1, 但源码给的是 `played` 本身而不是 `played x extra`.
            // 游戏在 `evaluate_play` 开头就给本次牌型记过一次 (`state_events.lua` L574),
            // 所以它读到的是**含这一手**的次数; 引擎在计分之后才累加, 这里补上那一次.
            "j_supernova" => {
                return Some(JokerEffect {
                    mult_mod: f64::from(ctx.table.get(ctx.hand).played + 1),
                    ..JokerEffect::default()
                });
            }
            // 蓝色小丑: 牌堆里每张牌给 +2 筹码.
            "j_blue_joker" => {
                return Some(JokerEffect {
                    chip_mod: self.extra * ctx.deck_len as f64,
                    ..JokerEffect::default()
                });
            }
            // 抽象小丑: 每持有一张小丑 (含它自己) 给 +3 倍率.
            // `joker_count` 是 `usize`, 不会小于零, 所以不用再夹一次.
            "j_abstract" => {
                return Some(JokerEffect {
                    mult_mod: self.extra * ctx.joker_count as f64,
                    ..JokerEffect::default()
                });
            }
            _ => {}
        }

        // 醋栗 (Cavendish): 无条件乘 3 倍. 它的数值在 `extra` **里面** (`{"Xmult": 3}`),
        // 所以走的不是上面那条读顶层 `Xmult` 的通用分支 —— 那一类还有 17 张, 见文档.
        if self.key == "j_cavendish" {
            return Some(JokerEffect {
                xmult_mod: self.extra_number("Xmult"),
                ..JokerEffect::default()
            });
        }
        // 牌卡夏普 (Card Sharp): **这一手型本回合已经打过**时乘 3 倍.
        // 游戏那边是 `hands[scoring_name].played_this_round > 1` (含这一手), 而引擎在计分**之后**
        // 才累加计数, 所以这里判 "之前打过至少一次" —— 两者等价.
        if self.key == "j_card_sharp" && ctx.played_this_round >= 1 {
            return Some(JokerEffect {
                xmult_mod: self.extra_number("Xmult"),
                ..JokerEffect::default()
            });
        }

        // 叠加态: 这一手**包含顺子**而且**计分牌里至少有一张 A** ⇒ 造一张塔罗.
        // 两个条件都读计分那一层的既有信息 (`hands` 是这一手满足的全部牌型, `scoring` 是计分牌).
        // 同样先看消耗槽有没有位子 —— 没位子时连"要不要造"都不判, 也就不掷骰.
        if self.key == "j_superposition" && ctx.consumable_room > 0 {
            let aces = ctx
                .scoring
                .iter()
                .filter(|card| card.card.rank == Rank::Ace)
                .count();
            if aces >= 1 && ctx.hands.has(PokerHand::Straight) {
                return Some(JokerEffect {
                    create_consumable: Some(("Tarot", "sup")),
                    ..JokerEffect::default()
                });
            }
        }

        // 通灵: 打出的牌型正好是配置里指定的那个 ⇒ 造一张幽灵牌.
        // 认牌型用配置里那个名字 (`extra.poker_hand`), 与牌型自己的名字对得上才生效.
        if self.key == "j_seance" && ctx.consumable_room > 0 {
            let wanted = self
                .config
                .get("extra")
                .and_then(|extra| extra.get("poker_hand"))
                .and_then(Json::as_str);
            if wanted.is_some_and(|name| name == ctx.hand.info().key) {
                return Some(JokerEffect {
                    create_consumable: Some(("Spectral", "sea")),
                    ..JokerEffect::default()
                });
            }
        }

        // `t_mult` / `t_chips`: 牌型匹配才生效 (j_zany, j_crafty 这一批).
        if self.t_mult > 0.0 && self.matches_hand(ctx.hands) {
            return Some(JokerEffect {
                mult_mod: self.t_mult,
                ..JokerEffect::default()
            });
        }
        if self.t_chips > 0.0 && self.matches_hand(ctx.hands) {
            return Some(JokerEffect {
                chip_mod: self.t_chips,
                ..JokerEffect::default()
            });
        }

        // 具名分支: 卡尼奥的成长倍率.
        if self.key == "j_caino" && self.caino_xmult > 1.0 {
            return Some(JokerEffect {
                xmult_mod: self.caino_xmult,
                ..JokerEffect::default()
            });
        }

        // 成长出来的筹码. **只有**那几张把 `extra.chips` 当成长值的才走这里 ——
        // 学者与对讲机的 `extra` 也是 `{chips, mult}` 这个形状, 但那是"给特定牌的固定值",
        // 由它们各自的逐卡分支处理. 早先这里无条件加, 结果学者给每张牌都加了 20.
        if self.chips > 0.0
            && matches!(
                self.key.as_str(),
                "j_square" | "j_runner" | "j_ice_cream" | "j_castle" | "j_wee"
            )
        {
            return Some(JokerEffect {
                chip_mod: self.chips,
                ..JokerEffect::default()
            });
        }

        // `ability.mult`: 基础倍率加成. 原版里每个这类小丑都有一条具名分支,
        // 效果一样, 所以这里按"有成长值就加"处理.
        if self.mult > 0.0 {
            return Some(JokerEffect {
                mult_mod: self.mult,
                ..JokerEffect::default()
            });
        }

        None
    }
}
