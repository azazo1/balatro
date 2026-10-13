//! balatro-engine 的 Python 绑定.
//!
//! 目的是让搜索跑在引擎状态上: 一局的状态可以克隆 ([`Game::copy`]), 试一条分支只是复制一份
//! 内存, 不像命令行那样每次都要把整段历史重放一遍. 这样一来"在某一步把前几名候选都试一遍"
//! 才真的划算.
//!
//! 用法见同目录的 README.md.

use std::collections::HashMap;

use engine::agent::{action, summary};
use engine::data::json::Json;
use engine::run::{Phase, RunState};
use engine::scoring::EvalEnv;
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;

/// 内置的全解锁档, 与命令行 `play` 的默认档是同一份文件.
const UDA_ALL: &str = include_str!("../../data/uda-all.json");

/// 取存档进度表: 既接受裸的 uda 对象, 也接受录像那种 `{"snapshot":{"uda":{...}}}`.
fn uda_of(text: &str) -> PyResult<HashMap<String, String>> {
    let parsed =
        Json::parse(text).map_err(|error| PyValueError::new_err(format!("uda 解析失败: {error}")))?;
    let table = parsed
        .get("snapshot")
        .and_then(|snapshot| snapshot.get("uda"))
        .unwrap_or(&parsed);
    match table {
        Json::Object(entries) => Ok(entries
            .iter()
            .filter_map(|(key, value)| value.as_str().map(|flags| (key.clone(), flags.to_owned())))
            .collect()),
        other => Err(PyValueError::new_err(format!(
            "uda 应当是个对象, 实际 {other:?}"
        ))),
    }
}

/// 一局游戏. 状态可克隆, 所以搜索分支只花内存.
#[pyclass(skip_from_py_object)]
#[derive(Clone)]
struct Game {
    state: RunState,
}

#[pymethods]
impl Game {
    /// 开一局并走到"选择盲注".
    ///
    /// `stake` 是 1..8 的档位 (1 = 白色). `uda` 给 JSON 文本就用它, 不给就用内置的全解锁档.
    #[new]
    #[pyo3(signature = (seed, deck, stake, uda=None))]
    fn new(seed: &str, deck: &str, stake: i64, uda: Option<&str>) -> PyResult<Self> {
        let table = match uda {
            Some(text) => uda_of(text)?,
            None => uda_of(UDA_ALL)?,
        };
        let deck_key = if deck.starts_with("b_") {
            deck.to_owned()
        } else {
            format!("b_{}", deck.to_lowercase())
        };
        let mut state = RunState::new(seed, stake).with_deck(&deck_key).with_uda(table);
        state.start_run();
        Ok(Game { state })
    }

    /// 做一步. 返回引擎给的说明; 动作不合法时抛 ValueError, 消息就是"该怎么办".
    fn apply(&mut self, action_json: &str) -> PyResult<String> {
        let step = Json::parse(action_json)
            .map_err(|error| PyValueError::new_err(format!("动作解析失败: {error}")))?;
        let env = EvalEnv::default();
        match action::apply(&step, &mut self.state, &env) {
            Ok(what) => Ok(what),
            Err(error) => Err(PyValueError::new_err(action::explain(&error, &self.state))),
        }
    }

    /// 复制这一局 (搜索分支用).
    fn copy(&self) -> Game {
        self.clone()
    }

    /// 给 agent 看的那份局面文本.
    fn summary(&self) -> String {
        summary::render(&self.state, &summary::Extras::default())
    }

    /// 阶段的中文名.
    fn phase(&self) -> String {
        summary::phase_zh(self.state.phase).to_owned()
    }

    /// 阶段的英文枚举名, 供代码判断 (例如 `SelectingHand`).
    fn phase_key(&self) -> String {
        format!("{:?}", self.state.phase)
    }

    fn ante(&self) -> i64 {
        self.state.ante
    }

    fn chips(&self) -> f64 {
        self.state.chips
    }

    fn dollars(&self) -> f64 {
        self.state.dollars
    }

    fn hands_left(&self) -> i64 {
        self.state.hands_left
    }

    fn discards_left(&self) -> i64 {
        self.state.discards_left
    }

    fn won(&self) -> bool {
        self.state.won
    }

    fn over(&self) -> bool {
        matches!(self.state.phase, Phase::GameOver)
    }

    /// 当前盲注的目标分; 还没摆上盲注时是 0.
    fn target(&self) -> f64 {
        self.state.blind.as_ref().map_or(0.0, |blind| blind.chips)
    }

    /// 手牌: `(下标, token)`. token 形如 `S_K` `H_10`, 带强化或版本时后缀会跟在后面.
    fn hand(&self) -> Vec<(usize, String)> {
        self.state
            .hand
            .iter()
            .enumerate()
            .map(|(index, card)| (index, card.token()))
            .collect()
    }

    fn jokers(&self) -> Vec<String> {
        self.state.jokers.iter().map(|joker| joker.key.clone()).collect()
    }

    fn consumables(&self) -> Vec<String> {
        self.state.consumables.iter().map(|card| card.key.clone()).collect()
    }

    /// 内置全解锁档的原文.
    #[staticmethod]
    fn full_unlock_uda() -> &'static str {
        UDA_ALL
    }

    fn __repr__(&self) -> String {
        format!("<Game 底注 {} 阶段 {}>", self.state.ante, self.phase())
    }
}

#[pymodule]
fn balatro_engine(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<Game>()?;
    Ok(())
}
