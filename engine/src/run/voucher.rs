//! 优惠券买下之后对局面的改动.
//!
//! 对应游戏的 `Card:apply_to_run`: 券不进持有区, 买下的那一刻就把规则改掉.
//! **券的效果与"记下买了哪张券"是两件事** —— 只记不施加的话, 券就是白买的 (这确实发生过).
//!
//! 多数券是"把某个字段设成 / 加上 `config.extra`", 所以这里按原型里的 `extra` 取数, 不写死.
//! 少数几张 (望远镜 / 天文台 / 导演剪辑版 / 重构) 改的是别处的行为, 见各自的注释.

use crate::data::catalog::Catalog;

use super::state::RunState;

/// 原型里 `config.extra` 的数值. 券的 `extra` 都是数字.
fn extra_of(key: &str) -> f64 {
    Catalog::get()
        .record(key)
        .and_then(|proto| proto.config.as_ref())
        .and_then(|config| config.get("extra"))
        .and_then(crate::data::json::Json::as_f64)
        .unwrap_or(0.0)
}

/// 买下一张券之后施加它的效果.
///
/// 未知的键什么也不做 —— 原版 32 张券都在下面列着, 漏掉的那几张在注释里写明了原因.
pub fn apply(run: &mut RunState, key: &str) {
    let extra = extra_of(key);
    match key {
        // 库存过剩: 商店多摆一件小丑.
        "v_overstock_norm" | "v_overstock_plus" => run.shop_size_bonus += 1,
        // 清仓特卖 / 清算: 折扣是**设定**而不是叠加 (后者要求先买前者).
        "v_clearance_sale" | "v_liquidation" => {
            run.discount_percent = extra;
            super::shop::refresh_costs(run);
        },
        // 多次重掷 / 重掷加强版: 重抽基准价各减 2.
        "v_reroll_surplus" | "v_reroll_glut" => {
            run.reroll_base_cost = (run.reroll_base_cost - extra).max(0.0);
        }
        // 种子基金 / 摇钱树: 利息本金上限.
        "v_seed_money" | "v_money_tree" => run.interest_cap = extra,
        // 抓手 / 玉米片夹: 每回合多一次出牌.
        "v_grabber" | "v_nacho_tong" => run.hands_per_round += extra as i64,
        // 常弃常新 / 回收魔法: 每回合多一次弃牌.
        "v_wasteful" | "v_recyclomancy" => run.discards_per_round += extra as i64,
        // 油漆刷 / 调色板: 手牌上限各加一张.
        "v_paint_brush" | "v_palette" => run.hand_size_bonus += 1,
        // 水晶球: 多一个消耗牌格子.
        "v_crystal_ball" => run.base_consumable_slots += 1,
        // 反物质: 多一个小丑格子. 空白券本身什么也不做 (它只是反物质的前置).
        "v_antimatter" => run.base_joker_slots += 1,
        "v_blank" => {}
        // 打磨 / 焕彩: 商店出版本的频率.
        "v_hone" | "v_glow_up" => run.edition_rate = extra,
        // 塔罗商人 / 大亨: 塔罗的权重是 `4 x extra`.
        "v_tarot_merchant" | "v_tarot_tycoon" => run.tarot_rate = 4.0 * extra,
        // 星球商人 / 大亨同理.
        "v_planet_merchant" | "v_planet_tycoon" => run.planet_rate = 4.0 * extra,
        // 魔术 / 幻象: 商店开始卖扑克牌.
        "v_magic_trick" | "v_illusion" => run.playing_card_rate = extra,
        // 象形文字 / 岩画: 底注回退一级, 代价是少一次出牌 (或弃牌).
        "v_hieroglyph" | "v_petroglyph" => {
            run.ante -= extra as i64;
            if key == "v_hieroglyph" {
                run.hands_per_round -= extra as i64;
            } else {
                run.discards_per_round -= extra as i64;
            }
        }
        // 望远镜与天文台改的是"天体包内容"与"行星牌的加成", 走的不是这里的字段;
        // 导演剪辑版与重构改的是"重抽 Boss", 也各自有专门的入口.
        _ => {}
    }
}

/// 这一局此刻的商店权重, 由 [`RunState`] 上那几个字段折算而来.
///
/// 券改的是字段, 商店每次铺货再从这里取值 —— 这样买完券立刻生效, 不用回头改已铺好的货架.
pub fn rates_of(run: &RunState) -> super::shop::ShopRates {
    super::shop::ShopRates {
        joker: run.joker_rate,
        tarot: run.tarot_rate,
        planet: run.planet_rate,
        playing_card: run.playing_card_rate,
        spectral: run.spectral_rate,
    }
}
