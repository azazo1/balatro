//! 可复现的事件文件, 不序列化 Rust 内存布局. 版本入口集中在此.
use std::collections::BTreeMap;
use serde::{Deserialize, Serialize};
use crate::{error::{Error, Result}, session::{Event, MAX_NODES, Notice, Opening, Session}};

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

/// 存档只记开局和事件, 因此换了引擎构建也能重放.
/// 同版本要求逐步成功; 不同版本时, 重放失败的节点连同其后代被丢弃, 其余分支保留, 并在 `notice` 里说明.
pub fn import(file: File) -> Result<Session> {
    if file.format_version != 1 { return Err(Error::bad("不支持的会话格式版本")); }
    if file.opening.seed.is_empty() { return Err(Error::bad("保存的会话不能缺少种子")); }
    if file.nodes.is_empty() || file.nodes.len() > MAX_NODES || file.current >= file.nodes.len() {
        return Err(Error::bad("节点数量或当前节点无效"));
    }
    let same_build = file.engine_version == engine::VERSION;
    let mut candidate = Session::new(file.opening)?;
    let expected: BTreeMap<String,String> = candidate.state().uda.iter().map(|(k,v)|(k.clone(),v.clone())).collect();
    if same_build && expected != file.uda { return Err(Error::bad("解锁档与当前开局配置不一致")); }
    let root = &file.nodes[0];
    if root.id != 0 || root.parent.is_some() || root.event.is_some() { return Err(Error::bad("根节点必须是开局")); }
    tracing::info!(nodes = file.nodes.len(), file_version = %file.engine_version, same_build, "开始重建会话");
    // 旧节点号 -> 新节点号, 丢弃的节点为 None.
    let mut mapped: Vec<Option<usize>> = vec![Some(0)];
    let mut parents: Vec<Option<usize>> = vec![None];
    let mut first_failure: Option<String> = None;
    for (index,node) in file.nodes.into_iter().enumerate().skip(1) {
        let parent = node.parent.filter(|p| node.id == index && *p < index)
            .ok_or_else(|| Error::bad(format!("节点 {index} 的 ID 或父节点无效")))?;
        let event = node.event.ok_or_else(|| Error::bad(format!("节点 {index} 缺少事件")))?;
        parents.push(Some(parent));
        let Some(new_parent) = mapped[parent] else { mapped.push(None); continue };
        match candidate.append(new_parent,event) {
            Ok(()) => mapped.push(Some(candidate.nodes.len() - 1)),
            Err(e) if !same_build => {
                tracing::warn!(index, error = %e.message, "旧版本存档的节点无法在当前引擎重放, 丢弃该分支");
                first_failure.get_or_insert_with(|| format!("节点 {index}: {}", e.message));
                mapped.push(None);
            }
            Err(e) => return Err(Error { status:e.status, message:format!("节点 {index}: {}",e.message) }),
        }
        if index % 250 == 0 { tracing::info!(index,"重建会话进度"); }
    }
    // 当前节点被丢弃时退回到最近一个保留下来的祖先.
    let mut current = file.current;
    while mapped[current].is_none() { current = parents[current].expect("根节点总会保留"); }
    candidate.current = mapped[current].expect("已找到保留的祖先");
    if !same_build {
        let dropped = mapped.iter().filter(|m| m.is_none()).count();
        let message = match first_failure {
            None => format!("存档来自引擎 {}, 已在当前引擎 {} 上重放全部 {} 个节点", file.engine_version, engine::VERSION, mapped.len()),
            Some(reason) => format!("存档来自引擎 {}, 当前引擎重放时丢弃了 {dropped} 个节点 (首个失败于{reason})", file.engine_version),
        };
        candidate.notice = Some(Notice { message, dropped });
    }
    tracing::info!(current = candidate.current, nodes = candidate.nodes.len(), "会话重建完成");
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

    #[test]
    fn other_build_keeps_replayable_branches() {
        let mut session = Session::new(Opening { seed:"ALEEB".into(),deck:"RED".into(),stake:1,profile:"all".into() }).unwrap();
        let event = |method: &str, params| Event::Action { action: serde_json::from_value::<Action>(json!({"method":method,"params":params})).unwrap() };
        session.commit(0,event("select",json!({}))).unwrap();
        session.commit(1,event("discard",json!({"cards":[0]}))).unwrap();
        let mut file = export(&session);
        file.engine_version = "older-build".into();
        // 模拟旧引擎接受, 新引擎拒绝的一步, 以及挂在它下面的后代.
        file.nodes.push(SavedNode { id:3,parent:Some(1),event:Some(event("buy",json!({"card":9}))) });
        file.nodes.push(SavedNode { id:4,parent:Some(3),event:Some(event("discard",json!({"cards":[0]}))) });
        file.current = 4;
        let loaded = import(file).unwrap();
        assert_eq!(loaded.nodes.len(),3);
        assert_eq!(loaded.current,1);
        assert_eq!(loaded.notice.as_ref().map(|n| n.dropped),Some(2));
        // 同一构建仍然严格: 任何一步失败都拒绝整个文件.
        let mut strict = export(&session);
        strict.nodes.push(SavedNode { id:3,parent:Some(1),event:Some(event("buy",json!({"card":9}))) });
        assert!(import(strict).is_err());
    }
}
