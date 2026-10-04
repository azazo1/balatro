//! 面向 agent 的一层: 局面摘要, 动态值, 动作施加, 提示词.
//!
//! 这一层不参与规则计算, 只把引擎已经算好的状态翻译成 agent 能用的信息, 对照内置 agent
//! (`mods/balatrobot/agent/`) 给模型的那一套:
//!
//! - [`summary`]\: 每步的局面摘要 (牌的中文名与效果, 盲注, 牌型等级, 上一手的明细).
//! - [`dynamics`]\: 会随局面变的值 (每回合认的花色点数, 小丑成长值).
//! - [`action`]\: 把一条动作施加到一局上.
//! - [`prompt`]\: 系统提示词.

pub mod action;
pub mod dynamics;
pub mod prompt;
pub mod summary;
