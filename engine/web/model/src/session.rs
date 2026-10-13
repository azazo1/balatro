//! 每一步持有独立快照, 切换节点不丢弃旧路线.
use std::collections::BTreeMap;
use engine::{agent::action, data::json::Json as EngineJson, opening, run::{Phase, RunState, Snapshot}, scoring::EvalEnv};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use crate::{debug, error::{Error, Result}};

pub const MAX_NODES: usize = 5000;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Opening {
    #[serde(default)]
    pub seed: String,
    pub deck: String,
    pub stake: i64,
    pub profile: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Action {
    pub method: String,
    #[serde(default)]
    pub params: BTreeMap<String, Value>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Event {
    Action { action: Action },
    Edit { changes: BTreeMap<String, f64> },
}

pub struct Node {
    pub id: usize,
    pub parent: Option<usize>,
    pub event: Option<Event>,
    pub snapshot: Snapshot,
    pub report: Option<String>,
    pub note: String,
    pub edited: bool,
}

pub struct Session {
    pub opening: Opening,
    pub nodes: Vec<Node>,
    pub current: usize,
    pub revision: u64,
    pub debug: bool,
}

impl Session {
    pub fn new(mut spec: Opening) -> Result<Self> {
        if spec.seed.is_empty() { spec.seed = opening::generate_seed(); }
        spec.deck = opening::deck_of(&spec.deck).map_err(Error::bad)?;
        spec.profile = spec.profile.to_ascii_lowercase();
        let run = opening::create(&spec.seed, &spec.deck, spec.stake, &spec.profile).map_err(Error::bad)?;
        Ok(Self {
            opening: spec,
            nodes: vec![Node { id: 0, parent: None, event: None, snapshot: run.snapshot("开局"),
                report: None, note: "开局".to_owned(), edited: false }],
            current: 0, revision: 0, debug: false,
        })
    }

    pub fn state(&self) -> &RunState { self.nodes[self.current].snapshot.state() }

    pub fn check_revision(&self, revision: u64) -> Result<()> {
        if self.revision == revision { Ok(()) } else { Err(Error::conflict()) }
    }

    pub fn jump(&mut self, revision: u64, node: usize) -> Result<()> {
        self.check_revision(revision)?;
        if node >= self.nodes.len() { return Err(Error::bad("历史节点不存在")); }
        self.current = node;
        self.revision += 1;
        tracing::info!(node, revision = self.revision, "恢复历史节点");
        Ok(())
    }

    pub fn set_debug(&mut self, revision: u64, enabled: bool) -> Result<()> {
        self.check_revision(revision)?;
        self.debug = enabled;
        self.revision += 1;
        tracing::info!(enabled, "切换调试模式");
        Ok(())
    }

    pub fn commit(&mut self, revision: u64, event: Event) -> Result<()> {
        self.check_revision(revision)?;
        if matches!(event, Event::Edit { .. }) && !self.debug {
            return Err(Error::refused("请先开启调试模式"));
        }
        self.append(self.current, event)?;
        self.revision += 1;
        Ok(())
    }

    /// 导入和正常提交共用原子执行路径. 导入不改变调试开关.
    pub(crate) fn append(&mut self, parent: usize, event: Event) -> Result<()> {
        if self.nodes.len() >= MAX_NODES { return Err(Error::refused("历史已达到 5000 节点, 请保存后新开一局")); }
        let source = self.nodes.get(parent).ok_or_else(|| Error::bad("父节点不存在"))?;
        let mut candidate = source.snapshot.state().clone();
        let (note, report, edited) = match &event {
            Event::Action { action: input } => {
                validate_action(input, &candidate)?;
                let json = EngineJson::parse(&serde_json::to_string(input).map_err(|_| Error::internal())?)
                    .map_err(|e| Error::bad(format!("动作 JSON 无效: {e}")))?;
                let note = action::apply(&json, &mut candidate, &EvalEnv::default())
                    .map_err(|e| Error::refused(action::explain(&e, source.snapshot.state())))?;
                let report = if input.method == "play" { Some(note.clone()) } else { source.report.clone() };
                (note, report, source.edited)
            }
            Event::Edit { changes } => (debug::apply(&mut candidate, changes)?, source.report.clone(), true),
        };
        let id = self.nodes.len();
        self.nodes.push(Node { id, parent: Some(parent), event: Some(event), snapshot: candidate.snapshot(&note),
            report, note, edited });
        self.current = id;
        tracing::info!(id, parent, edited, event = ?self.nodes[id].event, phase = ?candidate.phase, "提交历史节点");
        Ok(())
    }

    pub fn path(&self) -> Vec<usize> {
        let mut path = vec![self.current];
        while let Some(parent) = self.nodes[*path.last().expect("路径不为空")].parent { path.push(parent); }
        path.reverse();
        path
    }

    pub fn actions_jsonl(&self) -> Result<String> {
        if self.nodes[self.current].edited { return Err(Error::refused("当前路径包含调试修改, 请保存原生会话文件")); }
        let mut lines = vec![serde_json::json!({"method":"start", "params":{
            "seed": self.opening.seed, "deck":self.opening.deck,
            "stake": opening::STAKES[(self.opening.stake - 1) as usize], "uda":self.opening.profile
        }}).to_string()];
        for node in self.path().into_iter().skip(1) {
            if let Some(Event::Action { action }) = &self.nodes[node].event {
                lines.push(serde_json::to_string(action).map_err(|_| Error::internal())?);
            }
        }
        Ok(format!("{}\n", lines.join("\n")))
    }
}

/// 外部动作参数必须先严格验证, 避免引擎宽松的浮点转下标截断.
fn validate_action(input: &Action, run: &RunState) -> Result<()> {
    let allowed: &[&str] = match input.method.as_str() {
        "select" | "skip" | "reroll_boss" | "endless" | "cash_out" | "next_round" | "reroll" => &[],
        "sort_hand_suit" | "sort_hand_value" => {
            if !matches!(run.phase, Phase::SelectingHand | Phase::BoosterOpened) || run.hand.is_empty() {
                return Err(Error::refused("当前没有可排序的手牌"));
            }
            &[]
        }
        "play" | "discard" => &["cards"],
        "rearrange" => &["hand", "jokers", "consumables"],
        "buy" | "buy_and_use" => &["card", "voucher", "pack", "use"],
        "sell" => &["joker", "consumable"],
        "use" => &["consumable", "cards"],
        "pack" => &["skip", "card", "targets"],
        _ => return Err(Error::bad("不支持的动作, 开局请使用新会话接口")),
    };
    for (key, value) in &input.params {
        if !allowed.contains(&key.as_str()) { return Err(Error::bad(format!("动作不接受参数 {key}"))); }
        if ["skip", "use"].contains(&key.as_str()) {
            if !value.is_boolean() { return Err(Error::bad(format!("{key} 必须是布尔值"))); }
        } else if ["cards", "targets", "hand", "jokers", "consumables"].contains(&key.as_str()) {
            let items = value.as_array().ok_or_else(|| Error::bad(format!("{key} 必须是下标数组")))?;
            let mut seen = std::collections::HashSet::new();
            for item in items {
                let index = item.as_u64().filter(|i| *i < 10000).ok_or_else(|| Error::bad("下标必须是非负整数"))?;
                if !seen.insert(index) { return Err(Error::bad("下标不能重复")); }
            }
        } else if value.as_u64().filter(|i| *i < 10000).is_none() {
            return Err(Error::bad("下标必须是非负整数"));
        }
    }
    let required: &[&str] = match input.method.as_str() {
        "play" | "discard" => &["cards"], "use" => &["consumable"], _ => &[],
    };
    if required.iter().any(|k| !input.params.contains_key(*k)) { return Err(Error::bad("动作缺少必需参数")); }
    let targets: &[&str] = match input.method.as_str() {
        "buy" | "buy_and_use" => &["card", "voucher", "pack"],
        "sell" => &["joker", "consumable"], "rearrange" => &["hand", "jokers", "consumables"],
        _ => &[],
    };
    if !targets.is_empty() && targets.iter().filter(|k| input.params.contains_key(**k)).count() != 1 {
        return Err(Error::bad("动作必须指定且只能指定一个区域目标"));
    }
    if input.method == "pack" {
        let skip = input.params.get("skip").and_then(Value::as_bool) == Some(true);
        if skip && (input.params.contains_key("card") || input.params.contains_key("targets")) {
            return Err(Error::bad("跳过卡包不能同时选牌"));
        }
        if !skip && !input.params.contains_key("card") { return Err(Error::bad("请选择卡包中的牌")); }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use engine::run::digest::digest;
    use serde_json::json;

    pub fn session() -> Session { Session::new(Opening { seed:"ALEEB".into(), deck:"RED".into(), stake:1, profile:"all".into() }).unwrap() }
    pub fn action(method: &str, params: Value) -> Event {
        Event::Action { action: serde_json::from_value(json!({"method":method,"params":params})).unwrap() }
    }

    #[test]
    fn branching_restores_rng_and_preserves_original_future() {
        let mut s = session();
        s.commit(0, action("select", json!({}))).unwrap();
        s.commit(1, action("discard", json!({"cards":[0,1]}))).unwrap();
        let expected = digest(s.state());
        let rng = format!("{:?}", s.state().rng);
        s.jump(2,1).unwrap();
        s.commit(3, action("discard", json!({"cards":[0,1]}))).unwrap();
        assert_eq!(digest(s.state()), expected);
        assert_eq!(format!("{:?}", s.state().rng), rng);
        assert_eq!(s.nodes.len(),4);
        assert_eq!(s.nodes[2].parent,Some(1));
        assert_eq!(s.nodes[3].parent,Some(1));
        s.jump(4,2).unwrap();
        assert_eq!(digest(s.state()), expected);
    }

    #[test]
    fn rejected_and_stale_actions_leave_state_and_history_untouched() {
        let mut s = session();
        let before = format!("{:?}",s.state());
        assert!(s.commit(0,action("buy",json!({"card":0}))).is_err());
        assert!(s.commit(0,action("start",json!({}))).is_err());
        assert!(s.commit(0,action("play",json!({"cards":[-1,1.5]}))).is_err());
        assert!(s.commit(1,action("select",json!({}))).is_err());
        assert_eq!(format!("{:?}",s.state()),before);
        assert_eq!(s.nodes.len(),1);
        assert_eq!(s.revision,0);
    }

    #[test]
    fn edits_are_atomic_permission_checked_and_only_taint_descendants() {
        let mut s = session();
        let edit = Event::Edit { changes: BTreeMap::from([("dollars".into(),50.0)]) };
        assert!(s.commit(0,edit.clone()).is_err());
        s.set_debug(0,true).unwrap();
        let invalid = Event::Edit { changes: BTreeMap::from([("dollars".into(),50.0),("hands_left".into(),-1.0)]) };
        let money = s.state().dollars;
        assert!(s.commit(1,invalid).is_err());
        assert_eq!(s.state().dollars,money);
        s.commit(1,edit).unwrap();
        assert_eq!(s.state().dollars,50.0);
        s.set_debug(2,false).unwrap();
        assert!(s.actions_jsonl().is_err());
        s.jump(3,0).unwrap();
        s.commit(4,action("select",json!({}))).unwrap();
        assert!(!s.nodes[s.current].edited);
        assert!(s.actions_jsonl().is_ok());
        assert!(s.nodes[1].edited);
    }
}
