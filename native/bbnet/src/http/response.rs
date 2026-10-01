//! 响应头解析与响应体长度判定.

use crate::error::{Error, Result};
use crate::text::{Scan, find_blank_line};

/// 响应头最大长度, 超过视为协议错误.
pub const MAX_HEAD_LEN: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Head {
    pub status: u16,
    pub headers: Vec<(String, String)>,
}

/// 响应体的长度判定方式 (RFC 9112 6.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Framing {
    /// 没有响应体.
    Empty,
    Chunked,
    Length(u64),
    /// 读到连接关闭为止.
    UntilEof,
}

impl Head {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// 原始响应头, 每行 `"Name: value\n"`, 交给调用方.
    pub fn raw_headers(&self) -> String {
        self.headers
            .iter()
            .map(|(n, v)| format!("{n}: {v}\n"))
            .collect()
    }

    pub fn is_event_stream(&self) -> bool {
        self.header("content-type")
            .is_some_and(|v| v.to_ascii_lowercase().contains("text/event-stream"))
    }

    /// 1xx (101 除外) 是中间响应, 真正的响应还在后面.
    pub fn is_interim(&self) -> bool {
        (100..200).contains(&self.status) && self.status != 101
    }

    pub fn framing(&self, head_request: bool) -> Result<Framing> {
        if head_request || (100..200).contains(&self.status) || matches!(self.status, 204 | 304) {
            return Ok(Framing::Empty);
        }
        if let Some(te) = self.header("transfer-encoding") {
            // 最后一个编码是 chunked 才按 chunked 读, 否则只能读到 EOF. 同时出现时忽略 Content-Length.
            let last = te.rsplit(',').next().unwrap_or_default().trim();
            return Ok(if last.eq_ignore_ascii_case("chunked") {
                Framing::Chunked
            } else {
                Framing::UntilEof
            });
        }
        let mut length = None;
        for (name, value) in &self.headers {
            if !name.eq_ignore_ascii_case("content-length") {
                continue;
            }
            for part in value.split(',') {
                let n: u64 = part
                    .trim()
                    .parse()
                    .map_err(|_| Error::Http(format!("bad content-length: {value:?}")))?;
                if length.is_some_and(|l| l != n) {
                    return Err(Error::Http("conflicting content-length".into()));
                }
                length = Some(n);
            }
        }
        Ok(length.map_or(Framing::UntilEof, Framing::Length))
    }
}

/// 在缓冲区里查找完整的响应头. 找到则返回解析结果和响应头占用的字节数.
pub fn parse_head(buf: &[u8]) -> Result<Option<(Head, usize)>> {
    // 允许响应头前有多余的空行 (RFC 9112 2.2).
    let skip = buf
        .iter()
        .take_while(|&&b| b == b'\r' || b == b'\n')
        .count();
    let (start, end) = match find_blank_line(buf, skip) {
        Scan::Found { start, end } => (start, end),
        Scan::Pending { .. } => {
            if buf.len() > MAX_HEAD_LEN {
                return Err(Error::Http("response head too large".into()));
            }
            return Ok(None);
        }
    };
    let text = String::from_utf8_lossy(&buf[skip..start]);
    let mut lines = text.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l));
    let status_line = lines.next().unwrap_or_default();
    let status = parse_status_line(status_line)?;
    let mut headers: Vec<(String, String)> = Vec::new();
    for line in lines {
        if line.starts_with([' ', '\t']) {
            // 过时的折行: 并入上一个头的值.
            if let Some((_, value)) = headers.last_mut() {
                value.push(' ');
                value.push_str(line.trim());
            }
            continue;
        }
        // 客户端对畸形行宽容处理: 跳过而不是整个失败.
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim();
            if !name.is_empty() {
                headers.push((name.to_string(), value.trim().to_string()));
            }
        }
    }
    Ok(Some((Head { status, headers }, end)))
}

fn parse_status_line(line: &str) -> Result<u16> {
    let bad = || Error::Http(format!("bad status line: {line:?}"));
    let rest = line.strip_prefix("HTTP/").ok_or_else(bad)?;
    let code = rest.split(' ').nth(1).ok_or_else(bad)?;
    if code.len() != 3 {
        return Err(bad());
    }
    code.parse().map_err(|_| bad())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_head_and_framing() {
        let raw = b"\r\nHTTP/1.1 200 OK\r\nContent-Type: Text/Event-Stream; charset=utf-8\r\nX-Long: a\r\n  b\r\nbroken line\r\nContent-Length: 5\r\nTransfer-Encoding: gzip, chunked\r\n\r\nBODY";
        let (head, used) = parse_head(raw).unwrap().unwrap();
        assert_eq!(&raw[used..], b"BODY");
        assert_eq!(head.status, 200);
        assert!(head.is_event_stream());
        assert_eq!(head.header("x-long"), Some("a b"));
        assert_eq!(
            head.raw_headers(),
            "Content-Type: Text/Event-Stream; charset=utf-8\nX-Long: a b\nContent-Length: 5\nTransfer-Encoding: gzip, chunked\n"
        );
        // Transfer-Encoding 优先于 Content-Length.
        assert_eq!(head.framing(false).unwrap(), Framing::Chunked);
        assert_eq!(head.framing(true).unwrap(), Framing::Empty);

        // 响应头不完整时等待更多数据, 且头里只有 \n 也能识别.
        assert!(
            parse_head(b"HTTP/1.1 404 Not Found\nContent-Length: 3\n")
                .unwrap()
                .is_none()
        );
        let (head, _) = parse_head(b"HTTP/1.1 404 Not Found\nContent-Length: 3, 3\n\n")
            .unwrap()
            .unwrap();
        assert_eq!(head.status, 404);
        assert_eq!(head.framing(false).unwrap(), Framing::Length(3));

        let (head, _) = parse_head(b"HTTP/1.0 200 OK\r\n\r\n").unwrap().unwrap();
        assert_eq!(head.framing(false).unwrap(), Framing::UntilEof);
        let (head, _) = parse_head(b"HTTP/1.1 100 Continue\r\n\r\n")
            .unwrap()
            .unwrap();
        assert!(head.is_interim());

        assert!(parse_head(b"HTTP/1.1 2000 OK\r\n\r\n").is_err());
        assert!(parse_head(b"SSH-2.0-OpenSSH\r\n\r\n").is_err());
        let (head, _) =
            parse_head(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n")
                .unwrap()
                .unwrap();
        assert!(head.framing(false).is_err());
    }
}
