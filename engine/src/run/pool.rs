//! 候选池与抽取.
//!
//! 抄自 `game/functions/common_events.lua` 的 `get_current_pool` (L1963) 与 `get_next_voucher_key`
//! (L1901), `get_next_tag_key` (L1914).
//!
//! 有两点必须照抄:
//!
//! - 池子与起始池**等长**: 被过滤掉的项占一个 `'UNAVAILABLE'` 空位而不是被删掉. 抽取按池子长度
//!   取下标, 占位因此会改变下标分布.
//! - 池键末尾拼底注 (`'Voucher' .. ante`), 抽到占位时再拼 `_resampleN` 用同一个池重抽.

use crate::data::catalog::{Catalog, Prototype};


use super::state::RunState;

/// 被过滤掉的项在池子里占的位置.
const UNAVAILABLE: &str = "UNAVAILABLE";

/// 池子被筛空时的兜底项, 对应 `get_current_pool` 末尾那段.
fn fallback_for(category: &str) -> &'static str {
    match category {
        "Tarot" | "Tarot_Planet" => "c_strength",
        "Planet" => "c_pluto",
        "Spectral" => "c_incantation",
        "Voucher" => "v_blank",
        "Tag" => "tag_handy",
        _ => "j_joker",
    }
}

/// 按起始池建出候选池, 返回 `(池, 池键)`.
///
/// `available` 决定每一项是否可入池, 对应 `get_current_pool` 里那一大段 cull.
fn build_pool(
    starting: Vec<&Prototype>,
    category: &str,
    run: &RunState,
    available: impl Fn(&Prototype) -> bool,
) -> (Vec<String>, String) {
    let mut pool: Vec<String> = Vec::with_capacity(starting.len());
    let mut usable = 0usize;
    for proto in &starting {
        if available(proto) && !run.banned_keys.contains(&proto.id) {
            pool.push(proto.id.clone());
            usable += 1;
        } else {
            pool.push(UNAVAILABLE.to_owned());
        }
    }

    if usable == 0 {
        pool = vec![fallback_for(category).to_owned()];
    }

    (pool, format!("{category}{}", run.ante))
}

/// 优惠券是否可入池, 对应 `get_current_pool` 的 `v.set == 'Voucher'` 分支.
fn voucher_available(proto: &Prototype, run: &RunState) -> bool {
    if run.used_vouchers.contains(&proto.id) {
        return false;
    }
    if run.shop_vouchers.contains(&proto.id)
        || run.extra_voucher_keys.contains(&proto.id)
        || run.shop.as_ref().is_some_and(|shop| shop.vouchers.iter().any(|card| card.key == proto.id)) {
        return false;
    }
    // 前置条件: 数组里的每一项都要已经兑换过.
    proto
        .requires
        .iter()
        .all(|required| run.used_vouchers.contains(required))
}

/// `get_current_pool('Voucher')`.
pub fn voucher_pool(run: &RunState) -> (Vec<String>, String) {
    let starting = Catalog::get().pool("Voucher");
    // 表演者 (Showman) 让"用过的"重新可以出现 —— 这条写在 `get_current_pool` 的**外层**条件里,
    // 所以它对**每一类**池子都成立, 券也不例外:
    //
    // ```lua
    // elseif not (G.GAME.used_jokers[v.key] and not next(find_joker("Showman"))) and ...
    // ```
    //
    // 券为什么会在 `used_jokers` 里: 那个表是在 `Card:set_ability` 里按**名字**写的,
    // 与牌是哪一类无关 —— 商店摆出来的券一样会被记进去 (`shop_vouchers` 只挡"这一底正摆着的那张").
    // 于是"上一底见过、没买"的券, 在持有表演者时是**可以**再出现的.
    let showman = run.jokers.iter().any(|joker| joker.key == "j_ring_master" && !joker.debuffed);
    build_pool(starting, "Voucher", run, |proto| {
        // cull 的外层条件: 没上过场 (或者有表演者), 且 (解锁了 或 是传奇).
        ((!run.used_jokers.contains(&proto.id) || showman) && run.unlocked(proto))
            && voucher_available(proto, run)
    })
}

impl RunState {
    /// 从池子里抽一项, 抽到占位就换 `_resampleN` 重抽.
    ///
    /// 对应 `get_next_voucher_key` 里那个 `while center == 'UNAVAILABLE'` 循环. 注意 `it` 从 1 起,
    /// 进循环先自增再用, 所以第一次重抽用的是 `_resample2` 而不是 `_resample1`.
    fn pick_from_pool(&mut self, pool: &[String], pool_key: &str) -> String {
        // 与商店那边的重抽样是同一件事, 所以共用一份实现 —— 那段逻辑写两遍的话,
        // 一处加了"池子全空"的保护另一处没有, 就会在某个入口上卡死 (踩过).
        super::shop::pick_or_resample(&mut self.rng, pool, pool_key)
    }

    /// `get_next_voucher_key()`.
    pub fn next_voucher_key(&mut self) -> String {
        let (pool, pool_key) = voucher_pool(self);
        self.pick_from_pool(&pool, &pool_key)
    }

    /// `get_next_voucher_key(true)`: 标签覆盖池键, 不附加底注.
    pub fn next_voucher_key_from_tag(&mut self) -> String {
        let (pool, _) = voucher_pool(self);
        self.pick_from_pool(&pool, "Voucher_fromtag")
    }

    /// `get_next_tag_key()`.
    ///
    /// 开局时用小盲注与大盲注各抽一个 ("跳过这个盲注能得到什么标签"), 底注提升时重抽.
    /// 抽取方式与优惠券一模一样, 连重抽的键都一样.
    pub fn next_tag_key(&mut self) -> String {
        let (pool, pool_key) = tag_pool(self);
        self.pick_from_pool(&pool, &pool_key)
    }
}

/// `get_current_pool('Tag')`.
///
/// 标签按最早底注与前置原型的发现状态筛选, 不使用小丑的解锁检查.
pub fn tag_pool(run: &RunState) -> (Vec<String>, String) {
    let starting = Catalog::get().pool("Tag");
    build_pool(starting, "Tag", run, |proto| {
        proto.min_ante.is_none_or(|minimum| minimum <= run.ante)
            && proto.tag_requires.as_deref().is_none_or(|required| {
                Catalog::get().record(required).is_some_and(|center| run.discovered(center))
            })
    })
}

/// 供测试用: 只做一次抽取, 不重采样, 便于看清池子与下标.
pub fn voucher_pick_index(run: &mut RunState) -> (Vec<String>, String, usize) {
    let (pool, pool_key) = voucher_pool(run);
    let seed = run.rng.pseudoseed(&pool_key);
    let index = run.rng.pick_index(pool.len(), seed);
    (pool, pool_key, index)
}
