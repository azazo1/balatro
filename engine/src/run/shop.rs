//! 商店货架: 小丑, 消耗牌与卡包的抽取.
//!
//! 抄自 `game/functions/UI_definitions.lua` 的 `create_card_for_shop` (L742),
//! `game/functions/common_events.lua` 的 `create_card` (L2082) 与 `get_pack` (L1944),
//! `poll_edition` (L2055).
//!
//! 这里最容易被忽略的是**全局 PRNG 状态**: `get_pack` 第一次给基础小丑包时用的是
//! `math.random(1, 2)`, 中间没有 `math.randomseed`, 所以它吃的是上一次 `pseudorandom` 之后的
//! 状态. 也就是说货架的生成顺序 (两张小丑 -> 优惠券 -> 两个卡包) 必须整体照抄, 单独算某一项
//! 是算不对的.

use crate::cards::{Edition, Enhancement, Seal, standard_deck};
use crate::data::catalog::Catalog;

use super::state::RunState;

/// 商店各类商品的权重, 对应 `G.GAME` 上那几个 `*_rate`.
#[derive(Clone, Copy, Debug)]
pub struct ShopRates {
    pub joker: f64,
    pub tarot: f64,
    pub planet: f64,
    pub playing_card: f64,
    pub spectral: f64,
}

impl Default for ShopRates {
    fn default() -> Self {
        // game.lua:1901 起的默认值. 单独某个牌组或挑战会改其中几项 (例如幽灵牌组把
        // spectral_rate 提到 2), 挑战模式还有把 joker_rate 清零的规则.
        ShopRates {
            joker: 20.0,
            tarot: 4.0,
            planet: 4.0,
            playing_card: 0.0,
            spectral: 0.0,
        }
    }
}

/// 商店里的一件商品. 真游戏里是一张 `Card` 实例, 这里只留判定货架需要的那几项.
#[derive(Clone, Debug, PartialEq)]
pub struct ShopCard {
    /// 原型键.
    pub key: String,
    pub edition: Option<Edition>,
    pub eternal: bool,
    pub perishable: bool,
    pub rental: bool,
    /// 售价, 按 `Card:set_cost` 算好.
    pub cost: f64,
}

impl ShopCard {
    fn plain(key: String) -> Self {
        ShopCard {
            key,
            edition: None,
            eternal: false,
            perishable: false,
            rental: false,
            cost: 0.0,
        }
    }
}

/// `Card:set_cost`: 基础价加通胀, 再按版本加价, 最后打折并向下取整; 租赁固定 `$1`.
///
/// `discount_percent` 来自商店的折扣 (例如优惠券), 通胀来自 `modifiers.inflation`.
pub fn shop_cost(base_cost: f64, edition: Option<Edition>, rental: bool, inflation: f64, discount_percent: f64) -> f64 {
    if rental {
        return 1.0;
    }
    let mut extra = inflation;
    if let Some(edition) = edition {
        // 每个版本加价多少, 按 `Card:set_cost` 里的表.
        extra += match edition {
            Edition::Foil => 2.0,
            Edition::Holo => 3.0,
            Edition::Polychrome | Edition::Negative => 5.0,
        };
    }
    let raw = (base_cost + extra + 0.5) * (100.0 - discount_percent) / 100.0;
    raw.floor().max(1.0)
}

/// `poll_edition`: 抽一次版本.
///
/// `negative_ok` 对应 `not _no_neg`, `mod` 默认 1, `G.GAME.edition_rate` 默认 1.
/// `poll_edition`: 掷一次版本.
///
/// `rate` 对应原型的 `_mod` 倍数: 商店里的小丑用 1, 标准包里开出来的牌用 2 (概率翻倍).
/// `negative_ok` 为假时跳过负片那一档 —— 标准包就是不许出负片.
pub fn poll_edition(run: &mut RunState, key: &str, rate: f64, negative_ok: bool) -> Option<Edition> {
    let poll = run.rng.pseudorandom(key);
    if poll > 1.0 - 0.003 * rate && negative_ok {
        Some(Edition::Negative)
    } else if poll > 1.0 - 0.006 * rate {
        Some(Edition::Polychrome)
    } else if poll > 1.0 - 0.02 * rate {
        Some(Edition::Holo)
    } else if poll > 1.0 - 0.04 * rate {
        Some(Edition::Foil)
    } else {
        None
    }
}

/// `create_card_for_shop`: 决定这一格摆什么, 然后生成它.
///
/// `area_is_shop_jokers` 对应 `area == G.shop_jokers`, 影响后续的永恒 / 易腐 / 租赁抽签.
/// 目前只实现小丑这一条分支: 其余类型 (塔罗, 行星, 基础牌, 幻灵) 的生成还没做, 遇到就报错,
/// 不要静默给一个错的结果.
pub fn create_card_for_shop(run: &mut RunState, rates: &ShopRates) -> ShopCard {
    // 有几个标签会强行指定这一格放什么: "罕见 / 稀有标签"换成那个稀有度的小丑,
    // 紧接着"版本标签"再给它加个版本. 没有这类标签时下面照常按权重抽.
    if let Some(card) = shop_card_from_tags(run, rates) {
        return card;
    }

    let total = rates.joker + rates.tarot + rates.planet + rates.playing_card + rates.spectral;
    let polled = run.rng.pseudorandom(&format!("cdt{}", run.ante)) * total;

    let mut check = 0.0;
    // 顺序与游戏里的表一致: 小丑, 塔罗, 行星, 基础牌, 幻灵.
    let kinds = [
        ("Joker", rates.joker),
        ("Tarot", rates.tarot),
        ("Planet", rates.planet),
        ("Base", rates.playing_card),
        ("Spectral", rates.spectral),
    ];
    for (kind, weight) in kinds {
        if polled > check && polled <= check + weight {
            return match kind {
                "Joker" => create_joker(run, "sho"),
                // 基础牌: 从 52 张牌面里抽一张. 商店摆的是裸牌, 带版本或蜡封的那种要另做.
                "Base" => {
                    let mut card = ShopCard::plain(playing_card_for_shop(run));
                    card.cost = shop_cost(
                        base_cost_of(&card.key),
                        None,
                        false,
                        run.inflation,
                        run.discount_percent,
                    );
                    card
                }
                // 塔罗, 行星与幻灵: 直接抽它们各自的池.
                other => {
                    let mut card = ShopCard::plain(create_card_for_shop_slot(run, other, "sho"));
                    card.cost = shop_cost(
                        base_cost_of(&card.key),
                        None,
                        false,
                        run.inflation,
                        run.discount_percent,
                    );
                    card
                }
            };
        }
        check += weight;
    }
    panic!("商店类型抽签落到了权重区间之外 (total_rate={total}, polled={polled})");
}

