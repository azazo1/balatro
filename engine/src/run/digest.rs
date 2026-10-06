//! 与游戏对拍用的**状态摘要** (`digest`).
//!
//! 游戏那边由 `bbreplay` 的 `replay/format.lua` 生成同一个格式: 一行由空格分隔的
//! `键=值` 组成的摘要, 覆盖阶段, 底注, 回合, 钱, 牌堆张数, 手牌, 小丑, 消耗牌, 货架,
//! 券, 包, 包里还有什么.
//!
//! # 为什么它在库里, 而不在测试里
//!
//! 它是**与游戏之间的接口约定**, 有两类使用者:
//!
//! - 对拍测试 (`engine/tests/dump_replay.rs`): 拿录像里记的 digest 比对自己的;
//! - 生成器 (`engine/examples/gen_replay.rs`): 把**自己预测的** digest 写进回放文件,
//!   于是游戏重放时会**逐步核对** —— 那是"引擎先猜, 游戏来判"的闭环.
//!
//! 放在测试里的话, 生成器就用不上了, 只能各写一份; 而两份格式只要有一处不一致
//! (区域顺序, 钱的写法, 卡片记号的顺序), 对拍就会整体报错, 且很难看出是格式问题.

use super::flow::Phase;
use super::state::RunState;
use crate::cards::{Edition, Enhancement, Seal};

/// 阶段名换游戏那边的字符串.
pub fn state_name(phase: Phase) -> &'static str {
    match phase {
        Phase::BlindSelect => "BLIND_SELECT",
        Phase::SelectingHand => "SELECTING_HAND",
        Phase::RoundEval => "ROUND_EVAL",
        Phase::Shop => "SHOP",
        Phase::BoosterOpened => "SMODS_BOOSTER_OPENED",
        Phase::GameOver => "GAME_OVER",
    }
}

/// 一张牌写成记号, 例如 `S_K~glass#gold+p!e` —— 与游戏那边逐字一致.
///
/// 各段的顺序固定: 版本 (`+f`/`+h`/`+p`/`+n`), 蜡封 (`#gold`), 强化 (`~glass`),
/// 永恒 (`!e`), 租赁 (`!r`).
pub fn token_of(
    key: &str,
    edition: Option<Edition>,
    seal: Option<Seal>,
    enhancement: Option<Enhancement>,
    eternal: bool,
    rental: bool,
) -> String {
    let mut token = key.to_owned();
    if let Some(edition) = edition {
        let letter = match edition {
            Edition::Foil => "f",
            Edition::Holo => "h",
            Edition::Polychrome => "p",
            Edition::Negative => "n",
        };
        token.push_str(&format!("+{letter}"));
    }
    if let Some(seal) = seal {
        let name = match seal {
            Seal::Red => "red",
            Seal::Blue => "blue",
            Seal::Gold => "gold",
            Seal::Purple => "purple",
        };
        token.push_str(&format!("#{name}"));
    }
    if let Some(enhancement) = enhancement {
        let name = match enhancement {
            Enhancement::Bonus => "bonus",
            Enhancement::Mult => "mult",
            Enhancement::Wild => "wild",
            Enhancement::Glass => "glass",
            Enhancement::Steel => "steel",
            Enhancement::Stone => "stone",
            Enhancement::Gold => "gold",
            Enhancement::Lucky => "lucky",
        };
        token.push_str(&format!("~{name}"));
    }
    if eternal {
        token.push_str("!e");
    }
    if rental {
        token.push_str("!r");
    }
    token
}

