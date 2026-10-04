//! 一次出牌的计分.
//!
//! 抄自 `game/functions/state_events.lua` 的 `G.FUNCS.evaluate_play` (L571 起) 与
//! `game/back.lua` 的 `Back:trigger_effect` (L108 起).
//!
//! 完整的出牌顺序有八段 (见 `docs/game/rules/scoring.md`):
//!
//! 1. 识别牌型, 取计分名单;
//! 2. 筹码与倍率先取牌型当前等级的基础值;
//! 3. 每张计分牌加上自己的点数筹码;
//! 4. 牌背的最终处理 (等离子把两者平均).
//!
//! 小丑的 `before` / 逐卡 / `joker_main` / `after` 与增强, 蜡封, 版本都接在下面:
//! 四段小丑钩子按游戏里的先后依次跑, 逐张牌的增强与版本在 `card_contributions` 里算.

use super::hand_levels::HandTable;
use super::poker_hand::{EvalEnv, HandCard, PokerHand, evaluate_poker_hand};
use crate::cards::Edition;
use crate::jokers::{Joker, TriggerContext};

/// 牌背对最终数值的处理.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BackEffect {
    /// 普通牌背: 不动.
    Plain,
    /// 等离子牌组: 筹码与倍率都变成 `floor((筹码 + 倍率) / 2)`.
    Plasma,
}

/// 计分过程中的一步, 用于复现卡面上的飘字顺序.
#[derive(Clone, Debug, PartialEq)]
pub struct ScoreStep {
    /// 序号, 与 `scoring_cards` 对应; 牌背那一步是 `None`.
    pub card: Option<usize>,
    pub chips: f64,
    pub mult: f64,
}

/// 一次出牌的结果.
#[derive(Clone, Debug, PartialEq)]
pub struct ScoreResult {
    /// 本次选中的牌型.
    pub hand: PokerHand,
    /// 计分名单, 是输入牌里的下标.
    pub scoring_cards: Vec<usize>,
    /// 牌型给的基础筹码与倍率 (尚未加牌面点数).
    pub base_chips: f64,
    pub base_mult: f64,
    pub chips: f64,
    pub mult: f64,
    /// 本次得分, `floor(chips * mult)`.
    pub total: f64,
    pub steps: Vec<ScoreStep>,
    /// 这一手之后用完就没了的小丑 (在 `jokers` 里的下标), 例如融化的冰淇淋.
    /// 调用方按这个把它从持有区移走.
    pub melted: Vec<usize>,
    /// 这一手**打出去的牌**直接给的钱, 来自金封 (`p_dollars`).
    ///
    /// 与黄金牌不同: 黄金牌是"留在手里"到回合末才给, 那份算在结算栏里.
    pub dollars: f64,
    /// 本次计分顺手造出来的消耗牌 (按顺序), 由运行层负责入槽.
    pub consumables: Vec<String>,
}

/// 沿着"复制链"找到真正生效的那张小丑.
///
/// 蓝图与脑风暴本身没有效果: 蓝图复制**右边**那张, 脑风暴复制**队首**那张.
/// 而复制对象可能本身也是蓝图 —— 游戏里这就是一层递归 (`calculate_joker` 会再次进同一个分支),
/// 所以这里要一直解到一张"有自己效果的"或者解不下去为止.
///
/// 解不下去时返回 `None` (例如蓝图在最右边, 或者脑风暴指着自己).
fn resolve_copy_target(jokers: &[Joker], index: usize) -> Option<&Joker> {
    let mut current = index;
    // 队里最多这么多张, 所以链长不会超过它 —— 上限只是防呆.
    for _ in 0..jokers.len() {
        match jokers[current].key.as_str() {
            "j_blueprint" => current += 1,
            "j_brainstorm" => current = 0,
            _ => return Some(&jokers[current]),
        }
        if current >= jokers.len() {
            return None;
        }
    }
    None
}

/// 版本给的那三项: 加筹码, 加倍率, 乘倍率.
///
/// 数值取自原型 (`e_foil` 是 50, `e_holo` 是 10, `e_polychrome` 是 1.5). 负片只加小丑格子数,
/// 计分上没有东西, 所以返回 `None` 而不是"三项全零".
fn edition_mods(edition: Option<Edition>) -> Option<(f64, f64, f64)> {
    match edition? {
        Edition::Foil => Some((50.0, 0.0, 1.0)),
        Edition::Holo => Some((0.0, 10.0, 1.0)),
        Edition::Polychrome => Some((0.0, 0.0, 1.5)),
        Edition::Negative => None,
    }
}

