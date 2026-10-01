//! 请求线程: 连接, 发送请求, 读响应头, 解码响应体并分帧, 结果逐项推进队列.

use std::io::{self, Read, Write};
use std::sync::Arc;
use std::sync::mpsc::Sender;
use std::thread;

use crate::error::{Error, Result};
use crate::http::body::BodyDecoder;
use crate::http::request::Request;
use crate::http::response::{Head, parse_head};
use crate::net::{self, CancelToken, Conn};
use crate::registry::Item;
use crate::sse::SseFramer;

const READ_BUF_LEN: usize = 16 * 1024;

pub fn spawn(
    id: i64,
    request: Request,
    tx: Sender<Item>,
    cancel: Arc<CancelToken>,
) -> io::Result<()> {
    thread::Builder::new()
        .name(format!("bbnet-{id}"))
        .spawn(move || {
            let result = execute(&request, &tx, &cancel);
            cancel.detach();
            let last = match result {
                Ok(()) => Item::Done,
                // 取消后各种读写错误都只是 shutdown 的后果, 统一报 cancelled.
                Err(_) if cancel.is_cancelled() => Item::Error(Error::Cancelled.to_string()),
                Err(e) => Item::Error(e.to_string()),
            };
            let _ = tx.send(last);
        })
        .map(|_| ())
}

fn execute(request: &Request, tx: &Sender<Item>, cancel: &CancelToken) -> Result<()> {
    let mut conn = net::connect(&request.url, &request.timeouts, cancel)?;
    conn.write_all(&request.encode())
        .map_err(|e| Error::from_io("write", e))?;
    conn.flush().map_err(|e| Error::from_io("write", e))?;

    let mut buf = vec![0u8; READ_BUF_LEN];
    let (head, rest) = read_head(&mut conn, &mut buf, cancel)?;
    send(tx, Item::Status(head.status, head.raw_headers()))?;

    let mut decoder = BodyDecoder::new(head.framing(request.is_head())?);
    let mut sink = Sink::new(head.is_event_stream());
    let mut decoded = Vec::new();
    decoder.feed(&rest, &mut decoded)?;
    sink.push(&decoded, tx)?;
    while !decoder.is_done() {
        let n = read(&mut conn, &mut buf, cancel)?;
        if n == 0 {
            decoder.finish()?;
            break;
        }
        decoded.clear();
        decoder.feed(&buf[..n], &mut decoded)?;
        sink.push(&decoded, tx)?;
    }
    sink.finish(tx)
}

/// 读到完整的最终响应头, 跳过 1xx 中间响应. 返回响应头与已读到的响应体开头.
fn read_head(conn: &mut Conn, buf: &mut [u8], cancel: &CancelToken) -> Result<(Head, Vec<u8>)> {
    let mut pending = Vec::new();
    loop {
        if let Some((head, used)) = parse_head(&pending)? {
            pending.drain(..used);
            if head.is_interim() {
                continue;
            }
            return Ok((head, pending));
        }
        let n = read(conn, buf, cancel)?;
        if n == 0 {
            return Err(Error::Http("connection closed before response head".into()));
        }
        pending.extend_from_slice(&buf[..n]);
    }
}

fn read(conn: &mut Conn, buf: &mut [u8], cancel: &CancelToken) -> Result<usize> {
    loop {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        match conn.read(buf) {
            Ok(n) => return Ok(n),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(Error::from_io("read", e)),
        }
    }
}

/// 句柄已被取消或释放时队列另一端已丢弃, 请求线程随即停止.
fn send(tx: &Sender<Item>, item: Item) -> Result<()> {
    tx.send(item).map_err(|_| Error::Cancelled)
}

/// 解码后响应体的去向: SSE 按事件交出, 其余按段交出.
enum Sink {
    Sse(SseFramer),
    Raw,
}

impl Sink {
    fn new(event_stream: bool) -> Self {
        if event_stream {
            Sink::Sse(SseFramer::new())
        } else {
            Sink::Raw
        }
    }

    fn push(&mut self, data: &[u8], tx: &Sender<Item>) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        match self {
            Sink::Sse(framer) => {
                let mut events = Vec::new();
                framer.push(data, &mut events);
                events
                    .into_iter()
                    .try_for_each(|e| send(tx, Item::Event(e)))
            }
            Sink::Raw => send(tx, Item::Body(data.to_vec())),
        }
    }

    fn finish(&mut self, tx: &Sender<Item>) -> Result<()> {
        match self {
            Sink::Sse(framer) => framer.finish().map_or(Ok(()), |e| send(tx, Item::Event(e))),
            Sink::Raw => Ok(()),
        }
    }
}
