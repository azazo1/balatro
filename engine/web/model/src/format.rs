//! 可复现的事件文件, 不序列化 Rust 内存布局. 版本入口集中在此.
use std::collections::BTreeMap;
use serde::{Deserialize, Serialize};
use crate::{error::{Error, Result}, session::{Event, MAX_NODES, Opening, Session}};

pub const MAX_FILE_BYTES: usize = 10 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SavedNode {
    pub id: usize,
    pub parent: Option<usize>,
    pub event: Option<Event>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct File {
    pub format_version: u32,
    pub engine_version: String,
    pub opening: Opening,
    pub uda: BTreeMap<String, String>,
    pub nodes: Vec<SavedNode>,
    pub current: usize,
}

pub fn export(session: &Session) -> File {
    File {
        format_version: 1, engine_version: engine::VERSION.to_owned(), opening: session.opening.clone(),
        uda: session.nodes[0].snapshot.state().uda.iter().map(|(k,v)|(k.clone(),v.clone())).collect(),
        nodes: session.nodes.iter().map(|n| SavedNode { id:n.id,parent:n.parent,event:n.event.clone() }).collect(),
        current: session.current,
    }
}

/// 未知版本明确拒绝, 后续 migration 在此入口添加, 不散布于 UI.
pub fn decode(text: &str) -> Result<File> {
    if text.len() > MAX_FILE_BYTES { return Err(Error::bad("会话文件超过 10 MiB")); }
    let raw: serde_json::Value = serde_json::from_str(text).map_err(|e| Error::bad(format!("会话 JSON 无效: {e}")))?;
    if raw.get("format_version").and_then(serde_json::Value::as_u64) != Some(1) {
        return Err(Error::bad("不支持的会话格式版本, 当前只支持 v1"));
    }
    serde_json::from_value(raw).map_err(|e| Error::bad(format!("会话结构无效: {e}")))
}

pub fn import(file: File) -> Result<Session> {
    if file.format_version != 1 { return Err(Error::bad("不支持的会话格式版本")); }
    if file.engine_version != engine::VERSION { return Err(Error::bad(format!("引擎构建版本不同: 文件 {}, 当前 {}",file.engine_version,engine::VERSION))); }
    if file.opening.seed.is_empty() { return Err(Error::bad("保存的会话不能缺少种子")); }
    if file.nodes.is_empty() || file.nodes.len() > MAX_NODES || file.current >= file.nodes.len() {
        return Err(Error::bad("节点数量或当前节点无效"));
    }
    let mut candidate = Session::new(file.opening)?;
    let expected: BTreeMap<String,String> = candidate.state().uda.iter().map(|(k,v)|(k.clone(),v.clone())).collect();
    if expected != file.uda { return Err(Error::bad("解锁档与当前开局配置不一致")); }
    let root = &file.nodes[0];
    if root.id != 0 || root.parent.is_some() || root.event.is_some() { return Err(Error::bad("根节点必须是开局")); }
    tracing::info!(nodes = file.nodes.len(), "开始重建会话");
    for (index,node) in file.nodes.into_iter().enumerate().skip(1) {
        if node.id != index || !node.parent.is_some_and(|p| p < index) {
            return Err(Error::bad(format!("节点 {index} 的 ID 或父节点无效")));
        }
        let event = node.event.ok_or_else(|| Error::bad(format!("节点 {index} 缺少事件")))?;
        candidate.append(node.parent.expect("父节点已验证"),event)
            .map_err(|e| Error { status:e.status, message:format!("节点 {index}: {}",e.message) })?;
        if index % 250 == 0 { tracing::info!(index,"重建会话进度"); }
    }
    candidate.current = file.current;
    tracing::info!(current = candidate.current, "会话重建完成");
    Ok(candidate)
}

pub fn export_text(session: &Session) -> Result<String> {
    let text = serde_json::to_string(&export(session)).map_err(|_| Error::internal())?;
    if text.len() > MAX_FILE_BYTES { return Err(Error::refused("会话文件超过可导入的 10 MiB 限制")); }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Action,Event};
    use serde_json::json;

    #[test]
    fn export_import_preserves_every_branch_and_rng() {
        let mut session = Session::new(Opening { seed:"ALEEB".into(),deck:"RED".into(),stake:1,profile:"all".into() }).unwrap();
        let event = |method: &str, params| Event::Action { action: serde_json::from_value::<Action>(json!({"method":method,"params":params})).unwrap() };
        session.commit(0,event("select",json!({}))).unwrap();
        session.commit(1,event("discard",json!({"cards":[0,1]}))).unwrap();
        session.jump(2,1).unwrap();
        session.set_debug(3,true).unwrap();
        session.commit(4,Event::Edit { changes:BTreeMap::from([("dollars".into(),20.0)]) }).unwrap();
        let text = export_text(&session).unwrap();
        let loaded = import(decode(&text).unwrap()).unwrap();
        assert_eq!(loaded.current,session.current);
        assert!(!loaded.debug);
        for (a,b) in session.nodes.iter().zip(&loaded.nodes) {
            assert_eq!(a.parent,b.parent);
            assert_eq!(a.edited,b.edited);
            assert_eq!(a.report,b.report);
            assert_eq!(engine::run::digest::digest(a.snapshot.state()),engine::run::digest::digest(b.snapshot.state()));
            assert_eq!(a.snapshot.state().rng.diagnostics(),b.snapshot.state().rng.diagnostics());
        }
    }

    #[test]
    fn invalid_file_cannot_replace_existing_session() {
        let session = Session::new(Opening { seed:"ALEEB".into(),deck:"RED".into(),stake:1,profile:"new".into() }).unwrap();
        let mut file = export(&session);
        file.nodes.push(SavedNode { id:1,parent:Some(1),event:None });
        assert!(import(file).is_err());
        assert_eq!(session.nodes.len(),1);
        assert!(decode("{\"format_version\":2}").is_err());
    }
}
