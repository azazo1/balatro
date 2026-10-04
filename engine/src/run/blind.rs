//! 盲注: 目标分数与通关奖金.
//!
//! 抄自 `game/functions/misc_functions.lua` 的 `get_blind_amount` (L919) 与
//! `game/blind.lua` 的 `Blind:set_blind` (L78).
//!
//! 目标分数的算式是
//!
//! ```text
//! chips = get_blind_amount(底注, 难度档) * 盲注倍率 * 牌组的 ante_scaling
//! ```
//!
//! 所以等离子牌组的第一个小盲注是 `300 * 1 * 2 = 600`, 而不是标准牌组的 300.

use crate::data::catalog::{Catalog, Prototype};

/// 盲注种类.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BlindKind {
    Small,
    Big,
    Boss,
}

impl BlindKind {
    /// `Blind:get_type()` 用的名字, 也是 `modifiers.no_blind_reward` 的键.
    pub fn name(self) -> &'static str {
        match self {
            BlindKind::Small => "Small",
            BlindKind::Big => "Big",
            BlindKind::Boss => "Boss",
        }
    }
}

/// 本回合面对的盲注.
#[derive(Clone, PartialEq, Debug)]
pub struct Blind {
    pub kind: BlindKind,
    /// 原型键, 例如 `bl_small`.
    pub key: String,
    /// 是否已被禁用 (奇可: 拿到它时 Boss 盲注的效果整条不生效).
    pub disabled: bool,
    /// 目标分数.
    pub chips: f64,
    /// 通关后的固定奖金. 红注及以上小盲注会被清零.
    pub dollars: f64,
    /// 盲注倍率: 小盲注 1, 大盲注 1.5, Boss 2.
    pub mult: f64,
}

/// `get_blind_amount`: 底注对应的基准分数.
///
/// 三张表按难度档 (赌注 3 起为 2, 6 起为 3) 分开, 前八个底注查表, 之后走指数公式.
pub fn blind_amount(ante: i64, scaling: i64) -> f64 {
    const K: f64 = 0.75;
    let amounts: [f64; 8] = match scaling {
        1 => [
            300.0, 800.0, 2000.0, 5000.0, 11000.0, 20000.0, 35000.0, 50000.0,
        ],
        2 => [
            300.0, 900.0, 2600.0, 8000.0, 20000.0, 36000.0, 60000.0, 100000.0,
        ],
        _ => [
            300.0, 1000.0, 3200.0, 9000.0, 25000.0, 60000.0, 110000.0, 200000.0,
        ],
    };
    if ante < 1 {
        return 100.0;
    }
    if ante <= 8 {
        return amounts[(ante - 1) as usize];
    }

    let a = amounts[7];
    let b = 1.6;
    let c = (ante - 8) as f64;
    let d = 1.0 + 0.2 * (ante - 8) as f64;
    let mut amount = (a * (b + (K * c).powf(d)).powf(c)).floor();
    // 抹掉次高位以下, 让数字看起来整齐.
    let magnitude = 10f64.powf(amount.log10().floor() - 1.0);
    amount -= amount % magnitude;
    amount
}

/// 一局里前三个盲注的固定奖金, 对应原型上的 `reward_dollars`.
fn reward_for(kind: BlindKind) -> f64 {
    match kind {
        BlindKind::Small => 3.0,
        BlindKind::Big => 4.0,
        BlindKind::Boss => 5.0,
    }
}

fn multiplier_for(kind: BlindKind) -> f64 {
    match kind {
        BlindKind::Small => 1.0,
        BlindKind::Big => 1.5,
        BlindKind::Boss => 2.0,
    }
}

