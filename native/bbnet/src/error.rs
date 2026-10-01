//! 请求失败的原因, 其文本即 poll 返回 ERROR 时交给调用方的错误描述.

use std::fmt;
use std::io;

#[derive(Debug)]
pub enum Error {
    /// 请求参数不合法 (URL, 方法, 请求头).
    Invalid(String),
    /// 域名解析失败.
    Resolve(String),
    /// TCP 连接失败.
    Connect(String),
    /// TLS 握手或记录层错误.
    Tls(String),
    /// 连接或读写超时.
    Timeout,
    /// 其他读写错误, 附带所处阶段.
    Io {
        stage: &'static str,
        message: String,
    },
    /// 响应不符合 HTTP/1.1.
    Http(String),
    /// 已被取消或句柄已释放, 不再需要结果.
    Cancelled,
}

impl Error {
    /// 把读写阶段的 io 错误归类: 超时, 被 rustls 包装的 TLS 错误, 其他.
    pub fn from_io(stage: &'static str, err: io::Error) -> Self {
        if is_timeout(&err) {
            return Error::Timeout;
        }
        if let Some(tls) = err
            .get_ref()
            .and_then(|e| e.downcast_ref::<rustls::Error>())
        {
            return Error::Tls(tls.to_string());
        }
        Error::Io {
            stage,
            message: err.to_string(),
        }
    }
}

/// Unix 上读超时报 WouldBlock, Windows 上报 TimedOut.
pub fn is_timeout(err: &io::Error) -> bool {
    matches!(
        err.kind(),
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
    )
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Invalid(m) => write!(f, "invalid: {m}"),
            Error::Resolve(m) => write!(f, "resolve: {m}"),
            Error::Connect(m) => write!(f, "connect: {m}"),
            Error::Tls(m) => write!(f, "tls: {m}"),
            Error::Timeout => f.write_str("timeout"),
            Error::Io { stage, message } => write!(f, "{stage}: {message}"),
            Error::Http(m) => write!(f, "http: {m}"),
            Error::Cancelled => f.write_str("cancelled"),
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
