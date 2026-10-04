//! 原型数据: `docs/game/data/catalog.json`.
//!
//! 这个文件是随仓库走的静态快照 (由 `scripts/gen-card-docs.lua` 从游戏源码抽出), 覆盖原版
//! 360 个原型. 这里只取构建候选池需要的字段, 效果文本之类留给后面的模块按需读.
//!
//! 与 `game/game.lua` 的 `G.P_CENTERS` 对应关系:
//!
//! - `id` 就是 `G.P_CENTERS` 的键.
//! - `category` 是原型的 `set`, 也是 `G.P_CENTER_POOLS` 的分类依据.
//! - `initially_unlocked` 是新档的初始值. 实际值会被存档进度覆盖, 见 `unlocked_with`.

use std::collections::HashMap;
use std::sync::OnceLock;

use super::json::Json;

const CATALOG_JSON: &str = include_str!("../../../docs/game/data/catalog.json");

/// 一个原型的静态定义.
#[derive(Clone, Debug)]
pub struct Prototype {
    /// `G.P_CENTERS` 的键, 例如 `v_magic_trick`.
    pub id: String,
    /// 原型的 `set`, 例如 `Voucher` 或 `Joker`.
    pub category: String,
    /// 同类别内的展示顺序, 也是候选池的排序依据.
    pub order: f64,
    /// 小丑的稀有度 `1..=4`, 其他类别没有.
    pub rarity: Option<i64>,
    /// 新档的初始解锁状态. 没有这个字段时按 `None` 处理, 与游戏的 `v.unlocked ~= false` 一致.
    pub initially_unlocked: Option<bool>,
    /// 优惠券与标签的前置原型.
    pub requires: Vec<String>,
    pub no_pool_flag: Option<String>,
    pub yes_pool_flag: Option<String>,
    pub enhancement_gate: Option<String>,
    pub hidden: bool,
    pub base_cost: Option<f64>,
    /// 补充包的抽取权重, 对应原型上的 `weight`.
    pub weight: Option<f64>,
    /// 补充包的内容类别, 对应原型上的 `kind`.
    pub kind: Option<String>,
    /// 盲注的分数倍率 (小盲注 1, 大盲注 1.5, Boss 2).
    pub blind_multiplier: Option<f64>,
    /// 盲注通关后的固定奖金.
    pub reward_dollars: Option<f64>,
    /// Boss 的出现条件, 含 `min` / `max` / `showdown`. 非 Boss 没有这一项.
    pub boss: Option<Json>,
    /// 原型初始参数, 用法见 `docs/game/data/README.md`.
    pub config: Option<Json>,
}

impl Prototype {
    /// 是不是 Boss: 非 Boss 给 `None`, Boss 给 `Some(是否决战类型)`.
    pub fn boss_showdown(&self) -> Option<bool> {
        let boss = self.boss.as_ref()?;
        Some(boss.get("showdown").and_then(Json::as_bool).unwrap_or(false))
    }

    /// `boss.min`: 这个 Boss 从哪一底开始可能出现.
    pub fn boss_min(&self) -> Option<i64> {
        self.boss
            .as_ref()?
            .get("min")
            .and_then(Json::as_f64)
            .map(|n| n as i64)
    }

    /// 读原型 `config` 里的一个顶层数值, 例如标签的 `spawn_jokers` 或 `levels`.
    ///
    /// 取不到就算 0 —— 原型里没有这一项, 或者它不是数字.
    pub fn config_number(&self, field: &str) -> f64 {
        self.config
            .as_ref()
            .and_then(|config| config.get(field))
            .and_then(Json::as_f64)
            .unwrap_or(0.0)
    }
}

impl Prototype {
    /// 原型是否算"解锁". 没有这个字段时视为解锁, 因为游戏判的是 `v.unlocked ~= false`.
    pub fn unlocked_default(&self) -> bool {
        self.initially_unlocked.unwrap_or(true)
    }
}

/// 全部原型.
#[derive(Debug)]
pub struct Catalog {
    records: Vec<Prototype>,
    by_id: HashMap<String, usize>,
    /// 按类别缓存的候选池, 已按 `order` 升序.
    pools: HashMap<String, Vec<usize>>,
}

