//! 给 agent 看的局面摘要.
//!
//! 对照内置 agent 的 `mods/balatrobot/agent/loop/summary.lua`: 每张牌都带中文名与效果文本,
//! 还有牌型等级, 盲注效果, 跳过奖励, 上一手的明细.
//!
//! 与内置 agent 的一处不同: 那个 agent 是一段连续对话, 能把"每张牌只介绍一次"记在会话里;
//! 这里是每步一次独立进程, 没有记忆可留, 所以每次都写全. 省 token 该做在 agent 那一侧.

use crate::cards::{CardInstance, Edition, Enhancement, Seal, Suit};
use crate::data::knowledge;
use crate::jokers::Joker;
use crate::run::shop::PackCard;
use crate::run::{BlindKind, Phase, RunState, ShopCard, blind, make_blind};
use crate::scoring::PokerHand;

/// 摘要之外要带进来的东西 —— 引擎的运行状态里没有, 得由调用方给.
#[derive(Default)]
pub struct Extras<'a> {
    /// 上一手的计分明细 (一行一行的那种). 由调用方从 `ScoreResult` 渲染好带进来.
    pub last_hand: Option<&'a str>,
    /// 额外说明, 例如"刚才这一步自动处理了什么".
    pub note: Option<&'a str>,
}

fn suit_zh(suit: Suit) -> &'static str {
    match suit {
        Suit::Clubs => "梅花",
        Suit::Diamonds => "方片",
        Suit::Hearts => "红桃",
        Suit::Spades => "黑桃",
    }
}

fn rank_zh(rank: crate::cards::Rank) -> &'static str {
    use crate::cards::Rank::*;
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

fn enhancement_zh(value: Enhancement) -> &'static str {
    match value {
        Enhancement::Bonus => "奖励牌",
        Enhancement::Mult => "倍率牌",
        Enhancement::Wild => "万能牌",
        Enhancement::Glass => "玻璃牌",
        Enhancement::Steel => "钢铁牌",
        Enhancement::Stone => "石头牌",
        Enhancement::Gold => "黄金牌",
        Enhancement::Lucky => "幸运牌",
    }
}

fn edition_zh(value: Edition) -> &'static str {
    match value {
        Edition::Foil => "闪箔",
        Edition::Holo => "镭射",
        Edition::Polychrome => "多彩",
        Edition::Negative => "负片",
    }
}

fn seal_zh(value: Seal) -> &'static str {
    match value {
        Seal::Red => "红色蜡封",
        Seal::Blue => "蓝色蜡封",
        Seal::Gold => "金色蜡封",
        Seal::Purple => "紫色蜡封",
    }
}

/// 牌型的中文名. 对照 `summary.lua` 的 `HAND_ZH`.
pub fn hand_zh(hand: PokerHand) -> &'static str {
    match hand {
        PokerHand::FlushFive => "同花五条",
        PokerHand::FlushHouse => "同花葫芦",
        PokerHand::FiveOfAKind => "五条",
        PokerHand::StraightFlush => "同花顺",
        PokerHand::FourOfAKind => "四条",
        PokerHand::FullHouse => "葫芦",
        PokerHand::Flush => "同花",
        PokerHand::Straight => "顺子",
        PokerHand::ThreeOfAKind => "三条",
        PokerHand::TwoPair => "两对",
        PokerHand::Pair => "对子",
        PokerHand::HighCard => "高牌",
    }
}

/// 阶段的中文名. 键名与游戏一致, 便于对着回放文件看.
pub fn phase_zh(phase: Phase) -> &'static str {
    match phase {
        Phase::BlindSelect => "选择盲注",
        Phase::SelectingHand => "出牌",
        Phase::RoundEval => "结算",
        Phase::Shop => "商店",
        Phase::BoosterOpened => "打开补充包",
        Phase::GameOver => "游戏结束",
    }
}

/// 一张牌的中文名与效果. 手册里查不到时退回内部键名 —— 至少不假装知道.
fn name_and_effect(key: &str) -> (String, String) {
    match knowledge::describe(key) {
        Some((name, effect)) => (name.to_owned(), effect.to_owned()),
        None => (key.to_owned(), String::new()),
    }
}