/// 按稀有度抽一张小丑的**原型键**, 池子的过滤在这里统一做.
///
/// 三处都要"按稀有度抽小丑" (商店货架, 标签强行指定, 幻灵的幽灵与灵魂), 而过滤条件是同一套:
/// 解锁 (传奇无视解锁) 且 没用过 (持有表演者时例外). 手抄三遍的结果就是三处渐渐不一致 ——
/// 有一处漏了表演者的例外, 另一处漏了传奇的豁免. 所以只留这一份.
///
/// `legendary` 为真时稀有度固定是 4, 而且**池键不带底注** (源码里是 `not _legendary and ante or ''`).
pub fn pick_joker_of_rarity(
    run: &mut RunState,
    rarity: i64,
    key_append: &str,
    legendary: bool,
) -> Option<String> {
    let candidates = Catalog::get().jokers_by_rarity(rarity);
    let showman = run.jokers.iter().any(|joker| joker.key == "j_ring_master");
    let pool: Vec<String> = candidates
        .iter()
        .map(|proto| {
            // 用过的小丑默认不再出现, 但持有表演者时例外.
            let used = run.used_jokers.contains(&proto.id) && !showman;
            // 池子开关 (`pool_flags`): `no_pool_flag` 置位之后这张就不该再出现,
            // `yes_pool_flag` 则是没置位之前不出现. 现在只有一对:
            // 大麦克烂掉会置 `gros_michel_extinct` —— 于是大麦克离开池子, 而**卡文迪什进场**
            // (这正是"大麦克烂了才能刷到卡文迪什"那条规则). 少了它, 池子里的占位格子对不上.
            let blocked = proto
                .no_pool_flag
                .as_deref()
                .is_some_and(|flag| run.pool_flags.contains(flag))
                || proto
                    .yes_pool_flag
                    .as_deref()
                    .is_some_and(|flag| !run.pool_flags.contains(flag))
                // 这两条与消耗牌那份一样 (`get_current_pool` 的裁剪对所有类型都跑):
                // `hidden` 永远不进, `enhancement_gate` 要牌堆里有那种强化牌.
                || proto.hidden
                || proto
                    .enhancement_gate
                    .as_deref()
                    .is_some_and(|gate| !run.has_enhancement(gate));
            // 传奇无视解锁条件.
            if (legendary || run.unlocked(proto)) && !used && !blocked {
                proto.id.clone()
            } else {
                "UNAVAILABLE".to_owned()
            }
        })
        .collect();
    // 池键的构造 (`get_current_pool`): `'Joker'..稀有度..((not _legendary and 追加) or '')`,
    // 而函数末尾又是 `_pool_key..(not _legendary and 底注 or '')` ——
    // 也就是**传奇那条路既不带追加、也不带底注**, 键就是光秃秃的 `Joker4`.
    // 少了这个区别, 灵魂牌开出来的传奇就会选错人 (键不同 → 掷骰不同 → 落在别的传奇上).
    let pool_key = if legendary {
        format!("Joker{rarity}")
    } else {
        format!("Joker{rarity}{key_append}{}", run.ante)
    };
    let key = pick_or_resample(&mut run.rng, &pool, &pool_key);
    if key == "UNAVAILABLE" {
        return None;
    }
    // **造出来就算"用过"**: 游戏在 `Card:set_ability` 里把每一张造出来的牌记进
    // `G.GAME.used_jokers` (不看买没买), 而池子又把记过的滤掉 ——
    // 所以"商店里出现过的小丑本局不会再出现". 少了这一笔, 池子永远不缩小,
    // 同稀有度的池子长度对不上, 选中的小丑自然也不同.
    run.used_jokers.insert(key.clone());
    Some(key)
}

/// `create_card('Joker', area, ..., key_append)` 的小丑路径.
pub fn create_joker(run: &mut RunState, key_append: &str) -> ShopCard {
    // 1. 稀有度: get_current_pool 里对小丑先抽稀有度.
    let roll = run
        .rng
        .pseudorandom(&format!("rarity{}{key_append}", run.ante));
    let rarity = if roll > 0.95 {
        3
    } else if roll > 0.7 {
        2
    } else {
        1
    };

    // 2. 在这个稀有度的池子里抽原型. 过滤与池键的构造都交给共用那一个函数.
    //
    // 注意池键末尾的底注不能省 (共用函数里已经带上): 实测去掉它之后, ALEEB 第一个商店会变成
    // `j_seance` / `j_matador`, 而真游戏是 `j_trading` / `j_rocket`. 以上游源码的读法看不出
    // 底注参与, 但实测结果如此, 所以以实测为准, 别照源码"简化".
    let key = pick_joker_of_rarity(run, rarity, key_append, false)
        .unwrap_or_else(|| "j_joker".to_owned());

    let mut card = ShopCard::plain(key);

    // 3. 商店里的小丑抽永恒 / 易腐, 再抽租赁. 两者用的是不同的 key.
    let poll = run
        .rng
        .pseudorandom(&format!("etperpoll{}", run.ante));
    if run.modifiers.enable_eternals_in_shop && poll > 0.7 {
        card.eternal = true;
    } else if run.modifiers.enable_perishables_in_shop && poll > 0.4 && poll <= 0.7 {
        card.perishable = true;
    }
    if run.modifiers.enable_rentals_in_shop
        && run.rng.pseudorandom(&format!("ssjr{}", run.ante)) > 0.7
    {
        card.rental = true;
    }

    // 4. 版本.
    card.edition = poll_edition(run, &format!("edi{key_append}{}", run.ante), 1.0, true);
    card.cost = shop_cost(
        base_cost_of(&card.key),
        card.edition,
        card.rental,
        run.inflation,
        run.discount_percent,
    );
    card
}

