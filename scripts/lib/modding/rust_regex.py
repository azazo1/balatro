"""把 lovely 使用的 Rust regex 语法翻译成 Python re, 并复刻它的匹配迭代与替换插值.

lovely 用 regex-automata 编译补丁里的正则, 固定开启 multi_line 与 crlf, 补丁声明
verbose 时再开启 ignore_whitespace. Python re 与之大体相同, 但有几处差异会悄悄改变结果:

- 命名分组 `(?<name>...)` 在 Python 里写作 `(?P<name>...)`.
- crlf 模式下 `^` `$` 把 `\\r\\n` 视作一个换行, `.` 也不匹配 `\\r`; Python 只认 `\\n`.
- `\\z` 表示文本末尾, 对应 Python 的 `\\Z`; 非 multi_line 时 `$` 在 Python 里还会匹配末尾换行之前.
- 迭代时 Rust 不允许空匹配紧贴上一个匹配的结尾, Python 允许.
- 替换串里 `$name` `${name}` `$1` 的解析规则.

这里逐个 token 翻译. 遇到 Python 无法等价表达的写法 (unicode 属性类, 字符类集合运算,
环视等) 直接报错, 不生成一个行为不同的正则.
"""
import re

# Rust 的 char::is_whitespace, 即 Unicode White_Space 属性. Python 的 str.isspace 范围更大.
WHITESPACE = ("\t\n\x0b\x0c\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006"
              "\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000")

_FLAG_CHARS = "imsxRUu"

# POSIX 字符类只能出现在方括号内, Rust 按 ASCII 含义解释.
_POSIX_CLASSES = {
    "alnum": "0-9A-Za-z",
    "alpha": "A-Za-z",
    "ascii": "\\x00-\\x7f",
    "blank": "\\t ",
    "cntrl": "\\x00-\\x1f\\x7f",
    "digit": "0-9",
    "graph": "!-~",
    "lower": "a-z",
    "print": " -~",
    "punct": "!-/:-@\\[-`{-~",
    "space": "\\t\\n\\x0b\\x0c\\r ",
    "upper": "A-Z",
    "word": "0-9A-Za-z_",
    "xdigit": "0-9A-Fa-f",
}

# \b{...} 的四种特殊词边界.
_SPECIAL_BOUNDARIES = {
    "start": r"\b(?=\w)",
    "end": r"\b(?<=\w)",
    "start-half": r"(?<!\w)",
    "end-half": r"(?!\w)",
}

_GROUP_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_REPEAT_BODY_RE = re.compile(r"([0-9]*)(,([0-9]*))?")
_USIZE_RE = re.compile(r"\+?[0-9]+")
_USIZE_MAX = 2 ** 64 - 1


class RegexTranslateError(ValueError):
    """Rust 正则无法等价翻译为 Python 正则."""


