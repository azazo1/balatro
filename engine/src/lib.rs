//! Balatro 规则引擎.
//!
//! 用 Rust 重写原版 Balatro 的规则层, 不带界面, 不依赖 LOVE 与图形环境, 供批量跑对局与分析使用.
//! 只覆盖原版内容, 不含 mod.
//!
//! 分模块推进, 每个模块都能用真游戏的数据对拍:
//!
//! - [`rng`]\: LuaJIT 的 `math.random` 与游戏的 `pseudoseed` 状态机. 对拍数据在 `tests/data/`.
//! - [`lua`]\: Lua 运行时语义 (`table.sort` 那一份不稳定快排).
//! - [`cards`]\: 牌的表示与建牌顺序.
//! - [`scoring`]\: 扑克牌型判定与牌型等级.
//! - [`data`]\: 静态原型数据 (从 `docs/game/data/catalog.json` 读).
//! - [`run`]\: 一局的状态与候选池抽取.
//! - [`batch`]\: 批量并行跑对局.
//! - [`agent`]\: 给 agent 用的一层 —— 局面摘要, 动态值, 提示词 (不参与规则计算).
//! - 其余模块 (计分引擎, 商店货架, 回合流程) 陆续加入.

pub mod agent;
pub mod batch;
pub mod cards;
pub mod jokers;
pub mod lua;
pub mod data;
pub mod rng;
pub mod run;
pub mod replay;
pub mod scoring;
