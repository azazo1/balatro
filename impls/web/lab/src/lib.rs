pub mod debug;
pub mod error;
pub mod format;
pub mod preview;
pub mod session;
pub mod view;

use std::collections::BTreeMap;
use serde::Deserialize;
use session::{Action, Event, Session};
use error::Result;

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Action { revision: u64, action: Action },
    Jump { revision: u64, node: usize },
    Debug { revision: u64, enabled: bool },
    Edit { revision: u64, changes: BTreeMap<String, f64> },
}

/// 只读预览请求. 带上 revision, 页面据此丢弃过期结果; 预览本身不推进 revision.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreviewRequest { pub revision: u64, pub cards: Vec<usize> }

pub fn preview(session: &Session, request: &PreviewRequest) -> Result<serde_json::Value> {
    session.check_revision(request.revision)?;
    if request.cards.is_empty() || request.cards.len() > 5 { return Err(error::Error::bad("预览需要 1 到 5 张牌")); }
    preview::preview(session, &request.cards)
}

pub fn command(session: &mut Session, command: Command) -> Result<()> {
    match command {
        Command::Action { revision, action } => session.commit(revision, Event::Action { action }),
        Command::Jump { revision, node } => session.jump(revision, node),
        Command::Debug { revision, enabled } => session.set_debug(revision, enabled),
        Command::Edit { revision, changes } => session.commit(revision, Event::Edit { changes }),
    }
}