class _Translator:
    def __init__(self, pattern, verbose):
        self.p = pattern
        self.i = 0
        self.out = []
        # 每个未闭合的括号记录进入前的标志, 闭合时恢复.
        self.stack = []
        # lovely 固定开启 m 与 R (crlf), 其余为 Rust 默认值.
        self.flags = {"i": False, "m": True, "s": False, "x": bool(verbose),
                      "R": True, "U": False, "u": True}

    def fail(self, message):
        raise RegexTranslateError("%s (位置 %d): %r" % (message, self.i, self.p))

    def run(self):
        p = self.p
        while self.i < len(p):
            if self.skip_space():
                continue
            c = p[self.i]
            if c == "\\":
                self.out.append(self.escape(in_class=False))
            elif c == "[":
                self.out.append(self.char_class())
            elif c == "(":
                self.open_group()
            elif c == ")":
                self.close_group()
            elif c == ".":
                self.i += 1
                self.out.append(self.dot())
            elif c == "^":
                self.i += 1
                self.out.append(self.caret())
            elif c == "$":
                self.i += 1
                self.out.append(self.dollar())
            elif c in "*+?":
                self.i += 1
                self.out.append(self.quantifier_suffix(c))
            elif c == "{":
                self.out.append(self.counted_repetition())
            elif c == "|":
                self.i += 1
                self.out.append("|")
            else:
                self.i += 1
                self.out.append(self.literal(c))
        if self.stack:
            self.fail("括号未闭合")
        return "".join(self.out)

    # verbose 模式下跳过空白与 # 注释, 返回是否跳过了内容.
    def skip_space(self):
        if not self.flags["x"]:
            return False
        p = self.p
        start = self.i
        while self.i < len(p):
            c = p[self.i]
            if c in WHITESPACE:
                self.i += 1
            elif c == "#":
                end = p.find("\n", self.i)
                self.i = len(p) if end < 0 else end + 1
            else:
                break
        return self.i != start

    def literal(self, c):
        text = re.escape(c)
        if self.flags["i"] and c.lower() != c.upper():
            return "(?i:%s)" % text
        return text

    def dot(self):
        if self.flags["s"]:
            return "(?s:.)"
        return r"[^\r\n]" if self.flags["R"] else r"[^\n]"

    def caret(self):
        if not self.flags["m"]:
            return r"\A"
        if self.flags["R"]:
            # crlf: 行首是文本开头, \n 之后, 或者后面不跟 \n 的 \r 之后.
            return r"(?:\A|(?<=\n)|(?<=\r)(?!\n))"
        return r"(?:\A|(?<=\n))"

    def dollar(self):
        if not self.flags["m"]:
            return r"\Z"
        if self.flags["R"]:
            # crlf: 行尾是文本末尾, \r 之前, 或者前面不是 \r 的 \n 之前.
            return r"(?:\Z|(?=\r)|(?<!\r)(?=\n))"
        return r"(?=\n|\Z)"

    def lazy_suffix(self):
        """读取可选的非贪婪标记, 结合 U 标志返回应追加的后缀."""
        lazy = False
        if self.i < len(self.p) and self.p[self.i] == "?":
            lazy = True
            self.i += 1
        if self.i < len(self.p) and self.p[self.i] in "*+?{":
            # Python 3.11 起 *+ 是占有量词, ** 直接报错, 与 Rust 的嵌套重复不一致.
            self.fail("不支持叠加的重复运算符")
        return "?" if lazy != self.flags["U"] else ""

    def quantifier_suffix(self, c):
        return c + self.lazy_suffix()

    def counted_repetition(self):
        p = self.p
        end = p.find("}", self.i + 1)
        if end < 0:
            self.fail("计数重复缺少 }")
        body = p[self.i + 1:end]
        if self.flags["x"]:
            body = "".join(ch for ch in body if ch not in WHITESPACE)
        match = _REPEAT_BODY_RE.fullmatch(body)
        if not match or (not match.group(1) and not match.group(3)):
            self.fail("无法识别的计数重复 {%s}" % body)
        self.i = end + 1
        low = match.group(1) or "0"
        if match.group(2) is None:
            text = "{%s}" % low
        else:
            text = "{%s,%s}" % (low, match.group(3) or "")
        return text + self.lazy_suffix()

    def apply_flags(self, spec):
        flags = dict(self.flags)
        negate = False
        for ch in spec:
            if ch == "-":
                if negate:
                    self.fail("标志里出现多个 -")
                negate = True
                continue
            if ch not in _FLAG_CHARS:
                self.fail("不支持的标志 %s" % ch)
            flags[ch] = not negate
        if not flags["u"]:
            self.fail("不支持关闭 unicode 模式 (?-u)")
        return flags

    def open_group(self):
        p = self.p
        outer = dict(self.flags)
        self.i += 1
        if not p.startswith("?", self.i):
            self.stack.append(outer)
            self.out.append("(")
            return
        rest = p[self.i + 1:]
        if rest.startswith(("<=", "<!", "=", "!")):
            self.fail("Rust regex 不支持环视, lovely 会直接报错")
        if rest.startswith(("P<", "<")):
            start = self.i + (3 if rest.startswith("P<") else 2)
            end = p.find(">", start)
            if end < 0:
                self.fail("命名分组缺少 >")
            name = p[start:end]
            if not _GROUP_NAME_RE.fullmatch(name):
                self.fail("分组名 %r 无法在 Python 中使用" % name)
            self.i = end + 1
            self.stack.append(outer)
            self.out.append("(?P<%s>" % name)
            return
        end = self.i + 1
        while end < len(p) and (p[end] in _FLAG_CHARS or p[end] == "-"):
            end += 1
        if end >= len(p) or p[end] not in ":)":
            self.fail("无法识别的分组写法")
        spec = p[self.i + 1:end]
        if p[end] == ")":
            if not spec:
                self.fail("空的标志分组")
            # (?flags) 作用到所在分组结束, 闭合外层分组时会恢复.
            self.flags = self.apply_flags(spec)
            self.i = end + 1
            return
        self.stack.append(outer)
        self.flags = self.apply_flags(spec)
        self.out.append("(?:")
        self.i = end + 1

    def close_group(self):
        if not self.stack:
            self.fail("多余的右括号")
        self.i += 1
        self.flags = self.stack.pop()
        self.out.append(")")

    def char_class(self):
        p = self.p
        self.i += 1
        parts = ["["]
        if self.i < len(p) and p[self.i] == "^":
            parts.append("^")
            self.i += 1
        first = True
        while True:
            self.skip_space()
            if self.i >= len(p):
                self.fail("字符类未闭合")
            c = p[self.i]
            if c == "]":
                self.i += 1
                if first:
                    # 开头的 ] 是字面量, 两种引擎一致.
                    parts.append("\\]")
                    first = False
                    continue
                break
            first = False
            if c == "[":
                if p.startswith("[:", self.i):
                    end = p.find(":]", self.i + 2)
                    name = p[self.i + 2:end] if end >= 0 else ""
                    if name not in _POSIX_CLASSES:
                        self.fail("不支持的 POSIX 字符类 [:%s:]" % name)
                    parts.append(_POSIX_CLASSES[name])
                    self.i = end + 2
                    continue
                self.fail("不支持嵌套字符类")
            if p.startswith(("&&", "--", "~~"), self.i):
                self.fail("不支持字符类集合运算")
            if c == "\\":
                parts.append(self.escape(in_class=True))
                continue
            self.i += 1
            # | & ~ 在 Python 里连写会触发集合运算警告, 转义后含义不变.
            parts.append("\\" + c if c in "|&~" else c)
        parts.append("]")
        text = "".join(parts)
        return "(?i:%s)" % text if self.flags["i"] else text

    def hex_escape(self, digits):
        """解析 \\x \\u \\U 之后的十六进制, digits 为不带花括号时的固定位数."""
        p = self.p
        if self.i < len(p) and p[self.i] == "{":
            end = p.find("}", self.i)
            if end < 0:
                self.fail("十六进制转义缺少 }")
            text = p[self.i + 1:end]
            self.i = end + 1
        else:
            text = p[self.i:self.i + digits]
            self.i += digits
            if len(text) != digits:
                self.fail("十六进制转义位数不足")
        try:
            code = int(text, 16)
        except ValueError:
            self.fail("无效的十六进制转义 %r" % text)
        if code > 0x10FFFF or 0xD800 <= code <= 0xDFFF:
            self.fail("无效的码位 %X" % code)
        return code

    def escape(self, in_class):
        p = self.p
        if self.i + 1 >= len(p):
            self.fail("结尾的反斜杠")
        c = p[self.i + 1]
        self.i += 2
        if c in "dDsSwW":
            return "\\" + c
        if c in "nrtfva":
            return "\\" + c
        if c in "xuU":
            code = self.hex_escape({"x": 2, "u": 4, "U": 8}[c])
            text = "\\U%08x" % code
            ch = chr(code)
            if not in_class and self.flags["i"] and ch.lower() != ch.upper():
                return "(?i:%s)" % text
            return text
        if c in "pP":
            self.fail("不支持 unicode 属性类 \\%s" % c)
        if c.isdigit():
            self.fail("不支持反向引用或八进制转义 \\%s" % c)
        if not in_class:
            if c == "A":
                return r"\A"
            if c == "z":
                return r"\Z"
            if c == "B":
                return r"\B"
            if c == "b":
                if p.startswith("{", self.i):
                    end = p.find("}", self.i)
                    name = p[self.i + 1:end] if end >= 0 else None
                    if name in _SPECIAL_BOUNDARIES:
                        self.i = end + 1
                        return _SPECIAL_BOUNDARIES[name]
                return r"\b"
            if c == "<":
                return _SPECIAL_BOUNDARIES["start"]
            if c == ">":
                return _SPECIAL_BOUNDARIES["end"]
        if c.isascii() and not c.isalnum():
            # 转义的标点或空白, 两种引擎都当作字面量.
            return "\\" + c
        self.fail("不支持的转义 \\%s" % c)


