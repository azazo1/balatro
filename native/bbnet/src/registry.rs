//! 全局句柄表: 请求的发起, 轮询, 取消与释放.
//!
//! 每个请求一个线程, 线程把结果逐项推进 mpsc 队列, 主线程 poll 时每次取一项.
//! 结束 (DONE/ERROR) 后结果固定下来, 之后的 poll 一直返回它.

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};

use crate::http::request::Request;
use crate::net::CancelToken;
use crate::worker;

/// 请求线程交给主线程的一项结果.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Item {
    /// 响应头到达: 状态码与原始响应头.
    Status(u16, String),
    /// 一条完整的 SSE 事件.
    Event(Vec<u8>),
    /// 非 SSE 响应的一段响应体.
    Body(Vec<u8>),
    Done,
    Error(String),
}

impl Item {
    fn is_terminal(&self) -> bool {
        matches!(self, Item::Done | Item::Error(_))
    }
}

struct Entry {
    /// 结束后置空, 请求线程之后的发送会失败并退出.
    rx: Option<Receiver<Item>>,
    cancel: Arc<CancelToken>,
    terminal: Option<Item>,
}

static TABLE: LazyLock<Mutex<HashMap<i64, Entry>>> = LazyLock::new(Default::default);
static NEXT_ID: AtomicI64 = AtomicI64::new(1);

fn table() -> MutexGuard<'static, HashMap<i64, Entry>> {
    // 持锁时不会 panic, 即使中毒, 表本身仍是一致的.
    TABLE.lock().unwrap_or_else(|e| e.into_inner())
}

/// 登记请求并启动线程, 返回句柄.
pub fn start(request: Request) -> i64 {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let cancel = Arc::new(CancelToken::new());
    let (tx, rx) = mpsc::channel();
    let entry = match worker::spawn(id, request, tx, Arc::clone(&cancel)) {
        Ok(()) => Entry {
            rx: Some(rx),
            cancel,
            terminal: None,
        },
        Err(e) => Entry {
            rx: None,
            cancel,
            terminal: Some(Item::Error(format!("spawn: {e}"))),
        },
    };
    table().insert(id, entry);
    id
}

/// 取出一项结果, 没有新数据时返回 `None`.
pub fn poll(id: i64) -> Option<Item> {
    let mut table = table();
    let Some(entry) = table.get_mut(&id) else {
        return Some(Item::Error("invalid handle".into()));
    };
    if let Some(item) = &entry.terminal {
        return Some(item.clone());
    }
    let rx = entry.rx.as_ref()?;
    let item = match rx.try_recv() {
        Ok(item) => item,
        Err(TryRecvError::Empty) => return None,
        // 请求线程没有发出结束项就退出了, 只可能是线程内 panic.
        Err(TryRecvError::Disconnected) => Item::Error("internal: worker exited".into()),
    };
    if item.is_terminal() {
        entry.terminal = Some(item.clone());
        entry.rx = None;
    }
    Some(item)
}

/// 取消请求. 已结束的请求不受影响, 未结束的之后 poll 得到 ERROR "cancelled".
pub fn cancel(id: i64) {
    let token = {
        let mut table = table();
        let Some(entry) = table.get_mut(&id) else {
            return;
        };
        if entry.terminal.is_none() {
            entry.terminal = Some(Item::Error("cancelled".into()));
            entry.rx = None;
        }
        Arc::clone(&entry.cancel)
    };
    // shutdown 放在锁外, 不阻塞其他句柄的 poll.
    token.cancel();
}

/// 释放句柄, 未结束的请求先取消.
pub fn close(id: i64) {
    let entry = table().remove(&id);
    if let Some(entry) = entry {
        entry.cancel.cancel();
    }
}