/// 标签强行指定的那一格, 对应 `create_card_for_shop` 里遍历 `G.GAME.tags` 那一段.
///
/// 游戏那边的顺序是: 先找 `store_joker_create` 拿到一张小丑, 再拿它去问每个
/// `store_joker_modify`, 第一个答应的给它加版本.
fn shop_card_from_tags(run: &mut RunState, _rates: &ShopRates) -> Option<ShopCard> {
    // `store_joker_create`: 罕见标签给 2 级, 稀有标签给 3 级.
    let (rarity, key_append) = run.tags.iter().find_map(|tag| match tag.as_str() {
        "tag_uncommon" => Some((2, "uta")),
        "tag_rare" => Some((3, "rta")),
        _ => None,
    })?;
    // **用掉的标签要离场** —— 游戏里 `Tag:yep` 与 `Tag:nope` 两条路都会 `self:remove()`,
    // 也就是"触发一次就没了". 少了这一步, 它会在**之后每一格**货架上继续生效:
    // 一张"罕见标签"会把整面货架全变成稀有二的小丑.
    // (整局对拍里 `LG7RIX92` 那份第 26 步就是这么差的: 引擎连着两格都出了稀有二.)
    run.tags.retain(|tag| tag != "tag_uncommon" && tag != "tag_rare");

    // 画一张那个稀有度的小丑. 这里不走 `create_joker` 的主路径, 因为它会先掷一次稀有度 ——
    // 而标签已经指定了, 再掷一次就把随机数序列带偏了. 过滤本身仍然是共用那一份.
    let key = pick_joker_of_rarity(run, rarity, key_append, false)?;
    let mut card = ShopCard::plain(key);

    // `store_joker_modify`: 第一个版本标签给它加版本. 它原本没有版本才加.
    // 它同样是"触发一次就离场" —— 否则之后每一格商店小丑都会白带一个版本.
    let edition = run.tags.iter().find_map(|tag| match tag.as_str() {
        "tag_foil" => Some(Edition::Foil),
        "tag_holo" => Some(Edition::Holo),
        "tag_polychrome" => Some(Edition::Polychrome),
        "tag_negative" => Some(Edition::Negative),
        _ => None,
    });
    if edition.is_some() {
        run.tags
            .retain(|tag| !matches!(tag.as_str(), "tag_foil" | "tag_holo" | "tag_polychrome" | "tag_negative"));
    }
    card.edition = edition;
    card.cost = shop_cost(
        base_cost_of(&card.key),
        card.edition,
        false,
        run.inflation,
        run.discount_percent,
    );
    Some(card)
}

/// 商店摆的那张裸牌: 从 52 张里抽, 键与标准包抽牌面时不同 (`sho` 而不是 `sta`).
fn playing_card_for_shop(run: &mut RunState) -> String {
    let faces: Vec<String> = standard_deck().iter().map(|card| card.key()).collect();
    let frontsho_key = format!("frontsho{}", run.ante);
    pick_or_resample(&mut run.rng, &faces, &frontsho_key)
}

/// 原型上的基础价, 查不到给 0 (不会出现在正常商店里).
fn base_cost_of(key: &str) -> f64 {
    Catalog::get()
        .record(key)
        .and_then(|proto| proto.base_cost)
        .unwrap_or(0.0)
}

/// 包型对应的池类型, 照 `Card:open` 里那串 `self.ability.name:find(...)`.
///
/// 秘术包与幻灵包里的灵魂/黑洞是在抽池**之前**就定下来的, 见 `create_card`.
pub fn pack_kind_of(pack_key: &str) -> Option<&'static str> {
    let name = Catalog::get()
        .record(pack_key)
        .map(|proto| proto.id.clone())?;
    let kind = Catalog::get().record(&name).and_then(|p| p.kind.clone())?;
    Some(match kind.as_str() {
        "Arcana" => "Tarot",
        "Celestial" => "Planet",
        "Spectral" => "Spectral",
        "Standard" => "Base",
        "Buffoon" => "Joker",
        _ => return None,
    })
}

/// 原型上的 `config.choose`: 开出的这几张里能挑走几张.
pub fn pack_choices(pack_key: &str) -> usize {
    Catalog::get()
        .record(pack_key)
        .and_then(|proto| proto.config.as_ref())
        .and_then(|config| config.get("choose"))
        .and_then(crate::data::json::Json::as_f64)
        .map(|n| n as usize)
        .unwrap_or(1)
}

/// 这张消耗牌的原型里那个"给几张"的数目 (女祭司的 `planets`, 皇帝的 `tarots`).
pub fn consumable_count(key: &str, field: &str) -> usize {
    Catalog::get()
        .record(key)
        .and_then(|proto| proto.config.as_ref())
        .and_then(|config| config.get(field))
        .and_then(crate::data::json::Json::as_f64)
        .map(|n| n as usize)
        .unwrap_or(0)
}

