//! 响应体的增量解码: 按 Content-Length 截断, chunked 解码, 或读到 EOF.

use super::response::Framing;
use crate::error::{Error, Result};

/// chunk 头行与 trailer 行的最大长度.
const MAX_LINE_LEN: usize = 8 * 1024;

#[derive(Debug)]
pub struct BodyDecoder {
    state: State,
}

#[derive(Debug)]
enum State {
    /// 还剩多少字节.
    Length(u64),
    UntilEof,
    Chunked(Chunked),
    Done,
}

#[derive(Debug)]
enum Chunked {
    /// 正在读 chunk 头 `<十六进制长度>[;扩展]\r\n`, 缓存未凑齐的行.
    Size(Vec<u8>),
    /// chunk 数据还剩多少字节.
    Data(u64),
    /// chunk 数据之后的 CRLF.
    DataEnd(Vec<u8>),
    /// 最后一个 chunk 之后的 trailer 行, 以空行结束.
    Trailer(Vec<u8>),
}

impl BodyDecoder {
    pub fn new(framing: Framing) -> Self {
        let state = match framing {
            Framing::Empty | Framing::Length(0) => State::Done,
            Framing::Length(n) => State::Length(n),
            Framing::UntilEof => State::UntilEof,
            Framing::Chunked => State::Chunked(Chunked::Size(Vec::new())),
        };
        BodyDecoder { state }
    }

    pub fn is_done(&self) -> bool {
        matches!(self.state, State::Done)
    }

    /// 输入一段原始数据, 解码出的响应体追加到 `out`. 响应体结束后多出的字节被丢弃.
    pub fn feed(&mut self, mut input: &[u8], out: &mut Vec<u8>) -> Result<()> {
        while !input.is_empty() {
            match &mut self.state {
                State::Done => return Ok(()),
                State::UntilEof => {
                    out.extend_from_slice(input);
                    return Ok(());
                }
                State::Length(left) => {
                    let n = take_len(*left, input.len());
                    out.extend_from_slice(&input[..n]);
                    input = &input[n..];
                    *left -= n as u64;
                    if *left == 0 {
                        self.state = State::Done;
                    }
                }
                State::Chunked(chunked) => match feed_chunked(chunked, input, out)? {
                    Some(rest) => input = rest,
                    None => self.state = State::Done,
                },
            }
        }
        Ok(())
    }

    /// 连接已关闭. 只有读到 EOF 为止的响应体可以在这里正常结束.
    pub fn finish(&mut self) -> Result<()> {
        match self.state {
            State::Done => Ok(()),
            State::UntilEof => {
                self.state = State::Done;
                Ok(())
            }
            _ => Err(Error::Http("connection closed before body complete".into())),
        }
    }
}

/// 处理 chunked 的一步, 返回未消费的输入; trailer 结束 (响应体完整) 时返回 `None`.
fn feed_chunked<'a>(
    state: &mut Chunked,
    input: &'a [u8],
    out: &mut Vec<u8>,
) -> Result<Option<&'a [u8]>> {
    match state {
        Chunked::Size(line) => {
            let Some((rest, complete)) = take_line(line, input)? else {
                return Ok(Some(&[]));
            };
            let size = parse_chunk_size(&complete)?;
            *state = if size == 0 {
                Chunked::Trailer(Vec::new())
            } else {
                Chunked::Data(size)
            };
            Ok(Some(rest))
        }
        Chunked::Data(left) => {
            let n = take_len(*left, input.len());
            out.extend_from_slice(&input[..n]);
            *left -= n as u64;
            if *left == 0 {
                *state = Chunked::DataEnd(Vec::new());
            }
            Ok(Some(&input[n..]))
        }
        Chunked::DataEnd(line) => {
            let Some((rest, complete)) = take_line(line, input)? else {
                return Ok(Some(&[]));
            };
            if !complete.is_empty() {
                return Err(Error::Http("missing CRLF after chunk data".into()));
            }
            *state = Chunked::Size(Vec::new());
            Ok(Some(rest))
        }
        Chunked::Trailer(line) => {
            let Some((rest, complete)) = take_line(line, input)? else {
                return Ok(Some(&[]));
            };
            Ok((!complete.is_empty()).then_some(rest))
        }
    }
}

/// 把输入追加到行缓存直到遇到 `\n`. 凑齐一行时清空缓存并返回 (剩余输入, 去掉行结束符的行).
fn take_line<'a>(line: &mut Vec<u8>, input: &'a [u8]) -> Result<Option<(&'a [u8], Vec<u8>)>> {
    let Some(pos) = input.iter().position(|&b| b == b'\n') else {
        line.extend_from_slice(input);
        if line.len() > MAX_LINE_LEN {
            return Err(Error::Http("chunk line too long".into()));
        }
        return Ok(None);
    };
    line.extend_from_slice(&input[..pos]);
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    Ok(Some((&input[pos + 1..], std::mem::take(line))))
}

fn parse_chunk_size(line: &[u8]) -> Result<u64> {
    let text = String::from_utf8_lossy(line);
    let hex = text.split(';').next().unwrap_or_default().trim();
    u64::from_str_radix(hex, 16).map_err(|_| Error::Http(format!("bad chunk size: {text:?}")))
}

fn take_len(left: u64, available: usize) -> usize {
    usize::try_from(left).map_or(available, |l| l.min(available))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(parts: &[&[u8]]) -> Result<Vec<u8>> {
        let mut decoder = BodyDecoder::new(Framing::Chunked);
        let mut out = Vec::new();
        for part in parts {
            decoder.feed(part, &mut out)?;
        }
        if !decoder.is_done() {
            decoder.finish()?;
        }
        Ok(out)
    }

    /// 在任意位置切开 chunked 流, 解码结果都一致, 且忽略扩展, trailer 与结束后的多余字节.
    #[test]
    fn chunked_is_independent_of_split_points() {
        let input: &[u8] = b"5;ext=1\r\nhello\r\n1A\r\n, chunked world 0123456789\r\n3\n!\r\n\n0\r\nX-Trailer: t\r\n\r\nGARBAGE";
        let expected = b"hello, chunked world 0123456789!\r\n".to_vec();
        assert_eq!(decode(&[input]).unwrap(), expected);
        for cut in 0..=input.len() {
            let (a, b) = input.split_at(cut);
            assert_eq!(decode(&[a, b]).unwrap(), expected, "切分位置 {cut}");
        }
        let bytes: Vec<&[u8]> = input.chunks(1).collect();
        assert_eq!(decode(&bytes).unwrap(), expected);
    }

    #[test]
    fn chunked_errors() {
        // 连接在最后一个 chunk 之前关闭.
        assert!(decode(&[b"5\r\nhello\r\n"]).is_err());
        assert!(decode(&[b"zz\r\n"]).is_err());
        assert!(decode(&[b"2\r\nabc\r\n"]).is_err());
    }
}
