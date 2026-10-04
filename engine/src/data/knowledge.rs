//! 面向 agent 的静态知识: 卡牌查询与游戏手册.
//!
//! 数据来源与内置 agent (`mods/balatrobot/agent/knowledge/`) 用的是同一份:
//!
//! - 卡牌: `docs/game/data/catalog.json` 的 `name_zh` / `name_en` / `effect_zh`.
//! - 规则: `docs/game/` 下的手册 (`README.md`, `rules/`, `mechanics/`, `cards/`).
//!
//! 为什么要有这一层: 内置 agent 每轮拿到的状态摘要里, 每张牌都带**中文名与效果文本**,
//! 而且它能按需查手册. 引擎侧的 agent 原来只看得到内部键名 (`j_odd_todd`), 于是只能靠
//! 记忆或猜 —— 同样的局面, 信息量不一样, 输在这里不算引擎的问题, 但 agent 会输.
//!
//! 手册与目录都是 `include_str!` 进来的: 这样从任何工作目录调用都对, 路径写错在编译期就报.

use std::collections::HashMap;
use std::sync::OnceLock;

use super::json::Json;
use super::catalog::CATALOG_JSON;

/// 手册里的一个文件.
pub struct Manual {
    /// 相对 `docs/game/` 的路径, 也是 agent 查询时用的名字.
    pub path: &'static str,
    pub body: &'static str,
}

/// 手册的全部文件. 顺序与 `docs/game/README.md` 的阅读顺序一致 (规则在前, 条目目录在后).
const MANUAL: &[Manual] = &[
    Manual { path: "README.md", body: include_str!("../../../docs/game/README.md") },
    Manual { path: "rules/run-flow.md", body: include_str!("../../../docs/game/rules/run-flow.md") },
    Manual { path: "rules/poker-hands.md", body: include_str!("../../../docs/game/rules/poker-hands.md") },
    Manual { path: "rules/scoring.md", body: include_str!("../../../docs/game/rules/scoring.md") },
    Manual { path: "rules/card-modifiers.md", body: include_str!("../../../docs/game/rules/card-modifiers.md") },
    Manual { path: "rules/blinds.md", body: include_str!("../../../docs/game/rules/blinds.md") },
    Manual { path: "rules/stakes.md", body: include_str!("../../../docs/game/rules/stakes.md") },
    Manual { path: "rules/economy.md", body: include_str!("../../../docs/game/rules/economy.md") },
    Manual { path: "rules/shop-and-packs.md", body: include_str!("../../../docs/game/rules/shop-and-packs.md") },
    Manual { path: "rules/random-pools.md", body: include_str!("../../../docs/game/rules/random-pools.md") },
    Manual { path: "mechanics/joker-mechanics.md", body: include_str!("../../../docs/game/mechanics/joker-mechanics.md") },
    Manual { path: "mechanics/consumable-mechanics.md", body: include_str!("../../../docs/game/mechanics/consumable-mechanics.md") },
    Manual { path: "mechanics/run-modifiers.md", body: include_str!("../../../docs/game/mechanics/run-modifiers.md") },
    Manual { path: "mechanics/progression.md", body: include_str!("../../../docs/game/mechanics/progression.md") },
    Manual { path: "cards/jokers.md", body: include_str!("../../../docs/game/cards/jokers.md") },
    Manual { path: "cards/tarots.md", body: include_str!("../../../docs/game/cards/tarots.md") },
    Manual { path: "cards/planets.md", body: include_str!("../../../docs/game/cards/planets.md") },
    Manual { path: "cards/spectrals.md", body: include_str!("../../../docs/game/cards/spectrals.md") },
    Manual { path: "cards/vouchers.md", body: include_str!("../../../docs/game/cards/vouchers.md") },
    Manual { path: "cards/decks.md", body: include_str!("../../../docs/game/cards/decks.md") },
    Manual { path: "cards/tags.md", body: include_str!("../../../docs/game/cards/tags.md") },
    Manual { path: "cards/boosters.md", body: include_str!("../../../docs/game/cards/boosters.md") },
    Manual { path: "cards/blinds.md", body: include_str!("../../../docs/game/cards/blinds.md") },
    Manual { path: "cards/enhancements.md", body: include_str!("../../../docs/game/cards/enhancements.md") },
    Manual { path: "cards/editions.md", body: include_str!("../../../docs/game/cards/editions.md") },
    Manual { path: "cards/seals.md", body: include_str!("../../../docs/game/cards/seals.md") },
    Manual { path: "cards/stakes.md", body: include_str!("../../../docs/game/cards/stakes.md") },
    Manual { path: "cards/playing-cards.md", body: include_str!("../../../docs/game/cards/playing-cards.md") },
    Manual { path: "cards/challenges.md", body: include_str!("../../../docs/game/cards/challenges.md") },
    Manual { path: "cards/modifiers.md", body: include_str!("../../../docs/game/cards/modifiers.md") },
    Manual { path: "data/README.md", body: include_str!("../../../docs/game/data/README.md") },
];

