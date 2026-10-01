//! 跨线程取消: 另一线程直接 shutdown 请求线程正在用的 socket, 阻塞中的读写立即返回.

use std::net::{Shutdown, TcpStream};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Default)]
pub struct CancelToken {
    cancelled: AtomicBool,
    /// 请求线程所用 socket 的克隆 (同一个连接), 只用来 shutdown.
    socket: Mutex<Option<TcpStream>>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// 可重复调用. 先置标志再 shutdown, 与 `attach` 配合保证不会漏关.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        if let Some(sock) = self.lock().as_ref() {
            let _ = sock.shutdown(Shutdown::Both);
        }
    }

    /// 登记连接. 若登记前已被取消, 立即 shutdown, 请求线程随后的读写会马上失败.
    pub fn attach(&self, sock: TcpStream) {
        let mut slot = self.lock();
        if self.is_cancelled() {
            let _ = sock.shutdown(Shutdown::Both);
        }
        *slot = Some(sock);
    }

    /// 请求结束后释放克隆的 socket, 让连接真正关闭.
    pub fn detach(&self) {
        self.lock().take();
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Option<TcpStream>> {
        self.socket.lock().unwrap_or_else(|e| e.into_inner())
    }
}