/// 从 `config.<field>.<sub>` 里取一个数 (火祭的 `extra.dollars` 这种嵌一层的).
pub fn nested_number(key: &str, field: &str, sub: &str) -> f64 {
    Catalog::get()
        .record(key)
        .and_then(|proto| proto.config.as_ref())
        .and_then(|config| config.get(field))
        .and_then(|inner| inner.get(sub))
        .and_then(crate::data::json::Json::as_f64)
        .unwrap_or(0.0)
}

/// 每张包内容用哪个键前缀, 照 `Card:open` 里传给 `create_card` 的最后一个参数.
fn pack_key_append(kind: &str) -> &'static str {
    match kind {
        "Tarot" => "ar1",
        "Planet" => "pl1",
        "Spectral" => "spe",
        "Joker" => "buf",
        _ => "sta",
    }
}

/// `create_card`: 从某个类型的池里抽一张原型, 返回它的键.
///
/// 抽池之前先掷"灵魂": 命中的话不抽池, 直接给 `c_soul` (塔罗与幻灵包) 或 `c_black_hole`
/// (行星与幻灵包). 两次判定是两个独立的 if, 用的是同一个键, 所以幻灵包会连掷两次.
pub fn create_card(run: &mut RunState, kind: &str, key_append: &str) -> String {
    create_card_inner(run, kind, key_append, true, None)
}

/// 商店货架上那一格. **它不掷灵魂那一骰** —— 游戏里 `create_card_for_shop` 传的第 6 个参数
/// (`soulable`) 是 `nil`, 而灵魂那一段的头一句就是 `if not forced_key and soulable and ...`,
/// 于是整段跳过. 少了这个区别, 商店每出一张塔罗 / 行星 / 幻灵都会让那条键多走一步,
/// 后面所有用同一条键的地方 (开包) 就整体错位.
pub fn create_card_for_shop_slot(run: &mut RunState, kind: &str, key_append: &str) -> String {
    create_card_inner(run, kind, key_append, false, None)
}

/// `create_card` 的主体. `soulable` 对应游戏里那个同名参数.
/// 造一张**消耗牌**要看的那点状态.
///
/// 单独抽出来是为了让**计分那一层**也能造牌: 那一层拿不到整个 `RunState`, 但消耗牌这条路
/// 只需要这么几样 (小丑那条路要多得多 —— 定价, 解锁, 强化门, 版本与蜡封的开关...).
/// 字段都是分开借的, 所以可以用一个表达式从运行状态里切出来.
pub struct Creation {
    pub ante: i64,
    pub showman: bool,
    /// 禁用名单 (灵魂 / 黑洞那两张会看).
    pub banned: std::collections::HashSet<String>,
    /// 用过哪些 (池子裁剪与"灵魂只出一次"都看它). 用完由调用方并回运行状态.
    pub used: std::collections::HashSet<String>,
    /// 牌堆里出现过哪些强化 (行星与塔罗池子的"强化门"要它).
    pub enhanced: std::collections::HashSet<String>,
    /// 本局打过哪些牌型 (行星的"软锁"要它).
    pub played: std::collections::HashSet<String>,
}

impl Creation {
    /// 把"用过哪些"并回运行状态 —— 造过牌之后调用方要记得做, 否则池子裁剪会失准.
    pub fn merge_back(&self, run: &mut RunState) {
        run.used_jokers.extend(self.used.iter().cloned());
    }
}

/// 从一个运行状态里切出造消耗牌要的那几样.
pub fn creation_from(run: &RunState) -> Creation {
    let showman = run
        .jokers
        .iter()
        .any(|joker| joker.key == "j_ring_master");
    // 这两样是从牌堆与手牌表**现算**的: 与其把整个牌堆借出来, 不如只带这两个小集合,
    // 免得 `Creation` 的借用面铺得太开 (借得越少, 越容易在计分那一层用上).
    let enhanced: std::collections::HashSet<String> = run
        .deck
        .iter()
        .filter_map(|card| card.enhancement.map(|e| e.key().to_owned()))
        .collect();
    let played: std::collections::HashSet<String> = crate::scoring::PokerHand::BY_PRIORITY
        .iter()
        .filter(|hand| run.hands.get(**hand).played > 0)
        .map(|hand| hand.info().key.to_owned())
        .collect();
    Creation {
        ante: run.ante,
        showman,
        banned: run.banned_keys.clone(),
        used: run.used_jokers.clone(),
        enhanced,
        played,
    }
}

/// 造一张**消耗牌** (塔罗 / 行星 / 幽灵): 先掷灵魂与黑洞那两骰, 再抽池.
///
/// 这是消耗牌唯一的一条实现 —— `create_card` 与**计分那一层**都走它,
/// 免得两处各写一份、以后改一处忘一处.
pub fn create_consumable(
    creation: &mut Creation,
    rng: &mut crate::rng::Rng,
    kind: &str,
    key_append: &str,
    soulable: bool,
) -> String {
    // 灵魂 / 黑洞那两骰: 命中就不抽池, 直接给那一张. 这两道门除了"有没有这张牌"还看
    // **用过没有** (已经进过 `used_jokers` 时整段跳过, 表演者例外) —— 注意是跳过**整段**,
    // 连那一骰都不掷, 所以随机序列也会跟着不同.
    let soul_key = format!("soul_{kind}{}", creation.ante);
    let soul_used = creation.used.contains("c_soul") && !creation.showman;
    let black_hole_used = creation.used.contains("c_black_hole") && !creation.showman;
    if soulable
        && !soul_used
        && matches!(kind, "Tarot" | "Spectral" | "Tarot_Planet")
        && !creation.banned.contains("c_soul")
        && rng.pseudorandom(&soul_key) > 0.997
    {
        creation.used.insert("c_soul".to_owned());
        return "c_soul".to_owned();
    }
    if soulable
        && !black_hole_used
        && matches!(kind, "Planet" | "Spectral")
        && !creation.banned.contains("c_black_hole")
        && rng.pseudorandom(&soul_key) > 0.997
    {
        creation.used.insert("c_black_hole".to_owned());
        return "c_black_hole".to_owned();
    }
    // 池键同样要带上底注.
    let pool_key = format!("{kind}{key_append}{}", creation.ante);
    let pool = consumable_pool(kind, creation);
    let key = pick_or_resample(rng, &pool, &pool_key);
    // 造出来就算"用过" (游戏是在 `Card:set_ability` 里统一记的).
    if key != "UNAVAILABLE" {
        creation.used.insert(key.clone());
    }
    key
}

