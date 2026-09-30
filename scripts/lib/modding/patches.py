"""lovely 补丁的数据模型与应用逻辑.

字段校验与 lovely 0.10.0 的 serde 定义一致: 缺少必填字段直接报错, 未知字段只警告.
应用逻辑逐行对照 lovely-core 的 patch/pattern.rs, regex.rs, copy.rs 复刻, 包括它的边界行为,
例如 pattern 匹配后跳过整个窗口, regex 插入时为避免粘连标识符而补空格.
"""
import re
from dataclasses import dataclass, field

from . import rust_regex

POSITIONS = ("at", "before", "after")
COPY_POSITIONS = ("prepend", "append")


class PatchError(Exception):
    """补丁文件无效, 或补丁应用时触发了 lovely 里会 panic 的情况."""


@dataclass
class Origin:
    """补丁的来源, 用于日志与报错."""
    mod: str
    file: str
    index: int

    def __str__(self):
        return "%s/%s#%d" % (self.mod, self.file, self.index)


@dataclass
class PatternPatch:
    targets: list
    pattern: str
    position: str
    payload: str
    match_indent: bool
    times: int = None


@dataclass
class RegexPatch:
    targets: list
    pattern: str
    position: str
    payload: str
    root_capture: str = None
    line_prepend: str = ""
    times: int = None
    verbose: bool = False
    compiled: object = None


@dataclass
class CopyPatch:
    targets: list
    position: str
    sources: list = None
    payload: str = None
    contents: list = field(default_factory=list)


@dataclass
class ModulePatch:
    source: str
    name: str
    before: str = None
    load_now: bool = False
    content: str = ""


@dataclass
class LoadedPatch:
    """已加载的补丁及其优先级与来源."""
    kind: str
    body: object
    priority: int
    origin: Origin

    def targets(self):
        if self.kind == "module":
            return [self.body.before or ""]
        return self.body.targets


@dataclass
class Outcome:
    """一次应用的结果. status 为 ok, miss (没有匹配) 或 mismatch (匹配次数与 times 不符)."""
    status: str
    matches: int = 0
    detail: str = ""


# ---------------------------------------------------------------- 字段解析

_SCHEMA = {
    "pattern": {"target": True, "pattern": True, "position": True, "payload": True,
                "match_indent": True, "times": False, "overwrite": False, "name": False},
    "regex": {"target": True, "pattern": True, "position": True, "payload": True,
              "root_capture": False, "line_prepend": False, "times": False,
              "verbose": False, "name": False},
    "copy": {"target": True, "position": True, "sources": False, "payload": False, "name": False},
    "module": {"source": True, "name": True, "before": False, "load_now": False},
}


def _expect(where, key, value, kind):
    if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
        raise PatchError("%s: 字段 %s 类型错误: %r" % (where, key, value))
    return value


def _targets(where, value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(x, str) for x in value):
        return list(value)
    raise PatchError("%s: target 应为字符串或字符串列表: %r" % (where, value))


def _times(where, value):
    if value is None:
        return None
    _expect(where, "times", value, int)
    if value < 0:
        raise PatchError("%s: times 不能为负数" % where)
    return value


def parse_patch(entry, where, warn):
    """把 [[patches]] 里的一项解析为 (kind, body)."""
    if not isinstance(entry, dict) or len(entry) != 1:
        raise PatchError("%s: 每个 [[patches]] 必须恰好包含 pattern/regex/copy/module 之一" % where)
    kind, raw = next(iter(entry.items()))
    if kind not in _SCHEMA or not isinstance(raw, dict):
        raise PatchError("%s: 未知的补丁类型 %r" % (where, kind))
    schema = _SCHEMA[kind]
    for key in raw:
        if key not in schema:
            warn("%s: 忽略未知字段 %s" % (where, key))
    for key, required in schema.items():
        if required and key not in raw:
            raise PatchError("%s: %s 补丁缺少必填字段 %s" % (where, kind, key))

    def get(key, kind_, default=None):
        return _expect(where, key, raw[key], kind_) if key in raw else default

    if kind in ("pattern", "regex"):
        position = get("position", str)
        if position not in POSITIONS:
            raise PatchError("%s: 无效的 position %r" % (where, position))
    if kind == "pattern":
        return kind, PatternPatch(
            targets=_targets(where, raw["target"]),
            pattern=get("pattern", str),
            position=position,
            payload=get("payload", str),
            match_indent=get("match_indent", bool),
            times=_times(where, raw.get("times")),
        )
    if kind == "regex":
        body = RegexPatch(
            targets=_targets(where, raw["target"]),
            pattern=get("pattern", str),
            position=position,
            payload=get("payload", str),
            root_capture=get("root_capture", str),
            line_prepend=get("line_prepend", str, ""),
            times=_times(where, raw.get("times")),
            verbose=get("verbose", bool, False),
        )
        try:
            body.compiled = rust_regex.compile_regex(body.pattern, body.verbose)
        except rust_regex.RegexTranslateError as exc:
            raise PatchError("%s: %s" % (where, exc)) from exc
        return kind, body
    if kind == "copy":
        position = get("position", str)
        if position not in COPY_POSITIONS:
            raise PatchError("%s: 无效的 copy position %r" % (where, position))
        sources = raw.get("sources")
        if sources is not None and not (isinstance(sources, list)
                                        and all(isinstance(x, str) for x in sources)):
            raise PatchError("%s: sources 应为字符串列表" % where)
        return kind, CopyPatch(
            targets=_targets(where, raw["target"]),
            position=position,
            sources=sources,
            payload=get("payload", str),
        )
    body = ModulePatch(
        source=get("source", str),
        name=get("name", str),
        before=get("before", str),
        load_now=get("load_now", bool, False),
    )
    if body.load_now and body.before is None:
        raise PatchError("%s: 模块 %s 设置了 load_now, 但缺少 before" % (where, body.name))
    return kind, body