/// 修饰后缀: 强化, 版本, 蜡封, 永恒 / 易腐 / 租赁. 没有时给空串.
fn card_modifiers(
    enhancement: Option<Enhancement>,
    edition: Option<Edition>,
    seal: Option<Seal>,
    eternal: bool,
    perish_tally: i64,
    rental: bool,
    debuffed: bool,
) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(value) = enhancement {
        parts.push(enhancement_zh(value).to_owned());
    }
    if let Some(value) = edition {
        parts.push(edition_zh(value).to_owned());
    }
    if let Some(value) = seal {
        parts.push(seal_zh(value).to_owned());
    }
    if eternal {
        parts.push("永恒".to_owned());
    }
    if perish_tally > 0 {
        parts.push(format!("易腐 {perish_tally} 回合"));
    }
    if rental {
        parts.push("租赁".to_owned());
    }
    if debuffed {
        parts.push("被削弱".to_owned());
    }
    if parts.is_empty() {
        String::new()
    } else {
        format!(" ({})", parts.join(", "))
    }
}

/// 一张扑克牌: `红桃A (倍率牌, 闪箔)`, 并单独给出计分筹码.
fn playing_card(card: &CardInstance) -> String {
    let base = format!("{}{}", suit_zh(card.card.suit), rank_zh(card.card.rank));
    let tail = card_modifiers(
        card.enhancement,
        card.edition,
        card.seal,
        false,
        0,
        false,
        card.debuffed,
    );
    format!("{base}{tail}")
}

/// 小丑身上的**当前值**. 手册里带 `[...]` 占位的那种效果要靠它才对得上实际行为.
///
/// 只写**会变**的那几项, 判断基线与字段的初值一致 (见 `Jokers::new`):
///
/// - `t_mult` / `t_chips` 不写: 它们只从原型一次性带进来, 全程不变, 手册的效果文本里已经有了,
///   再报一遍只是噪声.
/// - `caino_xmult` 单独判: 它不是"默认 1", 而是**只有卡尼奥才有意义** (别的牌是 0),
///   拿 `!= 1.0` 当判据会把每一张小丑都误报成"已成长".
/// - `hands_since_gained` 只有积分卡按它循环, 所以只对那张牌报.
pub fn joker_current(joker: &Joker) -> String {
    let mut parts: Vec<String> = Vec::new();
    if joker.mult != 0.0 {
        parts.push(format!("+{} 倍率", number(joker.mult)));
    }
    if joker.x_mult != 1.0 {
        parts.push(format!("X{} 倍率", number(joker.x_mult)));
    }
    if joker.chips != 0.0 {
        parts.push(format!("+{} 筹码", number(joker.chips)));
    }
    if joker.key == "j_caino" {
        parts.push(format!("已成长到 X{} 倍率", number(joker.caino_xmult)));
    }
    if joker.extra_value != 0.0 {
        parts.push(format!("卖出价加成 +{}", number(joker.extra_value)));
    }
    if joker.invis_rounds != 0.0 {
        parts.push(format!("已过 {} 回合", number(joker.invis_rounds)));
    }
    if joker.yorick_discards != 0.0 {
        parts.push(format!("还差 {} 次弃牌", number(joker.yorick_discards)));
    }
    if joker.key == "j_loyalty_card" && joker.hands_since_gained > 0 {
        parts.push(format!("到手后出过 {} 手", joker.hands_since_gained));
    }
    if parts.is_empty() {
        String::new()
    } else {
        parts.join(", ")
    }
}

/// 价格与整数的显示: 不要 `3.0` 这种尾巴.
pub fn number(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        format!("{value}")
    }
}

/// 一行非扑克牌: `名字 (修饰) $价: 效果`.
fn item_line(
    key: &str,
    modifiers: &str,
    price: Option<String>,
    live: &str,
) -> String {
    let (name, effect) = name_and_effect(key);
    let mut line = format!("{name}{modifiers}");
    if let Some(price) = price {
        line.push_str(&format!(" {price}"));
    }
    // 手册里带 `[` 的是"会变的占位"; 那种效果自带实时值, 附在后面才对得上实际行为.
    let text = if knowledge::effect_is_dynamic(&effect) && !live.is_empty() {
        format!("{effect}  当前: {live}")
    } else if live.is_empty() {
        effect
    } else {
        format!("{effect}  当前: {live}")
    };
    if !text.is_empty() {
        line.push_str(": ");
        line.push_str(&text);
    }
    line
}