pub fn create_card_inner(
    run: &mut RunState,
    kind: &str,
    key_append: &str,
    soulable: bool,
    forced: Option<&str>,
) -> String {
    // 指定卡 (游戏的 `forced_key`): **灵魂 / 黑洞那两骰都不掷, 池也不抽**, 直接给这一张.
    // 游戏那句写的是 `if not forced_key and soulable and …` —— 少掷一骰就意味着后面整条
    // 随机序列都不同, 所以"指定卡"必须走这条短路, 不能"先照常抽一张再替换成它".
    if let Some(key) = forced {
        return key.to_owned();
    }
    // 小丑要走**稀有度分流**那条路 —— 与商店货架上的小丑一样: 先掷稀有度, 再从那个稀有度的
    // 池子里选. 少了这一步会从**全部**小丑里挑, 而且连稀有度那一掷都省了, 两边的序列都会偏
    // (`create_card` 的其余几类没有稀有度分流, 所以只有小丑要单独走).
    if kind == "Joker" {
        let roll = run
            .rng
            .pseudorandom(&format!("rarity{}{key_append}", run.ante));
        let rarity = if roll > 0.95 {
            3
        } else if roll > 0.7 {
            2
        } else {
            1
        };
        return pick_joker_of_rarity(run, rarity, key_append, false)
            .unwrap_or_else(|| "j_joker".to_owned());
    }

    // 消耗牌那一段统一走 `create_consumable` —— 那是唯一的一份实现,
    // 计分那一层要造牌时也走它 (见 `scoring::score_play_with_creation`).
    let mut creation = creation_from(run);
    let key = create_consumable(&mut creation, &mut run.rng, kind, key_append, soulable);
    creation.merge_back(run);
    key
}

/// 塔罗, 行星与幻灵的池: 只要没被禁用就都在里面, 筛空了退到兜底项.
///
/// 与小丑池不同, 这几类没有稀有度分流, 也没有"用过就不再出现"的规则 —— 塔罗可以重复出现.
fn consumable_pool(kind: &str, creation: &Creation) -> Vec<String> {
    let category = match kind {
        "Tarot_Planet" => "Tarot",
        other => other,
    };
    let showman = creation.showman;
    let mut pool: Vec<String> = Vec::new();
    let mut usable = 0usize;
    for proto in Catalog::get().pool(category) {
        // 池子裁剪 (`get_current_pool` 里那一串 `add = ...`) 有三条会挡住一张牌:
        // 1. `hidden`: 灵魂与黑洞**永远不进池子** (它们只能从"灵魂那一骰"里出来);
        // 2. `enhancement_gate`: 牌堆里有那种强化牌才进 (钢小丑要你先有钢牌);
        // 3. 行星的 `softlock`: 那个牌型**打过至少一次**才进.
        // 少任何一条, 池子里的占位格子就对不上, 商店与包里抽到的东西会整体偏.
        let gated = proto.hidden
            || proto
                .enhancement_gate
                .as_deref()
                .is_some_and(|gate| !creation.enhanced.contains(gate))
            || {
                let config = proto.config.as_ref();
                let softlocked = config
                    .and_then(|c| c.get("softlock"))
                    .and_then(crate::data::json::Json::as_bool)
                    .unwrap_or(false);
                softlocked
                    && !creation.played.contains(
                        config
                            .and_then(|c| c.get("hand_type"))
                            .and_then(crate::data::json::Json::as_str)
                            .unwrap_or(""),
                    )
            };
        // `used_jokers` 这一条对**所有类型**都生效 (游戏那段裁剪是共用的), 不只是小丑:
        // 商店里刚出现过的那张塔罗, 在这一格里就只能是 `UNAVAILABLE` —— 抽中它会重抽,
        // 于是抽出来的东西跟着变. 少了它, 秘术包里的牌会整体偏一位.
        let used = creation.used.contains(&proto.id) && !showman;
        if !creation.banned.contains(&proto.id) && !gated && !used {
            pool.push(proto.id.clone());
            usable += 1;
        } else {
            pool.push("UNAVAILABLE".to_owned());
        }
    }
    if usable == 0 {
        pool = vec![fallback_for_category(category).to_owned()];
    }
    pool
}

/// 池被筛空时的兜底, 对应 `get_current_pool` 末尾那段.
fn fallback_for_category(category: &str) -> &'static str {
    match category {
        "Tarot" => "c_strength",
        "Planet" => "c_pluto",
        "Spectral" => "c_incantation",
        _ => "j_joker",
    }
}

/// 商店的一整面货架. 优惠券一格, 小丑两格, 补充包两个.
#[derive(Clone, Debug, Default)]
pub struct Shop {
    pub jokers: Vec<ShopCard>,
    /// 这一底的优惠券, 开局就算好了, 重抽不动它.
    pub voucher: Option<ShopCard>,
    /// 优惠券标签额外多摆出来的那一张.
    pub extra_voucher: Option<ShopCard>,
    pub packs: Vec<ShopCard>,
}

/// 货架的格子数, 对应 `G.GAME.shop` 里的限额.
pub const JOKER_SLOTS: usize = 2;
const PACK_SLOTS: usize = 2;

