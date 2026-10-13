//! 极简 JSON 解析.
//!
//! 只为读 `docs/game/data/catalog.json` 这类随仓库走的静态数据, 不追求通用: 没有流式, 没有行号,
//! 不做重复键检测. 对象保留键顺序 (记录数不多, 按 key 线性找一次就够), 这样也不用引入哈希表.

use std::fmt;

/// 一个 JSON 值.
#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Json>),
    /// 保留键的书写顺序.
    Object(Vec<(String, Json)>),
}

#[derive(Clone, Debug)]
pub struct ParseError {
    pub offset: usize,
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "第 {} 字节: {}", self.offset, self.message)
    }
}

impl std::error::Error for ParseError {}

impl Json {
    /// 解析一整段文本.
    pub fn parse(text: &str) -> Result<Json, ParseError> {
        let mut parser = Parser {
            bytes: text.as_bytes(),
            pos: 0,
        };
        parser.skip_ws();
        let value = parser.value()?;
        parser.skip_ws();
        if parser.pos != parser.bytes.len() {
            return Err(parser.error("结尾有多余内容"));
        }
        Ok(value)
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Number(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(items) => Some(items),
            _ => None,
        }
    }

    /// 取字符串数组, 元素不是字符串或字段不存在时给空.
    pub fn str_list(&self) -> Vec<&str> {
        self.as_array()
            .map(|items| items.iter().filter_map(Json::as_str).collect())
            .unwrap_or_default()
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn error(&self, message: &str) -> ParseError {
        ParseError {
            offset: self.pos,
            message: message.to_owned(),
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while let Some(b) = self.peek() {
            if b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn expect(&mut self, byte: u8) -> Result<(), ParseError> {
        if self.peek() == Some(byte) {
            self.pos += 1;
            Ok(())
        } else {
            Err(self.error(&format!("期望 {}", byte as char)))
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> Result<Json, ParseError> {
        if self.bytes[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(value)
        } else {
            Err(self.error("无法识别的字面量"))
        }
    }

    fn value(&mut self) -> Result<Json, ParseError> {
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            Some(_) => self.number(),
            None => Err(self.error("内容意外结束")),
        }
    }

    fn object(&mut self) -> Result<Json, ParseError> {
        self.expect(b'{')?;
        let mut fields = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Json::Object(fields));
        }
        loop {
            self.skip_ws();
            let key = self.string()?;
            self.skip_ws();
            self.expect(b':')?;
            self.skip_ws();
            let value = self.value()?;
            fields.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Json::Object(fields));
                }
                _ => return Err(self.error("对象里期望 , 或 }")),
            }
        }
    }

    fn array(&mut self) -> Result<Json, ParseError> {
        self.expect(b'[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Json::Array(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Json::Array(items));
                }
                _ => return Err(self.error("数组里期望 , 或 ]")),
            }
        }
    }

    fn string(&mut self) -> Result<String, ParseError> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            let byte = self.peek().ok_or_else(|| self.error("字符串没有闭合"))?;
            match byte {
                b'"' => {
                    self.pos += 1;
                    return Ok(out);
                }
                b'\\' => {
                    self.pos += 1;
                    let escape = self.peek().ok_or_else(|| self.error("转义没有写完"))?;
                    self.pos += 1;
                    match escape {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => out.push(self.unicode_escape()?),
                        _ => return Err(self.error("不认识的转义")),
                    }
                }
                _ => {
                    // 非 ASCII 在 UTF-8 里是多字节, 但整段拷贝不切坏字符, 所以按字节收进 String.
                    let start = self.pos;
                    self.pos += 1;
                    while let Some(next) = self.peek() {
                        if next & 0xC0 == 0x80 {
                            self.pos += 1;
                        } else {
                            break;
                        }
                    }
                    match std::str::from_utf8(&self.bytes[start..self.pos]) {
                        Ok(text) => out.push_str(text),
                        Err(_) => return Err(self.error("字符串里有非法 UTF-8")),
                    }
                }
            }
        }
    }

    /// `\uXXXX`, 代理对会拼成一个码点.
    fn unicode_escape(&mut self) -> Result<char, ParseError> {
        let first = self.hex4()?;
        let code = if (0xD800..0xDC00).contains(&first) {
            // 高代理: 后面必须跟一个低代理.
            if self.peek() == Some(b'\\') {
                self.pos += 1;
                self.expect(b'u')?;
                let second = self.hex4()?;
                if (0xDC00..0xE000).contains(&second) {
                    0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                } else {
                    return Err(self.error("代理对不完整"));
                }
            } else {
                return Err(self.error("代理对不完整"));
            }
        } else {
            first
        };
        char::from_u32(code).ok_or_else(|| self.error("码点不合法"))
    }

    fn hex4(&mut self) -> Result<u32, ParseError> {
        if self.pos + 4 > self.bytes.len() {
            return Err(self.error("\\u 后面不足四位"));
        }
        let text = std::str::from_utf8(&self.bytes[self.pos..self.pos + 4])
            .map_err(|_| self.error("\\u 后面不是十六进制"))?;
        let value =
            u32::from_str_radix(text, 16).map_err(|_| self.error("\\u 后面不是十六进制"))?;
        self.pos += 4;
        Ok(value)
    }

    fn number(&mut self) -> Result<Json, ParseError> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while let Some(byte) = self.peek() {
            let is_part = byte.is_ascii_digit()
                || byte == b'.'
                || byte == b'e'
                || byte == b'E'
                || byte == b'+'
                || byte == b'-';
            if is_part {
                self.pos += 1;
            } else {
                break;
            }
        }
        let text = std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| self.error("数字不是 ASCII"))?;
        text.parse::<f64>()
            .map(Json::Number)
            .map_err(|_| self.error("数字解析失败"))
    }
}

#[cfg(test)]
mod tests {
    use super::Json;

    #[test]
    fn parses_the_shapes_used_by_catalog_json() {
        let text = r#"{"a": 1, "b": [true, null, "x"], "c": {"d": -2.5e2}, "e": []}"#;
        let json = Json::parse(text).expect("应当解析成功");
        assert_eq!(json.get("a").and_then(Json::as_f64), Some(1.0));
        assert_eq!(json.get("b").and_then(Json::as_array).map(<[_]>::len), Some(3));
        assert_eq!(
            json.get("c").and_then(|c| c.get("d")).and_then(Json::as_f64),
            Some(-250.0)
        );
        assert_eq!(json.get("e").and_then(Json::as_array).map(<[_]>::len), Some(0));
    }

    #[test]
    fn decodes_escapes_and_keeps_utf8() {
        let json = Json::parse(r#"{"k": "红桃K\n\"引号\" \u0041 \uD83D\uDE00"}"#).expect("解析");
        assert_eq!(
            json.get("k").and_then(Json::as_str),
            Some("红桃K\n\"引号\" A 😀")
        );
    }

    #[test]
    fn reports_trailing_content() {
        assert!(Json::parse("{} junk").is_err());
        assert!(Json::parse("{\"a\":}").is_err());
    }
}