/// 按底注, 难度档与牌组的 `ante_scaling` 组出这一回合的盲注.
///
/// `key` 从 `catalog.json` 的 Blind 里查倍率与奖金, 所以小盲注 (`bl_small`), 大盲注 (`bl_big`)
/// 与各个 Boss 走同一段代码. `no_blind_reward` 对应赌注 2 起取消小盲注奖励那一条.
pub fn make_blind(
    kind: BlindKind,
    key: &str,
    ante: i64,
    scaling: i64,
    ante_scaling: f64,
    no_blind_reward: bool,
) -> Blind {
    let proto = Catalog::get().record(key);
    let mult = proto
        .and_then(|p| p.blind_multiplier)
        .unwrap_or_else(|| multiplier_for(kind));
    let reward = proto
        .and_then(|p| p.reward_dollars)
        .unwrap_or_else(|| reward_for(kind));
    // 赌注 2 起取消的是**小盲注**的固定奖金 (`modifiers.no_blind_reward.Small = true`),
    // 大盲注与 Boss 照发.
    let dollars = if no_blind_reward && kind == BlindKind::Small {
        0.0
    } else {
        reward
    };
    Blind {
        kind,
        key: key.to_owned(),
        // 墙 (The Wall) 的翻倍不用在这里做: 它的原型 `blind_multiplier` 本来就是 4,
        // 而别的 Boss 是 2, 差值就是翻倍.
        disabled: false,
        chips: blind_amount(ante, scaling) * mult * ante_scaling,
        dollars,
        mult,
    }
}

impl Blind {
    /// 停用这个盲注, **并把它自己做过的改动撤掉** —— 对应 `Blind:disable()`.
    ///
    /// 两条进入路径 (游戏里都是这一个函数):
    /// - **奇可 (传奇)**: 摆盲注时的 `setting_blind` 钩子, 于是这个 Boss 整条不生效;
    /// - **翠叶**: 卖掉一张小丑 (`Card:get_price` 那段里那句 `G.GAME.blind:disable()`).
    ///
    /// 它做的事按"有没有留下痕迹"分三类, 三样都得做:
    ///
    /// 1. **改过目标分数的要改回去**: 墙 (`mult = 4`) 除以 2, 紫瓶 (`mult = 6`) 除以 3 ——
    ///    两处都落回 Boss 的常规倍数 2. 这不是"凑数": 游戏里 `set_blind` 先按 `mult` 算出
    ///    目标分数, 而 `disable()` 里就写着 `self.chips = self.chips/2` 与 `/3`.
    ///    少了这一步, 手里有奇可时墙与紫瓶的目标分数会是**两倍与三倍**, 一个本来打得过的
    ///    盲注会直接判负.
    /// 2. **削过的牌要恢复**: `disable()` 结尾对**所有**牌与小丑重跑一遍 `debuff_card`,
    ///    而那时 `disabled` 已经是真, 于是每个分支都跳过, 落到最后那句 `card:set_debuff(false)`.
    ///    所以"卖小丑解除翠叶"这件事的实质就是**把整副牌的削弱清掉** —— 只置一个标志而
    ///    不清削弱, 卖完小丑这一回合剩下的手牌仍然一分不出.
    /// 3. **锁过的牌要解锁**: 蓝铃的 `forced_selection` 也在 `disable()` 里清掉.
    pub fn disable(&mut self) {
        if self.disabled {
            return;
        }
        self.disabled = true;
        // 1. 撤销对目标分数的改动.
        match self.key.as_str() {
            "bl_wall" => self.chips /= 2.0,
            "bl_final_vessel" => self.chips /= 3.0,
            _ => {}
        }
        // 2 / 3 由调用方负责清牌上的标志 (这里只有盲注自己, 拿不到牌).
    }
}


/// 非 Boss 的盲注键.
pub fn plain_blind_key(kind: BlindKind) -> &'static str {
    match kind {
        BlindKind::Small => "bl_small",
        BlindKind::Big => "bl_big",
        // Boss 的键由 `get_new_boss` 抽出来, 调用方要自己传.
        BlindKind::Boss => "bl_small",
    }
}