def translate(pattern, verbose=False):
    """把 Rust 正则翻译为 Python 正则源码."""
    return _Translator(pattern, verbose).run()


def compile_regex(pattern, verbose=False):
    """按 lovely 的编译选项编译 Rust 正则, 返回 Python 的编译结果."""
    source = translate(pattern, verbose)
    try:
        return re.compile(source)
    except re.error as exc:
        raise RegexTranslateError("正则无法编译: %s: %r" % (exc, pattern)) from exc


def iter_matches(regex, text):
    """按 Rust regex 的规则迭代匹配.

    与 Python finditer 的区别: 空匹配不能出现在上一个匹配的结尾处, 遇到时从下一个位置重新查找.
    """
    start = 0
    last_end = None
    length = len(text)
    while start <= length:
        match = regex.search(text, start)
        if match is None:
            return
        if match.start() == match.end() and match.end() == last_end:
            start = last_end + 1
            if start > length:
                return
            match = regex.search(text, start)
            if match is None:
                return
        yield match
        last_end = match.end()
        start = match.end()


def _parse_number(text):
    """Rust usize 的解析规则, 失败或溢出时返回 None."""
    if not _USIZE_RE.fullmatch(text):
        return None
    value = int(text)
    return value if value <= _USIZE_MAX else None


