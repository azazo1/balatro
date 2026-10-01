//! SSE 事件分帧.
//!
//! 只负责按空行切出完整事件的原始文本, 不解析 `data:` 等字段, 字段与 JSON 交给 Lua.
//! 输入可以在任意字节处被切开 (TCP 分段, chunked 分块), 分帧结果与切法无关.

use crate::text::{Scan, find_blank_line, trim_line_ends};

/// 增量 SSE 分帧器.
#[derive(Debug, Default)]
pub struct SseFramer {
    buf: Vec<u8>,
    /// `buf` 中此位置之前已确定不含空行.
    scanned: usize,
}

impl SseFramer {
    pub fn new() -> Self {
        Self::default()
    }

    /// 追加一段数据, 把新凑齐的事件依次放进 `out`.
    /// 事件不含末尾空行; 多余的空行不产生空事件.
    pub fn push(&mut self, data: &[u8], out: &mut Vec<Vec<u8>>) {
        self.buf.extend_from_slice(data);
        let mut start = 0;
        let mut from = self.scanned;
        loop {
            match find_blank_line(&self.buf, from) {
                Scan::Found { start: sep, end } => {
                    let event = trim_line_ends(&self.buf[start..sep]);
                    if !event.is_empty() {
                        out.push(event.to_vec());
                    }
                    start = end;
                    from = end;
                }
                Scan::Pending { resume } => {
                    self.buf.drain(..start);
                    self.scanned = resume - start;
                    return;
                }
            }
        }
    }

    /// 流结束: 剩余的非空残片作为最后一条事件返回.
    pub fn finish(&mut self) -> Option<Vec<u8>> {
        let rest = trim_line_ends(&self.buf).to_vec();
        self.buf.clear();
        self.scanned = 0;
        (!rest.is_empty()).then_some(rest)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(chunks: &[&[u8]]) -> Vec<Vec<u8>> {
        let mut framer = SseFramer::new();
        let mut out = Vec::new();
        for chunk in chunks {
            framer.push(chunk, &mut out);
        }
        out.extend(framer.finish());
        out
    }

    /// 在每个位置切成两段, 以及逐字节输入, 结果都应与整段输入一致.
    #[test]
    fn framing_is_independent_of_split_points() {
        let input: &[u8] = b"\n\r\nevent: a\ndata: 1\n\ndata: 2\r\n\r\n\r\n\r\ndata: 3\r\n\ndata: {\"x\":\"\\n\"}\n\r\n: ping\n\ndata: tail\r\n";
        let expected: Vec<Vec<u8>> = vec![
            b"event: a\ndata: 1".to_vec(),
            b"data: 2".to_vec(),
            b"data: 3".to_vec(),
            b"data: {\"x\":\"\\n\"}".to_vec(),
            b": ping".to_vec(),
            b"data: tail".to_vec(),
        ];
        assert_eq!(frame(&[input]), expected);
        for cut in 0..=input.len() {
            let (a, b) = input.split_at(cut);
            assert_eq!(frame(&[a, b]), expected, "切分位置 {cut}");
        }
        let bytes: Vec<&[u8]> = input.chunks(1).collect();
        assert_eq!(frame(&bytes), expected);
    }
}