/// 把引擎当前的状态写成回放 digest 那种摘要.
///
/// 区域顺序与游戏一致 (`hand` / `jokers` / `consumables` / `shop` / `vouchers` / `packs` / `pack`),
/// 因为手牌与小丑的顺序影响 agent 用的下标, 必须一致. 钱的写法也要一样 (整数不带小数点).
pub fn digest(run: &RunState) -> String {
    let number = |value: f64| -> String {
        if value.fract() == 0.0 {
            format!("{}", value as i64)
        } else {
            format!("{value}")
        }
    };
    let joining = |tokens: Vec<String>| -> String { tokens.join(",") };

    let mut parts = vec![
        format!("state={}", state_name(run.phase)),
        format!("ante={}", run.ante),
        format!("round={}", run.round),
        format!("money={}", number(run.dollars)),
        format!("deck={}", run.deck.len()),
        format!(
            "hand={}",
            joining(
                run.hand
                    .iter()
                    .map(|c| token_of(&c.card.key(), c.edition, c.seal, c.enhancement, false, false))
                    .collect()
            )
        ),
        format!(
            "jokers={}",
            joining(
                run.jokers
                    .iter()
                    .map(|j| token_of(&j.key, j.edition, None, None, j.eternal, j.rental))
                    .collect()
            )
        ),
        format!(
            "consumables={}",
            joining(
                run.consumables
                    .iter()
                    .map(|card| token_of(&card.key, card.edition, None, None, false, false))
                    .collect()
            )
        ),
    ];
    // 货架那三项 (`shop` / `vouchers` / `packs`) **只在商店出现过之后才写**.
    //
    // 游戏那边的摘要是在遍历区域时"这个区域在就写它" (`format.lua` 的 `if state[name]`),
    // 而 `G.shop_jokers` / `G.shop_vouchers` / `G.shop_booster` 是 `G.UIDEF.shop()` 里建的,
    // 建出来之后**再没有置回 nil**: 于是第一次进商店**之前**这三项整段不出现, 之后一直出现,
    // 只是不逛商店时是空的 (`shop=` 光秃秃一个等号).
    //
    // 原来这里不管阶段总是写出来, 注释里还写着"游戏那边这三个区域一直都在" —— 那是**错的**.
    // 反向对拍第一步就撞上了: 游戏给的 diff 是
    // `packs:  -> (none); shop:  -> (none); vouchers:  -> (none)`,
    // 意思是文件里写了个空值而游戏那边压根没这个字段. 之所以一直没被发现, 是因为
    // `tests/dump_replay.rs` 只做单向比较 ("记录里有的项都要对上, 引擎多出来的项不管"),
    // 而游戏自己的 `format.diff` 是双向的.
    if run.shop_seen {
        let jokers = run.shop.as_ref().map(|shop| &shop.jokers);
        let vouchers = run.shop.as_ref().map(|shop| &shop.vouchers);
        let packs = run.shop.as_ref().map(|shop| &shop.packs);
        parts.push(format!(
            "shop={}",
            joining(
                jokers
                    .map(|list| list
                        .iter()
                        .map(|c| token_of(&c.key, c.edition, None, c.enhancement, c.eternal, c.rental))
                        .collect())
                    .unwrap_or_default()
            )
        ));
        parts.push(format!(
            "vouchers={}",
            joining(vouchers
                .map(|cards| cards.iter()
                    .map(|card| token_of(&card.key, card.edition, None, card.enhancement, card.eternal, card.rental))
                    .collect())
                .unwrap_or_default())
        ));
        parts.push(format!(
            "packs={}",
            joining(
                packs
                    .map(|list| list
                        .iter()
                        .map(|c| token_of(&c.key, c.edition, None, c.enhancement, c.eternal, c.rental))
                        .collect())
                    .unwrap_or_default()
            )
        ));
    }
    if let Some(pack) = run.open_pack.as_ref() {
        parts.push(format!(
            "pack={}",
            joining(
                pack.contents
                    .iter()
                    .map(|c| token_of(&c.key, c.edition, c.seal, c.enhancement, c.eternal, c.rental))
                    .collect()
            )
        ));
    }
    // 待办清单指定要打的牌型. 它放在**所有区域之后**, 而且是按区域顺序收集起来的:
    // 游戏那边的 `format.lua` 是在遍历区域的同一个循环里顺手把每张牌的 `to_do` 收进一张表,
    // 循环走完再拼成一段. 牌型名里的空格会被换成下划线 (`Three of a Kind` -> `Three_of_a_Kind`).
    //
    // 只有待办清单小丑有这个值, 所以它平时是空的; 但它一旦出现就必须对上 ——
    // 它是"这张牌被造出来时掷到了哪个牌型"的**唯一**外部证据 (掷骰的位置错了, 这一项会立刻露馅).
    let mut todos: Vec<String> = Vec::new();
    for joker in &run.jokers {
        if let Some(hand) = joker.todo_hand {
            todos.push(hand.key().replace(char::is_whitespace, "_"));
        }
    }
    if let Some(shop) = run.shop.as_ref() {
        for card in &shop.jokers {
            if let Some(hand) = card.todo {
                todos.push(hand.key().replace(char::is_whitespace, "_"));
            }
        }
    }
    if let Some(pack) = run.open_pack.as_ref() {
        for card in &pack.contents {
            if let Some(hand) = card.todo {
                todos.push(hand.key().replace(char::is_whitespace, "_"));
            }
        }
    }
    if !todos.is_empty() {
        parts.push(format!("todo={}", todos.join(",")));
    }
    parts.join(" ")
}