# ---------------------------------------------------------------- 文本工具

def rust_trim(text):
    return text.strip(rust_regex.WHITESPACE)


def rust_lines(text):
    """Rust str::lines: 只按 \\n 切分, 去掉行尾 \\r, 末尾换行不产生空行."""
    if not text:
        return []
    parts = text.split("\n")
    if text.endswith("\n"):
        parts.pop()
    return [part[:-1] if part.endswith("\r") else part for part in parts]


def split_inclusive(text):
    """Rust split_inclusive('\\n'): 保留换行符, 空串得到空列表."""
    if not text:
        return []
    parts = text.split("\n")
    out = [part + "\n" for part in parts[:-1]]
    if parts[-1]:
        out.append(parts[-1])
    return out


def line_starts(text):
    """每一行起始的字符位置, 末尾追加总长度, 对应 crop Rope::byte_of_line."""
    starts = [0]
    pos = text.find("\n")
    while pos >= 0:
        starts.append(pos + 1)
        pos = text.find("\n", pos + 1)
    if starts[-1] != len(text):
        starts.append(len(text))
    return starts


def _wildcard(line):
    """编译 pattern 的一行: 只有 * 与 ? 是通配符, 其余字符按字面匹配, 区分大小写."""
    if "*" not in line and "?" not in line:
        return line.__eq__
    parts = []
    for ch in line:
        if ch == "*":
            parts.append(".*")
        elif ch == "?":
            parts.append(".")
        else:
            parts.append(re.escape(ch))
    return re.compile("".join(parts), re.S).fullmatch


def _is_word_char(ch):
    return ch.isascii() and (ch.isalnum() or ch == "_")


# ---------------------------------------------------------------- 应用

def apply_pattern(patch, text):
    """应用 pattern 补丁, 返回 (新文本, Outcome)."""
    matchers = [_wildcard(rust_trim(line)) for line in rust_lines(patch.pattern)]
    if not matchers:
        return text, Outcome("miss", 0, "pattern 没有内容")
    count = len(matchers)
    raw = split_inclusive(text)
    trimmed = [rust_trim(line) for line in raw]

    matches = []
    index = 0
    while index + count <= len(raw):
        if all(matchers[k](trimmed[index + k]) for k in range(count)):
            indent = ""
            if patch.match_indent:
                line = raw[index]
                indent = line[:len(line) - len(line.lstrip(" \t"))]
            matches.append((index, indent))
            index += count
        else:
            index += 1

    if not matches:
        return text, Outcome("miss", 0)
    outcome = Outcome("ok", len(matches))
    if patch.times is not None and len(matches) != patch.times:
        outcome = Outcome("mismatch", len(matches), "期望 %d 次" % patch.times)
        matches = matches[:patch.times]

    delta = 0
    for line_index, indent in matches:
        adjusted = max(0, line_index + delta)
        starts = line_starts(text)
        if adjusted + count >= len(starts):
            raise PatchError("pattern 补丁的行号越界, lovely 在这里会崩溃")
        start = starts[adjusted]
        end = starts[adjusted + count]
        payload = "".join(indent + line for line in split_inclusive(patch.payload))
        if not patch.payload.endswith("\n"):
            payload += "\n"
        payload_lines = len(rust_lines(payload))
        if patch.position == "before":
            text = text[:start] + payload + text[start:]
            delta += payload_lines
        elif patch.position == "after":
            text = text[:end] + payload + text[end:]
            delta += payload_lines
        else:
            text = text[:start] + payload + text[end:]
            delta += payload_lines - count
    return text, outcome


