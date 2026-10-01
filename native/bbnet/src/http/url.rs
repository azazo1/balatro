//! 只解析请求需要的部分: 协议, 主机, 端口, 路径 (含查询串).

use crate::error::{Error, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Url {
    pub tls: bool,
    /// 主机名或 IP, IPv6 不带方括号.
    pub host: String,
    pub port: u16,
    /// 请求行里的目标, 以 `/` 开头, 不含片段.
    pub path: String,
}

impl Url {
    pub fn parse(input: &str) -> Result<Self> {
        let invalid = |why: &str| Error::Invalid(format!("url {why}: {input}"));
        let (tls, rest) = if let Some(rest) = strip_prefix_ignore_case(input, "https://") {
            (true, rest)
        } else if let Some(rest) = strip_prefix_ignore_case(input, "http://") {
            (false, rest)
        } else {
            return Err(invalid("scheme must be http or https"));
        };
        let rest = rest.split('#').next().unwrap_or_default();
        let split = rest.find(['/', '?']).unwrap_or(rest.len());
        let (authority, path) = rest.split_at(split);
        if authority.contains('@') {
            return Err(invalid("userinfo unsupported"));
        }
        let (host, port) = if let Some(v6) = authority.strip_prefix('[') {
            let (host, after) = v6.split_once(']').ok_or_else(|| invalid("bad ipv6 host"))?;
            (host, after.strip_prefix(':'))
        } else {
            match authority.rsplit_once(':') {
                Some((host, port)) => (host, Some(port)),
                None => (authority, None),
            }
        };
        if host.is_empty() {
            return Err(invalid("empty host"));
        }
        let port = match port {
            None | Some("") => {
                if tls {
                    443
                } else {
                    80
                }
            }
            Some(p) => p.parse().map_err(|_| invalid("bad port"))?,
        };
        let path = match path {
            "" => "/".to_string(),
            p if p.starts_with('?') => format!("/{p}"),
            p => p.to_string(),
        };
        if path.bytes().any(|b| b <= b' ' || b == 0x7f) {
            return Err(invalid("path contains space or control char"));
        }
        Ok(Url {
            tls,
            host: host.to_string(),
            port,
            path,
        })
    }

    /// Host 头的值: IPv6 加方括号, 默认端口省略.
    pub fn host_header(&self) -> String {
        let host = if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        let default_port = if self.tls { 443 } else { 80 };
        if self.port == default_port {
            host
        } else {
            format!("{host}:{}", self.port)
        }
    }
}

fn strip_prefix_ignore_case<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    let head = s.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix)
        .then(|| &s[prefix.len()..])
}