/// 给一次出牌算分.
///
/// `cards` 要按**手牌从左到右**的顺序传入: 游戏在出牌前会把选中的牌按横坐标排好再移进
/// 出牌区, 计分名单也跟着那个顺序走.
///
/// `jokers` 按持有顺序 (从左到右) 传入, `before` 阶段的成长与主效果都按这个顺序作用.
/// 这里要 `&mut`, 因为出牌前那一步会改小丑自己的成长值 (例如备用裤子, 绿色小丑).
///
/// 牌型识别不出来时返回 `None` (空手牌).
pub fn score_play(
    cards: &[HandCard],
    table: &HandTable,
    env: &EvalEnv,
    back: BackEffect,
    jokers: &mut [Joker],
) -> Option<ScoreResult> {
    score_play_with_held(cards, &[], table, env, back, jokers)
}

/// 同上, 但把**留在手里**的牌也交给计分.
///
/// 钢铁牌 (`h_x_mult`) 与男爵那类小丑看的是"没打出去, 还捏在手上的牌", 所以它们的效果
/// 只有在调用方把剩余手牌传进来时才算得出. 单独一个入口是为了不让不需要它的调用点
/// 都被迫传一个空切片.
///
/// 手牌的时机排在**逐卡计分之后, 小丑主效果之前** (`state_events.lua` 里 582 -> 798 -> 905
/// 那三段), 顺序换掉结果就不同.
pub fn score_play_with_held(
    cards: &[HandCard],
    held: &[HandCard],
    table: &HandTable,
    env: &EvalEnv,
    back: BackEffect,
    jokers: &mut [Joker],
) -> Option<ScoreResult> {
    // 这一档给"不掷骰"的调用方 (大多数测试与工具): 骰子用固定种子造一个临时的,
    // 结果是确定的, 只是与对局里那把骰子无关. 真正的对局走下面那个带 `rng` 的入口.
    let mut rng = crate::rng::Rng::new("scoring-without-dice");
    score_play_with_rng(cards, held, table, env, back, jokers, &mut rng)
}

/// 同上, 但把**骰子**也交进来.
///
/// 计分过程本身会掷骰 —— 幸运牌、血石、生意那几张都是"每张计分牌掷一次", 而且队里有几张
/// 就掷几次. 所以骰子必须由调用方 (持有 `RunState` 的那一层) 传进来:
/// `score_play` 保持"不改对局状态", 但随机数序列与游戏一致.
///
/// 对手牌无关的调用方来说, 传哪个 `rng` 都不影响结果 —— 只有带掷骰小丑时才看得出区别.
pub fn score_play_with_rng(
    cards: &[HandCard],
    held: &[HandCard],
    table: &HandTable,
    env: &EvalEnv,
    back: BackEffect,
    jokers: &mut [Joker],
    rng: &mut crate::rng::Rng,
) -> Option<ScoreResult> {
    // 这条入口不带"造牌的家当", 所以那些会在计分中造牌的小丑不会生效 ——
    // 测试与工具走这里, 运行层走 `score_play_with_creation`.
    let empty_banned = std::collections::HashSet::new();
    let mut creation = crate::run::shop::Creation {
        ante: 0,
        showman: false,
        banned: empty_banned,
        used: std::collections::HashSet::new(),
        enhanced: std::collections::HashSet::new(),
        played: std::collections::HashSet::new(),
    };
    score_play_inner(cards, held, table, env, back, jokers, rng, Some(&mut creation))
}

/// 与上面那条一样, 但**带上造牌的家当** —— 计分过程中要造牌的小丑 (八号球那类) 走这条.
#[allow(clippy::too_many_arguments)]
pub fn score_play_with_creation(
    cards: &[HandCard],
    held: &[HandCard],
    table: &HandTable,
    env: &EvalEnv,
    back: BackEffect,
    jokers: &mut [Joker],
    creation: &mut crate::run::shop::Creation,
    rng: &mut crate::rng::Rng,
) -> Option<ScoreResult> {
    score_play_inner(cards, held, table, env, back, jokers, rng, Some(creation))
}