/// 抽这一格的包时用哪个键.
const SHOP_PACK_KEY: &str = "shop_pack";

impl Shop {
    /// 铺一次货架, 顺序照游戏: 两张小丑, 然后两个包.
    ///
    /// 优惠券不在这里抽 —— 它在开局 (以及打败 Boss 之后) 就算好了, 这里只是摆上货架.
    pub fn restock(run: &mut RunState) -> Shop {
        let rates = super::voucher::rates_of(run);
        let jokers = (0..JOKER_SLOTS + run.shop_size_bonus)
            .map(|_| create_card_for_shop(run, &rates))
            .collect();
        // 券那一格的键在这**之后**、包**之前**才抽 —— 游戏里的顺序就是"卡 -> 券 -> 包"
        // (`game.lua` 里 `create_card_for_shop(G.shop_jokers)` 在前, 券的 `Card(...)` 在中间,
        // `get_pack('shop_pack')` 在最后). 这个顺序不是随便的: 全局随机序列的位置由**最后一次**
        // `pseudorandom` 决定, 而 `get_pack` 第一次调用会用全局的 `math.random(1, 2)` 挑那个
        // 白送的小人包 —— 所以券抽在包后面还是前面, 决定了赠包是 `_1` 还是 `_2`.
        // 整局对拍里 133 步那份第 4 步的赠包就是这么差的 (引擎 `_2`, 记录 `_1`).
        // 券已经买走的那一底不再摆券 (`voucher_spent`), 而不是"空着就再抽一张" ——
        // 这两种情形在下面那句注释说的时机之外还得分开, 见 `RunState::voucher_spent`.
        if run.shop_vouchers.is_empty() && !run.voucher_spent {
            let key = run.next_voucher_key();
            run.shop_vouchers.push(key);
        }
        let packs = (0..PACK_SLOTS)
            .map(|_| {
                let key = get_pack(run, SHOP_PACK_KEY);
                let mut card = ShopCard::plain(key);
                card.cost = shop_cost(
                    base_cost_of(&card.key),
                    None,
                    false,
                    run.inflation,
                    run.discount_percent,
                );
                card
            })
            .collect();
        // 优惠券那一格: 键在开局 (或打败 Boss 之后) 就算好了, 这里只摆上货架并标价.
        let voucher = run.shop_vouchers.first().map(|key| {
            let mut card = ShopCard::plain(key.clone());
            card.cost = shop_cost(
                base_cost_of(&card.key),
                None,
                false,
                run.inflation,
                run.discount_percent,
            );
            card
        });
        // 优惠券标签让券那一格多摆一张.
        let extra_voucher = run.extra_voucher_key.clone().map(|key| {
            let mut card = ShopCard::plain(key);
            card.cost = shop_cost(
                base_cost_of(&card.key),
                None,
                false,
                run.inflation,
                run.discount_percent,
            );
            card
        });
        Shop {
            jokers,
            voucher,
            extra_voucher,
            packs,
        }
    }

    /// 重抽小丑那两格. 优惠券与补充包不动 —— 游戏里 `reroll_shop` 只清 `shop_jokers`.
    pub fn reroll_jokers(&mut self, run: &mut RunState) {
        // 旧的这几张**先被收走** (游戏里是 `remove_card` 加 `c:remove()` 那两句),
        // 所以它们的"用过"记录要按"手里还有没有同名卡"清掉 —— 清完再抽新的, 顺序与游戏一致.
        // 少了这一步, 被抽掉的那些小丑会一直占着池子里的格子, 之后抽出来的都会偏.
        let old: Vec<String> = self.jokers.iter().map(|card| card.key.clone()).collect();
        for key in old {
            run.forget_used_if_gone(&key);
        }
        let rates = super::voucher::rates_of(run);
        self.jokers = (0..JOKER_SLOTS + run.shop_size_bonus)
            .map(|_| create_card_for_shop(run, &rates))
            .collect();
    }
}

/// 包里的一张牌. 标准包开出来的会有版本与蜡封, 其他的各自不同.
#[derive(Clone, Debug, PartialEq)]
pub struct PackCard {
    pub key: String,
    pub edition: Option<Edition>,
    pub seal: Option<Seal>,
    /// 标准包里开出来的强化牌会带上这个.
    pub enhancement: Option<Enhancement>,
    /// 下面三个只对小丑包有意义: 包里的小丑与商店货架上的一样会掷永恒 / 易腐 / 租赁.
    pub eternal: bool,
    pub perishable: bool,
    pub rental: bool,
}

/// 买下并开好的补充包.
///
/// 包里有什么在买下那一刻就定死了, 与后面挑哪张无关 —— 所以挑剩下的那些牌也已经消耗过随机数.
#[derive(Clone, Debug)]
pub struct OpenPack {
    /// 包的原型键.
    pub key: String,
    /// 包里的卡, 按生成顺序.
    pub contents: Vec<PackCard>,
    /// 还能挑几张, 取自原型的 `config.choose`.
    pub choices_left: usize,
    /// 这张包开了几张给玩家挑, 用于回报.
    pub size: usize,
}

/// `poll_edition` 的 `guaranteed` 分支: 必定出版本, 阈值乘 25.
///
/// 光环那张幻灵用它 —— 与普通抽版本的区别只在这里, 所以单开一个入口而不是加参数.
pub fn poll_edition_guaranteed(run: &mut RunState, key: &str) -> Option<Edition> {
    let poll = run.rng.pseudorandom(key);
    // 阈值就是游戏里那三个 `1 - k*25`, 分别是 0.85 / 0.5 / 0.0 ——
    // 最后一个恰好归零, 所以这一档**必定至少给闪箔** (只有 poll 精确等于 0 时才没有).
    // 光环调用时带着 `_no_neg`, 所以负片不在这条链上.
    if poll > 0.85 {
        Some(Edition::Polychrome)
    } else if poll > 0.5 {
        Some(Edition::Holo)
    } else if poll > 0.0 {
        Some(Edition::Foil)
    } else {
        None
    }
}