/// 商店 / 卡包里的一格 (它们与持有区的小丑字段形状不同).
fn shop_card_line(card: &ShopCard, prefix: &str, index: usize) -> String {
    let modifiers = card_modifiers(
        card.enhancement,
        card.edition,
        None,
        card.eternal,
        0,
        card.rental,
        false,
    );
    let mut price = format!("${}", number(card.cost));
    if card.perishable {
        price = format!("{price} [易腐]");
    }
    let todo = card
        .todo
        .map(|hand| format!("待办目标 {}", hand_zh(hand)))
        .unwrap_or_default();
    format!(
        "  {prefix}[{index}] {}",
        item_line(&card.key, &modifiers, Some(price), &todo)
    )
}

fn pack_card_line(card: &PackCard, index: usize) -> String {
    let modifiers = card_modifiers(
        card.enhancement,
        card.edition,
        card.seal,
        card.eternal,
        0,
        card.rental,
        false,
    );
    // 标准包里开出来的是扑克牌, 没有原型可查, 只剩点数和花色.
    if let Some(playing) = crate::cards::CardInstance::from_key(&card.key) {
        return format!("  [{index}] {}{modifiers}", playing_card(&playing));
    }
    let todo = card
        .todo
        .map(|hand| format!("待办目标 {}", hand_zh(hand)))
        .unwrap_or_default();
    format!("  [{index}] {}", item_line(&card.key, &modifiers, None, &todo))
}

/// 这一底里第 `index` 个盲注的原型键 (小 0 / 大 1 / Boss 2). 拿不到时给 `None`.
///
/// Boss 的键是每底抽出来的, 存在 `boss_key` 里; 小盲注与大盲注是固定原型.
fn blind_key_of(run: &RunState, index: usize) -> Option<String> {
    match index {
        0 => Some(blind::plain_blind_key(BlindKind::Small).to_owned()),
        1 => Some(blind::plain_blind_key(BlindKind::Big).to_owned()),
        2 => run.boss_key.clone(),
        _ => None,
    }
}

/// 还没开始的那个盲注的目标分与奖金.
///
/// 盲注对象要等 `select` 那一刻才造出来, 所以选盲注阶段得**按同样的规则先算一遍**才能报目标 ——
/// 这也正是 agent 决定要不要跳过时要看的东西. 算法直接复用 `make_blind`, 不另写一份.
fn projected_blind(run: &RunState, key: &str) -> (f64, f64) {
    let blind = make_blind(
        run.blind_on_deck,
        key,
        run.ante,
        run.scaling,
        run.ante_scaling,
        run.no_blind_reward,
    );
    (blind.chips, blind.dollars)
}

/// 盲注的进行状态. `index` 是这一底里的第几个 (小 0 / 大 1 / Boss 2).
fn blind_status(run: &RunState, index: usize) -> &'static str {
    let current = match run.blind_on_deck {
        BlindKind::Small => 0,
        BlindKind::Big => 1,
        BlindKind::Boss => 2,
    };
    // 盲注是**打赢那一刻**就被清空的, 而 `blind_on_deck` 要到 `next_round` (离开商店) 才轮到
    // 下一个. 所以"这一格正在打"还是"已经打完"要看阶段:
    // 商店与开包阶段说明刚打完, 出牌与结算说明正在打, 选盲注说明还没开始.
    match run.phase {
        Phase::BlindSelect => match index.cmp(&current) {
            std::cmp::Ordering::Less => skipped_or_beaten(run, index),
            std::cmp::Ordering::Equal => "待选择",
            std::cmp::Ordering::Greater => "未到",
        },
        Phase::SelectingHand | Phase::RoundEval => match index.cmp(&current) {
            std::cmp::Ordering::Less => skipped_or_beaten(run, index),
            std::cmp::Ordering::Equal => "进行中",
            std::cmp::Ordering::Greater => "未到",
        },
        Phase::Shop | Phase::BoosterOpened => match index.cmp(&current) {
            std::cmp::Ordering::Less => skipped_or_beaten(run, index),
            std::cmp::Ordering::Equal => "已击败",
            std::cmp::Ordering::Greater => "未到",
        },
        Phase::GameOver => "已过",
    }
}

/// 这一格是跳过还是打赢了. 判据是它的跳过标签**还在不在** —— 标签在开局与每底提升时抽好,
/// 被 `skip_blind` 取走才置空, 所以空了就是跳过过.
fn skipped_or_beaten(run: &RunState, index: usize) -> &'static str {
    match run.blind_tags.get(index) {
        Some(None) => "已跳过",
        _ => "已击败",
    }
}