/// 手册全部文件, 按上面的顺序.
pub fn manual() -> &'static [Manual] {
    MANUAL
}

/// 每份手册的标题 (第一行 `# `) 与行数, 给目录用.
pub fn manual_title(body: &str) -> &str {
    for line in body.lines() {
        if let Some(title) = line.strip_prefix("# ") {
            return title.trim();
        }
    }
    ""
}

/// 按路径找一份手册. 允许省略 `.md`, 也允许只给文件名 (例如 `economy`).
pub fn find_manual(path: &str) -> Option<&'static Manual> {
    let needle = path.trim().trim_start_matches("./").trim_start_matches("docs/game/");
    let needle = needle.strip_suffix(".md").unwrap_or(needle);
    MANUAL
        .iter()
        .find(|doc| {
            let full = doc.path.strip_suffix(".md").unwrap_or(doc.path);
            full == needle || full.ends_with(&format!("/{needle}"))
        })
}

/// 手册里搜子串, 返回 `(路径, 行号, 行内容)`. 只给可选的路径限定.
pub fn search_manual(query: &str, path: Option<&str>, limit: usize) -> Vec<(&'static str, usize, &'static str)> {
    let docs: Vec<&Manual> = match path {
        Some(path) => find_manual(path).into_iter().collect(),
        None => MANUAL.iter().collect(),
    };
    let mut out = Vec::new();
    for doc in docs {
        for (index, line) in doc.body.lines().enumerate() {
            if line.contains(query) {
                out.push((doc.path, index + 1, line.trim_end()));
                if out.len() >= limit {
                    return out;
                }
            }
        }
    }
    out
}

/// 一张卡的精简记录, 字段与内置 agent 的 `lookup` 返回一致.
#[derive(Clone, Debug)]
pub struct CardInfo {
    pub id: String,
    pub name_zh: String,
    pub name_en: String,
    /// 原型的 `set`, 例如 `Joker` / `Tarot` / `Voucher`.
    pub category: String,
    /// 小丑的稀有度, 中文 (普通 / 罕见 / 稀有 / 传奇).
    pub rarity: Option<String>,
    pub base_cost: Option<f64>,
    /// 卡面效果, 多行已连成一行.
    pub effect_zh: String,
    /// 蓝图能不能复制它 (`blueprint_compat`).
    pub blueprint_compat: Option<bool>,
}

const RARITY: [&str; 4] = ["普通", "罕见", "稀有", "传奇"];

/// 卡牌索引: 按 id, 中文名, 英文名 (忽略大小写, 再忽略空格与标点).
struct Index {
    cards: Vec<CardInfo>,
    by_id: HashMap<String, usize>,
    by_name: HashMap<String, Vec<usize>>,
}

fn index() -> &'static Index {
    static CACHE: OnceLock<Index> = OnceLock::new();
    CACHE.get_or_init(build_index)
}

/// 把名称压成便于匹配的形状: 小写, 去掉空格与标点.
fn squash(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .filter(|ch| !ch.is_whitespace() && !ch.is_ascii_punctuation())
        .collect()
}

fn text_of(value: Option<&Json>) -> String {
    match value {
        Some(Json::String(text)) => text.clone(),
        // 效果是"按卡面换行拆开的数组", 连成一行, 中间留空格, 免得数字与相邻文字粘连.
        Some(Json::Array(items)) => items
            .iter()
            .filter_map(Json::as_str)
            .collect::<Vec<_>>()
            .join(" "),
        _ => String::new(),
    }
}