/// 一底里 Boss 被抽出来的方式: 全部的 Boss 里挑 `boss.min` 够得着这一底的,
/// 再按使用次数最少的留下, 最后在剩下的里面按 `boss` 这个伪随机键抽一个.
///
/// 键的顺序是**字符串升序**: 游戏那边 `eligible_bosses` 是哈希表, `pseudorandom_element` 对
/// 哈希表会先按 key 排序再取下标.
pub fn eligible_bosses<'a>(
    catalog: &'a Catalog,
    ante: i64,
    win_ante: i64,
    banned: &std::collections::HashSet<String>,
    used: &std::collections::HashMap<String, i64>,
) -> Vec<&'a Prototype> {
    let mut candidates: Vec<&Prototype> = catalog
        .pool("Blind")
        .into_iter()
        .filter(|p| {
            // 游戏那边是两支**并列**的判断 (`get_new_boss`):
            // - 普通 Boss: `min <= 底注`, 而且**底注不是 `win_ante` 的倍数** (或底注 < 2);
            // - 终局 Boss (`showdown`): 只看 `底注 % win_ante == 0 且 底注 >= 2`, **不看 min / max**.
            // 引擎原来两支都要过 `boss_reachable` (也就是查 min), 而终局那五个的 min 是 **10** ——
            // 于是底注 8 一个候选都没有, 直接"抽不出 Boss". 这是个会让第 8 底整局崩掉的真 bug.
            let is_showdown_ante = ante % win_ante == 0 && ante >= 2;
            match p.boss_showdown() {
                Some(true) => is_showdown_ante,
                Some(false) => !is_showdown_ante && boss_reachable(p, ante, win_ante),
                None => false,
            }
        })
        .filter(|p| !banned.contains(&p.id))
        .collect();

    // 只用过最少次数的那一批.
    let min_use = candidates
        .iter()
        .map(|p| used.get(&p.id).copied().unwrap_or(0))
        .min()
        .unwrap_or(0);
    candidates.retain(|p| used.get(&p.id).copied().unwrap_or(0) == min_use);

    candidates.sort_by(|a, b| a.id.cmp(&b.id));
    candidates
}

/// `boss.min <= max(1, ante)`.
fn boss_reachable(proto: &Prototype, ante: i64, _win_ante: i64) -> bool {
    let effective = ante.max(1);
    proto.boss_min().map(|min| min <= effective).unwrap_or(false)
}

impl Blind {
    /// 换个名字用的小工具, 让测试能直接断言.
    pub fn label(&self) -> &str {
        &self.key
    }
}

/// Boss 出现的底注上限与决战规则都用 `win_ante`, 原版是 8.
pub const DEFAULT_WIN_ANTE: i64 = 8;

/// 难度档: 赌注 3 起为 2, 6 起为 3, 其余为 1. 对应 `Game:start_run` 里的 `modifiers.scaling`.
pub fn scaling_for_stake(stake: i64) -> i64 {
    if stake >= 6 {
        3
    } else if stake >= 3 {
        2
    } else {
        1
    }
}

/// 回合结算栏.
#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct RoundEval {
    /// 固定盲注奖金.
    pub blind_reward: f64,
    /// 剩余出牌次数换来的钱, 默认每手 $1.
    pub hand_bonus: f64,
    /// 剩余弃牌次数换来的钱, 只有牌组设了单价才不为零.
    pub discard_bonus: f64,
    /// 利息.
    pub interest: f64,
    /// 手牌在回合末给的钱 (黄金牌与金封各三块).
    pub card_bonus: f64,
}

impl RoundEval {
    pub fn total(&self) -> f64 {
        self.blind_reward + self.hand_bonus + self.discard_bonus + self.interest + self.card_bonus
    }
}

/// 利息: 每完整 $5 给 `rate`, 本金上限 `cap`.
///
/// 基础 `rate = 1`, `cap = 25`, 所以最多 $5. 现金不到 $5 时为零, 负债也为零.
pub fn interest(dollars: f64, rate: f64, cap: f64) -> f64 {
    if dollars < 5.0 {
        return 0.0;
    }
    rate * (dollars / 5.0).floor().min(cap / 5.0)
}