#[allow(clippy::too_many_arguments)]
fn score_play_inner(
    cards: &[HandCard],
    held: &[HandCard],
    table: &HandTable,
    env: &EvalEnv,
    back: BackEffect,
    jokers: &mut [Joker],
    rng: &mut crate::rng::Rng,
    mut creation: Option<&mut crate::run::shop::Creation>,
) -> Option<ScoreResult> {
    let evaluated = evaluate_poker_hand(cards, env);
    let hand = evaluated.top()?;
    // 飞溅: 有它的时候**所有打出的牌**都进计分名单 (不只是凑成牌型的那几张).
    // 游戏在 `state_events.lua` 里分配 `scoring_hand` 时就是这个分叉.
    let mut scoring_cards = if env.splash {
        (0..cards.len()).collect()
    } else {
        evaluated.top_group()?.clone()
    };

    // 计分名单按屏幕从左到右排序, 而输入已经是这个顺序, 所以只需要把下标排一下.
    // 牌型判定返回的下标顺序是它自己找牌的顺序 (顺子按点数, 同花按花色), 不能直接用.
    scoring_cards.sort_unstable();
    let scoring_views: Vec<HandCard> = scoring_cards.iter().map(|&index| cards[index]).collect();

    let level = table.get(hand);
    let base_chips = level.chips(hand);
    let base_mult = level.mult(hand);
    let mut chips = base_chips;
    let mut mult = base_mult;

    // 燧石 (The Flint): 把**牌型的基础**筹码与倍率各砍一半, 而且是在逐卡计分**之前** ——
    // 所以它砍的是基础值, 后面牌的加成照常算. 两个下限分别是 0 与 1 (倍率不会低于 1).
    if env.flint {
        chips = (chips * 0.5 + 0.5).floor().max(0.0);
        mult = (mult * 0.5 + 0.5).floor().max(1.0);
    }

    let mut dollars = 0.0;
    // 小丑顺手造出来的消耗牌 (八号球 / 叠加态), 交给运行层入槽.
    let mut created: Vec<String> = Vec::new();

    // 上下文要在逐卡那一步**之前**建好 —— 照片那类逐卡效果也要看这手里有哪些牌,
    // 所以要提前拿到 `evaluated` 与 `scoring_views`.
    // 这一手型**之前**打过几次 (牌卡夏普看它). 引擎在计分之后才累加, 所以这里就是"之前".
    let played_this_round_before = table.get(hand).played_this_round;
    let ctx = TriggerContext {
        hand,
        hands: &evaluated,
        cards,
        // 参与计分的那几张, 按计分顺序摆好 (照片要看"第一张人头牌"是哪张).
        scoring: &scoring_views,
        held,
        full_hand_len: cards.len(),
        // 这几个由调用方通过 `env` 传进来; 计分本身不碰局面, 所以从环境里取.
        discards_left: env.discards_left,
        dollars: env.dollars,
        joker_count: jokers.len(),
        played_this_round: played_this_round_before,
        // 上古小丑看的花色由调用方通过 `env` 传进来 (与 flint 那几个同路).
        ancient_suit: env.ancient_suit,
        idol_card: env.idol_card,
        pareidolia: env.pareidolia,
        probability_extra: env.probability_extra,
        consumable_room: env.consumable_room,
        // 模具小丑的乘倍率要"队里有几张模具", 这里数好带过去.
        stencil_count: jokers.iter().filter(|joker| joker.key == "j_stencil").count(),
        joker_capacity: env.joker_capacity,
        hands_left: env.hands_left,
        deck_len: env.deck_len,
        deck_total: env.deck_total,
        deck_stones: env.deck_stones,
        deck_enhanced: env.deck_enhanced,
        starting_deck_size: env.starting_deck_size,
        deck_nines: env.deck_nines,
        planets_used: env.planets_used,
        discards_used: env.discards_used,
        table,
    };

    let mut steps = Vec::with_capacity(scoring_cards.len() + jokers.len() + 1);
    for &index in &scoring_cards {
        // 这张牌要算几遍: 它自己那份 (红封给一次) 加上各小丑给的重触发
        // (袜子与巴斯金 / 烂脱口秀演员 / 黄昏 / 挂账 / 汽水).
        // 游戏那边把这些收成一个列表, 再把整段逐卡效果重跑那么多次, 这里等价.
        let mut repeats = cards[index].repetitions.max(1);
        for joker in jokers.iter() {
            repeats += joker.retrigger(&cards[index], &ctx);
        }
        // 红封让这张牌多算一遍: 整段 (含它自己的筹码与逐卡小丑的效果) 都重跑, 不是只加倍率.
        for _ in 0..repeats {
            // 这一遍里这张幸运牌有没有**成功触发**过: 两个骰子中任意一个中了就算.
            // 游戏把它记在牌自己身上 (`Card.lucky_trigger`), 并在这一遍的逐卡小丑跑完之后清掉,
            // 所以它的作用范围正好是"这一遍", 而且每多算一遍就多一次机会.
            let mut lucky_trigger = false;
            // 金封: 这张牌被打出时直接给三块 (`Card:get_p_dollars`).
            if cards[index].gold_seal {
                dollars += 3.0;
            }
            chips += cards[index].chip_bonus();
            // 强化牌在计分时各给一份: 倍率牌加倍率, 玻璃牌乘倍率.
            mult += cards[index].mult_bonus();
            let x_mult = cards[index].x_mult();
            if x_mult > 0.0 {
                mult *= x_mult;
            }
            // 幸运牌的两份都靠掷骰 (1/5 给 +20 倍率, 1/15 给 20 块), 顺序是**倍率在前, 钱在后**
            // (`eval_card` 里 `get_chip_mult` 排在 `get_p_dollars` 前面).
            // 骰子只在**参与计分**的牌上掷 —— 打出去但没进计分名单的牌不掷;
            // 被削弱的牌连骰子都不掷 (`get_chip_mult` 与 `get_p_dollars` 开头都先判 debuff),
            // 所以这里少掷一次, **这个键**之后的取值就会跟着错位 (第几张幸运牌对不上).
            //
            // 注意影响范围**仅限这个键**: 游戏的 `pseudorandom(键)` 每次都按这个键自己重播种,
            // 所以别的键一点不受影响 (详见 `luajit_parity.rs::random_keys_are_independent`).
            // 这句话以前写成"后面所有掷骰都会错开一格", 那是错的, 按它去判断轻重会误判.
            //
            // 分子是 `G.GAME.probabilities.normal` (七上八下把它乘二), 不是写死的 1.
            if cards[index].lucky && !cards[index].debuffed {
                if rng.pseudorandom("lucky_mult") < (1.0 + env.probability_extra) / 5.0 {
                    mult += 20.0;
                    lucky_trigger = true;
                }
                if rng.pseudorandom("lucky_money") < (1.0 + env.probability_extra) / 15.0 {
                    dollars += 20.0;
                    lucky_trigger = true;
                }
            }

            // 逐张计分牌的小丑 (笑脸, 奇数托德那批): 每张牌各判一次, 按持有顺序.
            // 这里拿的是可变引用而不是 `iter()`: 幸运猫要当场改自己的成长值, 改完的那一份
            // 在**本次**的小丑主效果那一趟就要用上 (主效果排在逐卡之后), 不能等这一手结束再并回.
            for joker in jokers.iter_mut() {
                // 幸运猫: 这张幸运牌这一遍成功触发过就涨一份 (0.25 倍率).
                // 游戏写在 `context.individual` 分支里, 认的是同一张牌上的 `lucky_trigger` 标志;
                // 蓝图复制到它身上那一趟游戏会跳过成长, 这里同样只在它自己那一格长.
                if lucky_trigger {
                    joker.grow_on_lucky_trigger();
                }
                if let Some(effect) = joker.individual(&cards[index], &ctx, rng) {
                    mult += effect.mult_mod;
                    chips += effect.chip_mod;
                    dollars += effect.dollars;
                    if let Some((kind, append)) = effect.create_consumable
                        && let Some(creation) = creation.as_deref_mut()
                    {
                        let key = crate::run::shop::create_consumable(creation, rng, kind, append, true);
                        created.push(key);
                    }
                    if effect.xmult_mod != 0.0 {
                        mult *= effect.xmult_mod;
                    }
                }
            }

            // 版本是**这一条里的最后一步** (`state_events` 里排在自身的筹码与倍率之后):
            // 闪箔加筹码, 镭射加倍率, 多彩乘倍率. 负片没有计分效果.
            if let Some((chip, mult_mod, x_mult)) = edition_mods(cards[index].edition) {
                chips += chip;
                mult += mult_mod;
                if x_mult != 1.0 {
                    mult *= x_mult;
                }
            }

            steps.push(ScoreStep {
                card: Some(index),
                chips,
                mult,
            });
        }
    }

    // 手牌阶段: 留在手里没打出去的牌各给自己的乘倍率 (钢铁牌), 以及看手牌的小丑
    // (男爵, 射月, 致胜之拳). 它排在逐卡计分之后, 小丑主效果之前.
    for card in held {
        let x = card.h_x_mult();
        if x > 0.0 {
            mult *= x;
        }
        for joker in jokers.iter() {
            if let Some(effect) = joker.held(card, held, &ctx, rng) {
                mult += effect.mult_mod;
                chips += effect.chip_mod;
                dollars += effect.dollars;
                if let Some((kind, append)) = effect.create_consumable
                    && let Some(creation) = creation.as_deref_mut()
                {
                    let key = crate::run::shop::create_consumable(creation, rng, kind, append, true);
                    created.push(key);
                }
                if effect.xmult_mod != 0.0 {
                    mult *= effect.xmult_mod;
                }
            }
        }
    }
    if !held.is_empty() {
        steps.push(ScoreStep {
            card: None,
            chips,
            mult,
        });
    }

    // 小丑的两个阶段, 顺序不能换:
    //
    // 1. `before`: 成长类小丑先改自己的值 (备用裤子加 2, 绿色小丑加 1),
    // 2. `joker_main`: 每张按新值加筹码, 加倍率, 乘倍率, 与游戏里消费顺序一致
    //    (`mult_mod` -> `chip_mod` -> `Xmult_mod`).
    // "小丑互相看"那些 (棒球卡): 每张小丑问一遍别的小丑, 按答应的次数乘倍率.
    // 排在 `before` 之前 —— 它们只看队里有什么, 与自己的成长值无关.
    for index in 0..jokers.len() {
        for other_index in 0..jokers.len() {
            if other_index == index {
                continue;
            }
            let effect = jokers[index].other_joker(&jokers[other_index]);
            if let Some(effect) = effect {
                mult += effect.mult_mod;
                chips += effect.chip_mod;
                dollars += effect.dollars;
                if effect.xmult_mod != 0.0 {
                    mult *= effect.xmult_mod;
                }
            }
        }
    }

    for joker in jokers.iter_mut() {
        joker.before(&ctx);
    }
    for index in 0..jokers.len() {
        let effect =
            resolve_copy_target(jokers, index).and_then(|actual| actual.joker_main(&ctx, rng));
        let mut applied = false;
        if let Some(effect) = effect {
            mult += effect.mult_mod;
            chips += effect.chip_mod;
            dollars += effect.dollars;
            if effect.xmult_mod != 0.0 {
                mult *= effect.xmult_mod;
            }
            // 这一趟也会有"顺手造一张消耗牌"的小丑 (叠加态那类), 收集方式与逐卡那一趟一致.
            if let Some((kind, append)) = effect.create_consumable
                && let Some(creation) = creation.as_deref_mut()
            {
                let key = crate::run::shop::create_consumable(creation, rng, kind, append, true);
                created.push(key);
            }
            applied = true;
        }
        // 版本在这个格子的效果**之后**生效, 而且属于**格子里的那张牌** ——
        // 游戏里版本是单独一趟 (`context.edition`), 走的是卡自己, 蓝图复制的是别人的效果但不复制版本.
        if let Some((chip, mult_mod, x_mult)) = edition_mods(jokers[index].edition) {
            chips += chip;
            mult += mult_mod;
            if x_mult != 1.0 {
                mult *= x_mult;
            }
            applied = true;
        }
        if applied {
            steps.push(ScoreStep {
                card: None,
                chips,
                mult,
            });
        }
    }

    if back == BackEffect::Plasma {
        let half = ((chips + mult) / 2.0).floor();
        chips = half;
        mult = half;
    }
    steps.push(ScoreStep {
        card: None,
        chips,
        mult,
    });

    // 天文台: 消耗区里对应本手牌型的行星牌, 每张给一次 ×1.5.
    // 位置在**所有小丑的主效果之后** —— 游戏那边是小丑先遍历、消耗品后遍历 (同一个循环里).
    if env.observatory_planets > 0 {
        let factor = 1.5f64.powi(env.observatory_planets as i32);
        mult = (mult * factor).floor();
        steps.push(ScoreStep {
            card: None,
            chips,
            mult,
        });
    }

    // 计分结束之后才跑 `after`: 它只改下一轮要用的值 (冰淇淋融化), 所以放在牌背处理之后
    // 也不影响上面的数字. 返回值说明这张小丑用完就没了.
    let mut melted: Vec<usize> = Vec::new();
    for (index, joker) in jokers.iter_mut().enumerate() {
        if joker.after(&ctx) {
            melted.push(index);
        }
    }

    Some(ScoreResult {
        hand,
        scoring_cards,
        base_chips,
        base_mult,
        chips,
        mult,
        total: (chips * mult).floor(),
        steps,
        melted,
        dollars,
        consumables: created,
    })
}