/// digest 里出现过的键名. 用来**定边界** —— 不能直接按空格切.
///
/// 原因: 卡片记号里的 `~效果名` 自带空格 (塔罗是 `~hand upgrade` 这种), 按空格切会把它切成两半,
/// 于是"记录"那一侧被切碎, 比较注定对不上. 这类"格式里带空格"的地方只能按已知键名来找边界.
pub const DIGEST_KEYS: [&str; 13] = [
    "state",
    "ante",
    "round",
    "money",
    "deck",
    "hand",
    "jokers",
    "consumables",
    "shop",
    "vouchers",
    "packs",
    "pack",
    "todo",
];

/// 把 digest 拆成 `key -> value`.
pub fn digest_fields(digest: &str) -> Vec<(String, String)> {
    // 先找出每个 "<键>=" 的起点 (必须在开头或跟在空格后面).
    let mut marks: Vec<(usize, &str)> = Vec::new();
    for (index, _) in digest.char_indices() {
        if index > 0 && !digest[..index].ends_with(' ') {
            continue;
        }
        for key in DIGEST_KEYS {
            if digest[index..].starts_with(&format!("{key}=")) {
                marks.push((index, key));
            }
        }
    }
    let mut fields = Vec::new();
    for (order, (start, key)) in marks.iter().enumerate() {
        let value_start = start + key.len() + 1;
        let value_end = marks
            .get(order + 1)
            .map(|(next, _)| *next)
            .unwrap_or(digest.len());
        let value = digest[value_start..value_end].trim_end().to_owned();
        fields.push(((*key).to_owned(), value));
    }
    fields
}

/// 比对两行 digest, 返回**所有**不同的项 (相同就给 `None`).
///
/// 只比**记录里有的**键: 两个基准的疏密不同 (有的录了 `todo`, 有的没录), 缺键不算差异.
/// 先把所有不同的项都收集出来再报 —— 只看第一处容易被后面无关的项挡住.
pub fn diff(want: &str, got: &str) -> Option<String> {
    let got = digest_fields(got);
    let mut all = std::collections::BTreeMap::new();
    for (key, want) in digest_fields(want) {
        let found = got
            .iter()
            .find(|(k, _)| *k == key)
            .map(|(_, v)| v.clone())
            .unwrap_or_else(|| "<缺>".to_owned());
        if found != want {
            all.insert(key.clone(), format!("{key}: 引擎 {found} | 记录 {want}"));
        }
    }
    if all.is_empty() {
        None
    } else {
        Some(all.into_values().collect::<Vec<_>>().join(" ; "))
    }
}