impl Catalog {
    /// 全局唯一的一份, 第一次用到时解析.
    pub fn get() -> &'static Catalog {
        static CACHE: OnceLock<Catalog> = OnceLock::new();
        CACHE.get_or_init(Catalog::parse)
    }

    fn parse() -> Catalog {
        let root = Json::parse(CATALOG_JSON).expect("catalog.json 应当能解析");
        let records: Vec<Prototype> = root
            .get("records")
            .and_then(Json::as_array)
            .expect("catalog.json 缺少 records")
            .iter()
            .map(parse_record)
            .collect();

        let mut by_id = HashMap::with_capacity(records.len());
        let mut pools: HashMap<String, Vec<usize>> = HashMap::new();
        for (i, record) in records.iter().enumerate() {
            by_id.insert(record.id.clone(), i);
            pools.entry(record.category.clone()).or_default().push(i);
        }
        // 游戏在 `Game:init_item_prototypes` 里对每个池按 `order` 升序排一次.
        for indices in pools.values_mut() {
            indices.sort_by(|&a, &b| records[a].order.total_cmp(&records[b].order));
        }

        Catalog {
            records,
            by_id,
            pools,
        }
    }

    pub fn record(&self, id: &str) -> Option<&Prototype> {
        self.by_id.get(id).map(|&i| &self.records[i])
    }

    /// 某一类原型的候选池, 顺序与 `G.P_CENTER_POOLS[set]` 一致.
    pub fn pool(&self, category: &str) -> Vec<&Prototype> {
        self.pools
            .get(category)
            .map(|indices| indices.iter().map(|&i| &self.records[i]).collect())
            .unwrap_or_default()
    }

    /// `Tarot_Planet`, 即 `Tarot` 与 `Planet` 合成后按 `order` 重排.
    pub fn tarot_planet(&self) -> Vec<&Prototype> {
        let mut items: Vec<&Prototype> = self
            .records
            .iter()
            .filter(|p| p.category == "Tarot" || p.category == "Planet")
            .collect();
        items.sort_by(|a, b| a.order.total_cmp(&b.order));
        items
    }

    /// `Consumeables`, 即所有消耗牌按 `order` 重排.
    pub fn consumables(&self) -> Vec<&Prototype> {
        let mut items: Vec<&Prototype> = self
            .records
            .iter()
            .filter(|p| {
                matches!(p.category.as_str(), "Tarot" | "Planet" | "Spectral")
            })
            .collect();
        items.sort_by(|a, b| a.order.total_cmp(&b.order));
        items
    }

    /// 小丑按稀有度分组后的池, 对应 `G.P_JOKER_RARITY_POOLS[rarity]`.
    pub fn jokers_by_rarity(&self, rarity: i64) -> Vec<&Prototype> {
        self.pool("Joker")
            .into_iter()
            .filter(|p| p.rarity == Some(rarity))
            .collect()
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }
}

fn parse_record(value: &Json) -> Prototype {
    Prototype {
        id: str_field(value, "id").unwrap_or_default(),
        category: str_field(value, "category").unwrap_or_default(),
        order: value.get("order").and_then(Json::as_f64).unwrap_or(0.0),
        rarity: value.get("rarity").and_then(Json::as_f64).map(|n| n as i64),
        initially_unlocked: value.get("initially_unlocked").and_then(Json::as_bool),
        requires: value
            .get("requires")
            .map(Json::str_list)
            .unwrap_or_default()
            .into_iter()
            .map(str::to_owned)
            .collect(),
        no_pool_flag: str_field(value, "no_pool_flag"),
        yes_pool_flag: str_field(value, "yes_pool_flag"),
        enhancement_gate: str_field(value, "enhancement_gate"),
        hidden: value.get("hidden").and_then(Json::as_bool).unwrap_or(false),
        base_cost: value.get("base_cost").and_then(Json::as_f64),
        weight: value.get("weight").and_then(Json::as_f64),
        kind: str_field(value, "kind"),
        blind_multiplier: value.get("blind_multiplier").and_then(Json::as_f64),
        reward_dollars: value.get("reward_dollars").and_then(Json::as_f64),
        boss: value.get("boss").cloned(),
        config: value.get("config").cloned(),
    }
}

fn str_field(value: &Json, key: &str) -> Option<String> {
    value.get(key).and_then(Json::as_str).map(str::to_owned)
}
