pub mod debug;
pub mod error;
pub mod format;
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

pub fn command(session: &mut Session, command: Command) -> Result<()> {
    match command {
        Command::Action { revision, action } => session.commit(revision, Event::Action { action }),
        Command::Jump { revision, node } => session.jump(revision, node),
        Command::Debug { revision, enabled } => session.set_debug(revision, enabled),
        Command::Edit { revision, changes } => session.commit(revision, Event::Edit { changes }),
    }
}