def apply_regex(patch, text):
    """应用 regex 补丁, 返回 (新文本, Outcome)."""
    regex = patch.compiled
    captures = list(rust_regex.iter_matches(regex, text))
    if not captures:
        return text, Outcome("miss", 0)
    outcome = Outcome("ok", len(captures))
    if patch.times is not None and len(captures) != patch.times:
        outcome = Outcome("mismatch", len(captures), "期望 %d 次" % patch.times)
        captures = captures[:patch.times]

    names = regex.groupindex
    root = (patch.root_capture or "0").replace("$", "")

    delta = 0
    for match in captures:
        def group_text(index, match=match):
            if index > regex.groups or match.start(index) < 0:
                raise PatchError("payload 引用的分组 %d 不存在或没有参与匹配: %r"
                                 % (index, patch.pattern))
            return match.group(index)

        line_prepend = rust_regex.interpolate(patch.line_prepend, group_text, names.get)

        number = rust_regex._parse_number(root)
        group = number if number is not None else names.get(root)
        if group is None or group > regex.groups or match.start(group) < 0:
            raise PatchError("root_capture %r 不存在或没有参与匹配: %r"
                             % (patch.root_capture, patch.pattern))
        target_start = match.start(group) + delta
        target_end = match.end(group) + delta

        prepended = "".join(line_prepend + line for line in split_inclusive(patch.payload))
        payload = rust_regex.interpolate(prepended, group_text, names.get)

        # 与 lovely 相同: 插入点两侧若会拼成更长的标识符, 在对应一侧补一个空格.
        if payload and _is_word_char(payload[0]):
            left = target_end if patch.position == "after" else target_start
            if left > 0 and _is_word_char(text[left - 1]):
                payload = " " + payload
        if payload and _is_word_char(payload[-1]):
            right = target_start if patch.position == "before" else target_end
            if right < len(text) and _is_word_char(text[right]):
                payload = payload + " "

        if patch.position == "before":
            text = text[:target_start] + payload + text[target_start:]
            delta += len(payload)
        elif patch.position == "after":
            text = text[:target_end] + payload + text[target_end:]
            delta += len(payload)
        else:
            text = text[:target_start] + payload + text[target_end:]
            delta += len(payload) - (target_end - target_start)
    return text, outcome


def apply_copy(patch, text):
    """应用 copy 补丁, 返回 (新文本, Outcome)."""
    payloads = list(patch.contents)
    if patch.payload is not None:
        payloads.append(patch.payload)
    for content in payloads:
        if patch.position == "prepend":
            text = content + "\n" + text
        else:
            text = text + "\n" + content
    return text, Outcome("ok", len(payloads))


_VAR_RE = re.compile(r"\{\{lovely:([0-9A-Za-z_]+)\}\}")


def interpolate_vars(text, variables):
    """把 {{lovely:NAME}} 替换为 [vars] 中的值, 未登记的变量在 lovely 里会 panic."""
    def replace(match):
        name = match.group(1)
        if name not in variables:
            raise PatchError("引用了未登记的变量 %s" % name)
        return variables[name]
    return _VAR_RE.sub(replace, text)


def ordered_for_target(patches, target):
    """返回作用于 target 的补丁, 顺序与 lovely 的 PatchTable::apply_patches 一致.

    copy 按优先级稳定排序后先应用; 其后是 pattern 与 regex: 先按加载顺序排出全部 pattern,
    再接全部 regex, 最后按优先级稳定排序.
    """
    def hits(p):
        return target in p.body.targets

    copies = sorted((p for p in patches if p.kind == "copy" and hits(p)),
                    key=lambda p: p.priority)
    textual = [p for p in patches if p.kind == "pattern" and hits(p)]
    textual += [p for p in patches if p.kind == "regex" and hits(p)]
    textual.sort(key=lambda p: p.priority)
    return copies + textual


def apply_all(patches, target, text, variables, report):
    """把 patches 中作用于 target 的补丁依次应用到 text, 最后做变量插值.

    只应对 lovely 认定需要打补丁的目标调用: lovely 对这类目标总会做变量插值, 即使没有补丁命中.
    report(patch, outcome) 在每个补丁应用后调用. 返回 (新文本, 应用的补丁数).
    """
    count = 0
    for patch in ordered_for_target(patches, target):
        if patch.kind == "copy":
            text, outcome = apply_copy(patch.body, text)
        elif patch.kind == "pattern":
            text, outcome = apply_pattern(patch.body, text)
        else:
            text, outcome = apply_regex(patch.body, text)
        report(patch, outcome)
        count += 1
    return interpolate_vars(text, variables), count
