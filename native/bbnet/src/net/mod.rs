//! 建立连接: DNS 解析, TCP 连接, 可选的 TLS 握手.

mod cancel;
mod tls;

use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};

pub use cancel::CancelToken;

use crate::error::{Error, Result, is_timeout};
use crate::http::request::Timeouts;
use crate::http::url::Url;

/// 明文或 TLS 连接.
pub enum Conn {
    Plain(TcpStream),
    Tls(Box<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>),
}

impl Read for Conn {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Conn::Plain(s) => s.read(buf),
            // 不少服务端直接断开而不发 close_notify, rustls 此时报 UnexpectedEof, 按普通 EOF 处理.
            // 截断仍能被 chunked 与 Content-Length 的完整性检查发现.
            Conn::Tls(s) => match s.read(buf) {
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(0),
                r => r,
            },
        }
    }
}

impl Write for Conn {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Conn::Plain(s) => s.write(buf),
            Conn::Tls(s) => s.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Conn::Plain(s) => s.flush(),
            Conn::Tls(s) => s.flush(),
        }
    }
}

/// 连接到 `url`, 并把 socket 登记到 `cancel`, 之后的读写都可被取消打断.
pub fn connect(url: &Url, timeouts: &Timeouts, cancel: &CancelToken) -> Result<Conn> {
    let addrs: Vec<_> = (url.host.as_str(), url.port)
        .to_socket_addrs()
        .map_err(|e| Error::Resolve(format!("{}: {e}", url.host)))?
        .collect();
    if addrs.is_empty() {
        return Err(Error::Resolve(format!("{}: no address", url.host)));
    }
    let mut last_err = None;
    let mut stream = None;
    for addr in &addrs {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        match TcpStream::connect_timeout(addr, timeouts.connect) {
            Ok(s) => {
                stream = Some(s);
                break;
            }
            Err(e) => last_err = Some(e),
        }
    }
    let stream = match (stream, last_err) {
        (Some(s), _) => s,
        (None, Some(e)) if is_timeout(&e) => return Err(Error::Timeout),
        (None, e) => {
            let detail = e.map(|e| e.to_string()).unwrap_or_default();
            return Err(Error::Connect(format!(
                "{}:{}: {detail}",
                url.host, url.port
            )));
        }
    };
    let setup = |e: io::Error| Error::Connect(format!("socket setup: {e}"));
    stream
        .set_read_timeout(Some(timeouts.idle))
        .map_err(setup)?;
    stream
        .set_write_timeout(Some(timeouts.idle))
        .map_err(setup)?;
    stream.set_nodelay(true).map_err(setup)?;
    cancel.attach(stream.try_clone().map_err(setup)?);

    if url.tls {
        tls::handshake(&url.host, stream).map(|s| Conn::Tls(Box::new(s)))
    } else {
        Ok(Conn::Plain(stream))
    }
}
