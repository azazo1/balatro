//! 手写的 HTTP/1.1 客户端协议部分, 不涉及 socket.

pub mod body;
pub mod request;
pub mod response;
pub mod url;

/// token 字符 (RFC 9110), 用于校验方法名与头名.
pub(crate) fn is_token(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
}