/// 渲染整个局面. 只写**决策要用**的东西, 而且凡是有值的都写出来, 不做"首次介绍"的省略.
pub fn render(run: &RunState, extras: &Extras) -> String {
    let mut out: Vec<String> = Vec::new();
    if let Some(note) = extras.note
        && !note.is_empty()
    {
        out.push(note.to_owned());
    }
    out.push(format!(
        "阶段: {} | 底注 {} 回合 {} | 金钱 ${}",
        phase_zh(run.phase),
        run.ante,
        run.round,
        number(run.dollars)
    ));

    // 盲注三项. 名字与效果都从手册来, 目标分与奖金用当前局面里的实时值.
    for (index, (kind, key)) in [
        (0usize, ("小盲注", blind_key_of(run, 0))),
        (1, ("大盲注", blind_key_of(run, 1))),
        (2, ("Boss", blind_key_of(run, 2))),
    ] {
        let Some(key) = key else { continue };
        let status = blind_status(run, index);
        let (name, effect) = name_and_effect(&key);
        let mut line = format!("{kind} {name}: {status}");
        // 目标分只对"正在打"或"待选择"的那一格有意义 —— 再往后的格子引擎没算, 硬报就是编.
        if matches!(status, "进行中" | "待选择") {
            if let Some(current) = run.blind.as_ref()
                && current.key == key
            {
                line.push_str(&format!(", 目标 {}", number(current.chips)));
                if current.dollars > 0.0 {
                    line.push_str(&format!(", 奖金 ${}", number(current.dollars)));
                }
            } else {
                let (target, reward) = projected_blind(run, &key);
                line.push_str(&format!(", 目标 {}", number(target)));
                if reward > 0.0 {
                    line.push_str(&format!(", 奖金 ${}", number(reward)));
                }
            }
        }
        if !effect.is_empty() {
            line.push_str(&format!(", 效果: {effect}"));
        }
        // 跳过奖励只在这一格**还能跳**的时候才有意义.
        if status == "待选择"
            && index < 2
            && let Some(Some(tag)) = run.blind_tags.get(index)
        {
            let (tag_name, _) = name_and_effect(tag);
            line.push_str(&format!(", 跳过奖励: {tag_name}"));
        }
        out.push(line);
    }

    match run.phase {
        Phase::SelectingHand | Phase::RoundEval => {
            out.push(format!(
                "本回合: 已得 {} 分, 剩余出牌 {} 次, 弃牌 {} 次",
                number(run.chips),
                run.hands_left,
                run.discards_left
            ));
        }
        _ => {
            out.push(format!(
                "这一回合会给: 出牌 {} 次, 弃牌 {} 次, 手牌上限 {} 张, 一次最多出 5 张",
                run.hands_per_round,
                run.discards_per_round,
                run.hand_size()
            ));
        }
    }

    if let Some(line) = extras.last_hand {
        out.push(format!("上一手: {line}"));
    }

    if !run.hand.is_empty() {
        let cards: Vec<String> = run
            .hand
            .iter()
            .enumerate()
            .map(|(index, card)| format!("[{index}]{}(筹码 {})", playing_card(card), number(card.to_hand_card().chip_bonus())))
            .collect();
        out.push(format!("手牌 (最多选 5 张): {}", cards.join(" ")));
    }

    if !run.jokers.is_empty() {
        out.push(format!(
            "小丑 ({}/{}):",
            run.jokers.len(),
            run.joker_capacity()
        ));
        for (index, joker) in run.jokers.iter().enumerate() {
            let modifiers = card_modifiers(
                None,
                joker.edition,
                None,
                joker.eternal,
                joker.perish_tally,
                joker.rental,
                joker.debuffed,
            );
            // 卖价: 游戏是 `max(1, floor(价/2))`, 再叠上成长出来的那份.
            let sell = ((joker.cost + joker.extra_value) / 2.0).floor().max(1.0);
            out.push(format!(
                "  [{index}] {}",
                item_line(
                    &joker.key,
                    &modifiers,
                    Some(format!("卖 ${}", number(sell))),
                    &joker_current(joker)
                )
            ));
        }
    }

    if !run.consumables.is_empty() {
        out.push(format!(
            "消耗牌 ({}/{}):",
            run.consumables.len(),
            run.consumable_capacity()
        ));
        for (index, card) in run.consumables.iter().enumerate() {
            let modifiers = card_modifiers(None, card.edition, None, false, 0, false, false);
            out.push(format!(
                "  [{index}] {}",
                item_line(&card.key, &modifiers, None, "")
            ));
        }
    }

    if run.phase == Phase::Shop
        && let Some(shop) = run.shop.as_ref()
    {
        if !shop.jokers.is_empty() {
            out.push("商店:".to_owned());
            for (index, card) in shop.jokers.iter().enumerate() {
                out.push(shop_card_line(card, "card ", index));
            }
        }
        let vouchers: Vec<&ShopCard> = shop
            .voucher
            .iter()
            .chain(shop.extra_voucher.iter())
            .collect();
        if !vouchers.is_empty() {
            out.push("优惠券:".to_owned());
            for (index, card) in vouchers.iter().enumerate() {
                out.push(shop_card_line(card, "voucher ", index));
            }
        }
        if !shop.packs.is_empty() {
            out.push("补充包:".to_owned());
            for (index, card) in shop.packs.iter().enumerate() {
                out.push(shop_card_line(card, "pack ", index));
            }
        }
        out.push(format!("刷新价格: ${}", number(run.reroll_cost())));
    }

    if run.phase == Phase::BoosterOpened
        && let Some(pack) = run.open_pack.as_ref()
    {
        let (pack_name, _) = name_and_effect(&pack.key);
        out.push(format!(
            "卡包内容 ({pack_name}, 还能挑 {} 张):",
            pack.choices_left
        ));
        for (index, card) in pack.contents.iter().enumerate() {
            out.push(pack_card_line(card, index));
        }
    }

    out.push(format!(
        "牌堆剩余 {} 张, 弃牌堆 {} 张",
        run.deck.len(),
        run.discard_pile.len()
    ));

    // 牌型: 只列等级高于 1 或这一局打过次的 —— 其余都是初始值, 列出来只是噪声.
    // `BY_PRIORITY` 是"强牌在前", 而游戏面板是"弱牌在前", 所以反过来走, 顺序与面板一致.
    let levels: Vec<PokerHand> = PokerHand::BY_PRIORITY
        .into_iter()
        .rev()
        .filter(|hand| {
            let level = run.hands.get(*hand);
            level.level > 1 || level.played > 0
        })
        .collect();
    if !levels.is_empty() {
        let parts: Vec<String> = levels
            .iter()
            .map(|hand| {
                let level = run.hands.get(*hand);
                let mut line = format!(
                    "{} Lv{} {}x{}",
                    hand_zh(*hand),
                    level.level,
                    number(level.chips(*hand)),
                    number(level.mult(*hand))
                );
                if level.played > 0 {
                    line.push_str(&format!(
                        " 已打{}(本回合{})",
                        level.played, level.played_this_round
                    ));
                }
                line
            })
            .collect();
        out.push(format!("牌型: {}", parts.join(", ")));
    }

    if !run.used_vouchers.is_empty() {
        let mut names: Vec<String> = run
            .used_vouchers
            .iter()
            .map(|key| name_and_effect(key).0)
            .collect();
        names.sort();
        out.push(format!("已有优惠券: {}", names.join(", ")));
    }

    // 持有的标签: 跳过盲注拿到的那些, 有些是"之后某刻生效", 所以 agent 要知道自己拿着什么.
    if !run.tags.is_empty() {
        let names: Vec<String> = run
            .tags
            .iter()
            .map(|key| name_and_effect(key).0)
            .collect();
        out.push(format!("持有标签: {}", names.join(", ")));
    }

    out.join("\n")
}

/// 上一手的计分明细, 从一次出牌的结果渲染成几行.
///
/// 对应内置 agent 拿到的 `round.last_hand.text` —— 那一手每个来源各加了多少.
/// 没有它, agent 只能看到一个总分, 无法知道"为什么是这个分", 也就无法从错误中调整.
pub fn scoring_breakdown(hand: PokerHand, base_chips: f64, base_mult: f64, chips: f64, mult: f64, total: f64) -> String {
    format!(
        "{} 基础 {}x{} = {}x{} = {} 分",
        hand_zh(hand),
        number(base_chips),
        number(base_mult),
        number(chips),
        number(mult),
        number(total)
    )
}