/// 开一个补充包, 返回包里那几张.
///
/// 张数取自原型的 `config.extra`. 包里有什么在这一刻就定了, 与玩家后来挑哪张无关 ——
/// 所以挑剩下的那些也照样消耗掉了随机数.
pub fn open_pack(run: &mut RunState, pack_key: &str) -> Vec<PackCard> {
    // 幻觉: 开包时掷一次 (键 `halu{底注}`, 概率 1/2), 中了就额外给一张塔罗.
    // 它先看**消耗槽有没有位子** —— 游戏是"有位子才掷", 没位子时连骰子都不掷.
    if run.consumables.len() < run.consumable_slots
        && run
            .jokers
            .iter()
            .any(|joker| joker.key == "j_hallucination" && !joker.debuffed)
    {
        let odds = run
            .jokers
            .iter()
            .find(|joker| joker.key == "j_hallucination")
            .map(|joker| joker.extra)
            .unwrap_or(2.0);
        let key = format!("halu{}", run.ante);
        if odds > 0.0 && run.rng.pseudorandom(&key) < run.probability_scale / odds {
            let tarot = create_card(run, "Tarot", "hal");
            run.consumables
                .push(super::consumable::Consumable::plain(tarot));
        }
    }

    let kind = pack_kind_of(pack_key).unwrap_or("Tarot");
    let size = Catalog::get()
        .record(pack_key)
        .and_then(|proto| proto.config.as_ref())
        .and_then(|config| config.get("extra"))
        .and_then(crate::data::json::Json::as_f64)
        .map(|n| n as usize)
        .unwrap_or(1);

    let key_append = pack_key_append(kind);
    (0..size)
        .map(|index| {
            if kind == "Base" {
                return standard_pack_card(run, key_append);
            }
            // 望远镜 (优惠券): 天体包的**第一张**直接给"最常打牌型"的行动星牌.
            // 它走的是"指定卡"那条短路 (不掷灵魂骰也不抽池), 所以随机序列与平常不同.
            // 注意"一张牌都还没打过"的时候游戏是不指定任何牌的 (计数全为 0, 条件 `played > 0`
            // 一个都不满足), 那种情况下照常抽池.
            let telescope = if index == 0
                && kind == "Planet"
                && run.used_vouchers.contains("v_telescope")
                && run.hands.get(run.hands.most_played()).played > 0
            {
                let hand = run.hands.most_played().info().key;
                Catalog::get()
                    .pool("Planet")
                    .into_iter()
                    .find(|proto| {
                        proto
                                .config
                                .as_ref()
                                .and_then(|config| config.get("hand_type"))
                                .and_then(|value| value.as_str())
                                .is_some_and(|hand_type| hand_type == hand)
                    })
                    .map(|proto| proto.id.clone())
            } else {
                None
            };
            if let Some(key) = telescope {
                return PackCard {
                    key,
                    edition: None,
                    seal: None,
                    enhancement: None,
                    eternal: false,
                    perishable: false,
                    rental: false,
                };
            }
            // 字母球 (优惠券): 秘术包里的**每一张**都先掷一次 `omen_globe`,
            // 命中 (大于 0.8) 就换成幽灵牌, 而且池键也跟着从 `ar1` 变成 `ar2` ——
            // 键不同意味着后面抽池用的随机序列不是同一条, 所以这两处必须一起换.
            // 这一掷只有在买过那张优惠券时才发生 (游戏是 `used_vouchers.v_omen_globe and …`),
            // 没买过的局面随机序列完全不变.
            let (kind, key_append) = if kind == "Tarot"
                && run.used_vouchers.contains("v_omen_globe")
            {
                if run.rng.pseudorandom("omen_globe") > 0.8 {
                    ("Spectral", "ar2")
                } else {
                    (kind, key_append)
                }
            } else {
                (kind, key_append)
            };
            let mut card = PackCard {
                key: create_card(run, kind, key_append),
                edition: None,
                seal: None,
                enhancement: None,
                eternal: false,
                perishable: false,
                rental: false,
            };
            // 小丑包里的小丑与商店货架上的一样要掷"永恒 / 易腐 / 租赁 / 版本", 三掷的顺序也不能换.
            // **键跟商店不一样**: 游戏里按 `area` 取 `packetper` 与 `packssjr`,
            // 少掷一次或者用错键, 后面的随机序列就整体偏了.
            if kind == "Joker" {
                let poll = run.rng.pseudorandom(&format!("packetper{}", run.ante));
                if run.modifiers.enable_eternals_in_shop && poll > 0.7 {
                    card.eternal = true;
                } else if run.modifiers.enable_perishables_in_shop && poll > 0.4 && poll <= 0.7 {
                    card.perishable = true;
                }
                if run.modifiers.enable_rentals_in_shop
                    && run.rng.pseudorandom(&format!("packssjr{}", run.ante)) > 0.7
                {
                    card.rental = true;
                }
                // 版本这一项两边共用同一条键 (`edi` + 追加 + 底注).
                card.edition = poll_edition(
                    run,
                    &format!("edi{key_append}{}", run.ante),
                    1.0,
                    true,
                );
            }
            card
        })
        .collect()
}