def _find_cap_ref(template, index):
    """解析 template[index] 处以 $ 开头的分组引用, 返回 (分组, 结束位置) 或 None."""
    if index + 1 >= len(template):
        return None
    pos = index + 1
    if template[pos] == "{":
        end = template.find("}", pos + 1)
        if end < 0:
            return None
        name = template[pos + 1:end]
        number = _parse_number(name)
        return (number if number is not None else name), end + 1
    end = pos
    while end < len(template) and (template[end].isascii()
                                   and (template[end].isalnum() or template[end] == "_")):
        end += 1
    if end == pos:
        return None
    name = template[pos:end]
    number = _parse_number(name)
    return (number if number is not None else name), end


def interpolate(template, group_text, name_to_index):
    """复刻 regex_automata::util::interpolate::string.

    group_text(index) 返回分组内容; name_to_index(name) 返回分组序号, 不存在时返回 None,
    此时该引用替换为空串. `$$` 转义为 `$`, 无法解析的 `$` 原样保留.
    """
    out = []
    pos = 0
    while pos < len(template):
        dollar = template.find("$", pos)
        if dollar < 0:
            break
        out.append(template[pos:dollar])
        pos = dollar
        if template.startswith("$$", pos):
            out.append("$")
            pos += 2
            continue
        ref = _find_cap_ref(template, pos)
        if ref is None:
            out.append("$")
            pos += 1
            continue
        cap, pos = ref
        if isinstance(cap, int):
            out.append(group_text(cap))
        else:
            index = name_to_index(cap)
            if index is not None:
                out.append(group_text(index))
    out.append(template[pos:])
    return "".join(out)
