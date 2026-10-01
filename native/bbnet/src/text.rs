//! 响应头与 SSE 共用的空行查找.
//!
//! 空行即连续两个行结束符, 认 `\n\n`, `\r\n\r\n` 以及混用的 `\r\n\n`, `\n\r\n`,
//! 从左向右扫描, 先出现的那个优先.

/// 一次扫描的结果.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Scan {
    /// 找到空行: `start` 是第一个 `\n` 的位置, `end` 是空行之后第一个字节的位置.
    /// `start` 之前可能还有一个属于同一行结束符的 `\r`, 由调用方裁掉.
    Found { start: usize, end: usize },
    /// 暂时没有空行. `resume` 之前的字节已确定不构成空行, 数据变多后从这里继续扫描.
    Pending { resume: usize },
}

/// 从 `from` 开始查找空行.
pub(crate) fn find_blank_line(buf: &[u8], from: usize) -> Scan {
    let mut i = from;
    while i < buf.len() {
        if buf[i] == b'\n' {
            match buf.get(i + 1) {
                Some(b'\n') => {
                    return Scan::Found {
                        start: i,
                        end: i + 2,
                    };
                }
                Some(b'\r') => match buf.get(i + 2) {
                    Some(b'\n') => {
                        return Scan::Found {
                            start: i,
                            end: i + 3,
                        };
                    }
                    Some(_) => {}
                    None => return Scan::Pending { resume: i },
                },
                Some(_) => {}
                None => return Scan::Pending { resume: i },
            }
        }
        i += 1;
    }
    Scan::Pending { resume: buf.len() }
}

/// 去掉首尾的 `\r` 与 `\n`.
pub(crate) fn trim_line_ends(mut s: &[u8]) -> &[u8] {
    while let [b'\r' | b'\n', rest @ ..] = s {
        s = rest;
    }
    while let [rest @ .., b'\r' | b'\n'] = s {
        s = rest;
    }
    s
}
