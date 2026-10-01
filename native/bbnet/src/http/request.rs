//! 请求的参数校验与编码.

use std::time::Duration;

use super::is_token;
use super::url::Url;
use crate::error::{Error, Result};

/// 连接超时的默认值.
pub const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// 两次读之间空闲超时的默认值. 模型首个 token 可能要等很久, 所以放宽.
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timeouts {
    pub connect: Duration,
    pub idle: Duration,
}

impl Timeouts {
    /// `0` 取默认值, 否则连接与空闲超时都用这个值.
    pub fn from_millis(ms: u32) -> Self {
        if ms == 0 {
            Timeouts {
                connect: DEFAULT_CONNECT_TIMEOUT,
                idle: DEFAULT_IDLE_TIMEOUT,
            }
        } else {
            let d = Duration::from_millis(u64::from(ms));
            Timeouts {
                connect: d,
                idle: d,
            }
        }
    }
}

#[derive(Debug)]
pub struct Request {
    pub method: String,
    pub url: Url,
    /// 调用方传入的请求头, 已校验.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub timeouts: Timeouts,
}

impl Request {
    pub fn new(
        method: &str,
        url: &str,
        headers: &str,
        body: Vec<u8>,
        timeouts: Timeouts,
    ) -> Result<Self> {
        if !is_token(method) {
            return Err(Error::Invalid(format!("method: {method:?}")));
        }
        Ok(Request {
            method: method.to_string(),
            url: Url::parse(url)?,
            headers: parse_headers(headers)?,
            body,
            timeouts,
        })
    }

    pub fn is_head(&self) -> bool {
        self.method.eq_ignore_ascii_case("HEAD")
    }

    /// 编码为请求报文.
    ///
    /// Host, User-Agent, Connection 缺省时由库补上, 调用方传了同名头则以调用方为准.
    /// Content-Length 总是按实际 body 计算, 调用方传的会被忽略, 避免长度与内容不符.
    /// 不支持分块发送, 调用方传的 Transfer-Encoding 同样忽略.
    pub fn encode(&self) -> Vec<u8> {
        let has = |name: &str| {
            self.headers
                .iter()
                .any(|(n, _)| n.eq_ignore_ascii_case(name))
        };
        let mut head = format!("{} {} HTTP/1.1\r\n", self.method, self.url.path);
        if !has("host") {
            head += &format!("Host: {}\r\n", self.url.host_header());
        }
        if !has("user-agent") {
            head += &format!("User-Agent: bbnet/{}\r\n", crate::VERSION);
        }
        if !has("connection") {
            head += "Connection: close\r\n";
        }
        for (name, value) in &self.headers {
            if name.eq_ignore_ascii_case("content-length")
                || name.eq_ignore_ascii_case("transfer-encoding")
            {
                continue;
            }
            head += &format!("{name}: {value}\r\n");
        }
        let needs_length = !self.body.is_empty()
            || ["POST", "PUT", "PATCH"]
                .iter()
                .any(|m| self.method.eq_ignore_ascii_case(m));
        if needs_length {
            head += &format!("Content-Length: {}\r\n", self.body.len());
        }
        head += "\r\n";
        let mut out = head.into_bytes();
        out.extend_from_slice(&self.body);
        out
    }
}

/// 解析 `"Name: value\n"` 拼接的请求头, 也接受 `\r\n`, 忽略空行.
/// 头名须为 token, 值里不能有 CR, LF, NUL, 防止拼出额外的头.
pub fn parse_headers(raw: &str) -> Result<Vec<(String, String)>> {
    let mut out = Vec::new();
    for line in raw.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.trim().is_empty() {
            continue;
        }
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| Error::Invalid(format!("header without colon: {line:?}")))?;
        let name = name.trim();
        let value = value.trim();
        if !is_token(name) || value.bytes().any(|b| matches!(b, b'\r' | b'\n' | 0)) {
            return Err(Error::Invalid(format!("header: {line:?}")));
        }
        out.push((name.to_string(), value.to_string()));
    }
    Ok(out)
}