/// 标准包里的一张牌.
///
/// 一张标准包的牌由**两份**东西拼出来, 各掷各的:
///
/// 1. 强化: 先看 `stdset{底注}` 决定要不要强化, 要的话从 `Enhanced` 池里抽一个 `m_`
///    (键是 `Enhanced{包键}{底注}`), 不要就是裸牌;
/// 2. 牌面: 从 52 张里抽一张, 键是 `front{包键}{底注}`.
///
/// 之后才是版本与蜡封. 这四件事的顺序不能换, 换了随机数就对不上.
fn standard_pack_card(run: &mut RunState, key_append: &str) -> PackCard {
    let enhanced = run
        .rng
        .pseudorandom(&format!("stdset{}", run.ante))
        > 0.6;

    let enhancement = if enhanced {
        let pool: Vec<String> = Catalog::get()
            .pool("Enhanced")
            .iter()
            .map(|proto| proto.id.clone())
            .collect();
        let enhanced_key = format!("Enhanced{key_append}{}", run.ante);
        let picked = pick_or_resample(&mut run.rng, &pool, &enhanced_key);
        Enhancement::from_key(&picked)
    } else {
        None
    };

    let faces: Vec<String> = standard_deck().iter().map(|card| card.key()).collect();
    let front_key = format!("front{key_append}{}", run.ante);
    let face = pick_or_resample(&mut run.rng, &faces, &front_key);

    let mut card = PackCard {
        key: face,
        edition: None,
        seal: None,
        enhancement,
        // 标准包开出来的是扑克牌, 没有永恒 / 易腐 / 租赁那回事.
        eternal: false,
        perishable: false,
        rental: false,
    };

    card.edition = poll_edition(
        run,
        &format!("standard_edition{}", run.ante),
        2.0,
        false,
    );

    // 蜡封的几率是 2%, 写成 `1 - 0.02 * 10` 与游戏一致.
    let seal_rate = 10.0;
    let seal_poll = run.rng.pseudorandom(&format!("stdseal{}", run.ante));
    if seal_poll > 1.0 - 0.02 * seal_rate {
        let seal_type = run.rng.pseudorandom(&format!("stdsealtype{}", run.ante));
        card.seal = Some(if seal_type > 0.75 {
            Seal::Red
        } else if seal_type > 0.5 {
            Seal::Blue
        } else if seal_type > 0.25 {
            Seal::Gold
        } else {
            Seal::Purple
        });
    }

    card
}

/// `get_pack`: 抽一个补充包原型.
///
/// 第一次进商店时游戏无条件给基础小丑包 (`p_buffoon_normal_1` 或 `_2`), 用一次裸的
/// `math.random(1, 2)` 决定, 所以那一次会消耗当前的全局 PRNG 状态.
pub fn get_pack(run: &mut RunState, key: &str) -> String {
    if !run.first_shop_buffoon && !run.banned_keys.contains("p_buffoon_normal_1") {
        run.first_shop_buffoon = true;
        let n = run.rng.random_int_range(1.0, 2.0) as i64;
        return format!("p_buffoon_normal_{n}");
    }

    let boosters = Catalog::get().pool("Booster");
    let kind: Option<&str> = None;
    let total: f64 = boosters
        .iter()
        .filter(|proto| kind.is_none() && !run.banned_keys.contains(&proto.id))
        .map(|proto| weight_of(proto))
        .sum();
    let poll = run
        .rng
        .pseudorandom(&format!("{key}{}", run.ante))
        * total;

    let mut cumulative = 0.0;
    for proto in &boosters {
        if run.banned_keys.contains(&proto.id) {
            continue;
        }
        let weight = weight_of(proto);
        cumulative += weight;
        if cumulative >= poll && cumulative - weight <= poll {
            return proto.id.clone();
        }
    }
    // 兜底: 与游戏一样, 落在边界之外时不给东西, 但这里宁可报出来.
    panic!("卡包加权抽签落到了区间之外 (poll={poll}, total={total})");
}

/// 补充包的权重, 没有 `weight` 字段时按 1 算 (对应 `v.weight or 1`).
fn weight_of(proto: &crate::data::catalog::Prototype) -> f64 {
    proto.weight.unwrap_or(1.0)
}

/// `pseudorandom_element` 加上那个抽到占位就重抽的循环. 重抽序号从 2 起.
pub fn pick_or_resample(rng: &mut crate::rng::Rng, pool: &[String], pool_key: &str) -> String {
    // 池子里一张可用的都没有时不能再抽下去 —— 重抽样永远抽不到, 会无限循环.
    // 传奇小丑就常是这样: 它们要解锁之后才进池子.
    if pool.iter().all(|key| key == "UNAVAILABLE") {
        return "UNAVAILABLE".to_owned();
    }
    let mut it = 1usize;
    let mut key = pool_key.to_owned();
    loop {
        let picked = rng.pick(pool, &key).clone();
        if picked != "UNAVAILABLE" {
            return picked;
        }
        it += 1;
        key = format!("{pool_key}_resample{it}");
    }
}

/// 待办清单换牌型时的掷法: 池子是**当前可见**的牌型, 键 `to_do`,
/// 而且要**循环掷到和原来不同**为止 (游戏的 `while not to_do_poker_hand` 就是这个意思).
///
/// 这个循环不能省成"掷一次" —— 每掷一次都会推进 `to_do` 这个键的值, 少掷一次,
/// 后面所有按键取随机数的地方都会错开.
pub fn roll_todo(
    rng: &mut crate::rng::Rng,
    hands: &crate::scoring::HandTable,
    old: Option<crate::scoring::PokerHand>,
) -> crate::scoring::PokerHand {
    use crate::scoring::PokerHand;
    let pool: Vec<String> = PokerHand::BY_PRIORITY
        .iter()
        .filter(|hand| hands.get(**hand).visible)
        .filter(|hand| Some(**hand) != old)
        .map(|hand| hand.index().to_string())
        .collect();
    loop {
        let picked = rng.pick(&pool, "to_do").clone();
        if let Ok(index) = picked.parse::<usize>()
            && index < PokerHand::BY_PRIORITY.len()
        {
            return PokerHand::BY_PRIORITY[index];
        }
    }
}