fn build_index() -> Index {
    let root = Json::parse(CATALOG_JSON).expect("catalog.json 应当能解析");
    let records = root
        .get("records")
        .and_then(Json::as_array)
        .expect("catalog.json 缺少 records");

    let mut cards = Vec::with_capacity(records.len());
    for record in records {
        let Some(id) = record.get("id").and_then(Json::as_str) else {
            continue;
        };
        cards.push(CardInfo {
            id: id.to_owned(),
            name_zh: text_of(record.get("name_zh")),
            name_en: text_of(record.get("name_en")),
            category: text_of(record.get("category")),
            rarity: record
                .get("rarity")
                .and_then(Json::as_f64)
                .and_then(|level| RARITY.get(level as usize - 1))
                .map(|name| (*name).to_owned()),
            base_cost: record.get("base_cost").and_then(Json::as_f64),
            effect_zh: text_of(record.get("effect_zh")),
            blueprint_compat: record.get("blueprint_compat").and_then(Json::as_bool),
        });
    }

    let mut by_id = HashMap::with_capacity(cards.len());
    let mut by_name: HashMap<String, Vec<usize>> = HashMap::new();
    for (position, card) in cards.iter().enumerate() {
        by_id.insert(card.id.clone(), position);
        for name in [&card.id, &card.name_zh, &card.name_en] {
            if name.is_empty() {
                continue;
            }
            let keys = [name.to_lowercase(), squash(name)];
            for key in keys {
                if key.is_empty() {
                    continue;
                }
                let slot = by_name.entry(key).or_default();
                if !slot.contains(&position) {
                    slot.push(position);
                }
            }
        }
    }
    Index {
        cards,
        by_id,
        by_name,
    }
}

/// 按 id / 中文名 / 英文名精确匹配 (名称忽略大小写, 再忽略空格与标点).
pub fn find_cards(key: &str) -> Vec<&'static CardInfo> {
    let index = index();
    if let Some(&position) = index.by_id.get(key) {
        return vec![&index.cards[position]];
    }
    let trimmed = key.trim();
    for needle in [trimmed.to_lowercase(), squash(trimmed)] {
        if needle.is_empty() {
            continue;
        }
        if let Some(positions) = index.by_name.get(&needle) {
            return positions.iter().map(|&p| &index.cards[p]).collect();
        }
    }
    Vec::new()
}

/// 名称相近的候选, 给"查不到"时提示用.
///
/// 两层判据, 从紧到松:
///
/// 1. 名称或 id **互相包含** (打了一半, 或者记成了更长的写法), 按长度差排序.
/// 2. 以上都没有时, 退一步看**首字相同且长度接近**的. 这一层是为了打错一个字的情形:
///    `蓝盆` 与 `蓝图` 互不包含, 但含义上就是同一条, 而"查不到且毫无提示"会让 agent 以为
///    这张牌不存在 —— 那比给一个错误的候选更糟.
///
/// 只给提示, 不回填结果: 调用方拿到的仍是"没查到", 不至于把猜测当事实用.
pub fn candidates(key: &str) -> Vec<String> {
    let needle = squash(key);
    if needle.is_empty() {
        return Vec::new();
    }
    let shapes = |card: &CardInfo| -> Vec<String> {
        [&card.id, &card.name_zh, &card.name_en]
            .iter()
            .map(|name| squash(name))
            .filter(|shape| !shape.is_empty())
            .collect()
    };
    // 收集符合 `hit` 的, 按与 query 的长度差排序 (越接近的越可能是想找的那条).
    let rank = |hit: &dyn Fn(&str) -> bool| -> Vec<(usize, &'static CardInfo)> {
        let mut scored: Vec<(usize, &'static CardInfo)> = Vec::new();
        for card in &index().cards {
            let best = shapes(card)
                .iter()
                .filter(|shape| hit(shape))
                .map(|shape| shape.chars().count().abs_diff(needle.chars().count()))
                .min();
            if let Some(distance) = best {
                scored.push((distance, card));
            }
        }
        scored.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.id.cmp(&b.1.id)));
        scored
    };

    let mut scored = rank(&|shape: &str| shape.contains(&needle) || needle.contains(shape));
    if scored.is_empty() {
        // 首字相同, 且长度差不超过一 —— 收紧到这里, 否则会给出一大堆无关的牌.
        let head = needle.chars().next().expect("上面判过非空");
        scored = rank(&|shape: &str| {
            shape.starts_with(head)
                && shape.chars().count().abs_diff(needle.chars().count()) <= 1
        });
    }
    scored
        .iter()
        .take(5)
        .map(|(_, card)| format!("{} {} / {}", card.id, card.name_zh, card.name_en))
        .collect()
}

/// 摘要用的一行: 中文名与效果. 查不到时给 `None`, 调用方退回键名.
pub fn describe(id: &str) -> Option<(&'static str, &'static str)> {
    let card = *find_cards(id).first()?;
    Some((card.name_zh.as_str(), card.effect_zh.as_str()))
}

/// 效果文本里还剩 `[` 的说明它有**会变的占位** (每回合换的花色点数, 成长值这类),
/// 这种要看局面里的实时值, 不能用这里的静态文本.
pub fn effect_is_dynamic(effect: &str) -> bool {
    effect.contains('[')
}
