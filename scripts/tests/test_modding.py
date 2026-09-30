"""补丁引擎的关键语义测试.

只覆盖与 lovely 行为容易出现偏差的地方: 这些偏差不会报错, 只会让补丁悄悄打错位置.
"""
import os
import tempfile
import textwrap
import unittest

from lib import log
from lib.modding import build, rust_regex
from lib.modding.patches import (LoadedPatch, Origin, PatchError, apply_all, apply_pattern,
                                 apply_regex, parse_patch)


def pattern(**kw):
    kw.setdefault("target", "a.lua")
    kw.setdefault("match_indent", True)
    return parse_patch({"pattern": kw}, "test", lambda _m: None)[1]


def regex(**kw):
    kw.setdefault("target", "a.lua")
    return parse_patch({"regex": kw}, "test", lambda _m: None)[1]


class PatternTest(unittest.TestCase):
    def test_window_skip_and_indent(self):
        # 命中后跳过整个窗口, 所以三行 x 只命中一次; 缩进取窗口首行.
        text = "  x\n  x\n  x\n"
        body = pattern(pattern="x\nx", position="after", payload="y")
        out, outcome = apply_pattern(body, text)
        self.assertEqual(outcome.matches, 1)
        self.assertEqual(out, "  x\n  x\n  y\n  x\n")

    def test_at_multiple_matches_keeps_offsets(self):
        text = "a\nb\na\nb\n"
        body = pattern(pattern="a", position="at", payload="1\n2\n3", match_indent=False)
        out, outcome = apply_pattern(body, text)
        self.assertEqual(outcome.matches, 2)
        self.assertEqual(out, "1\n2\n3\nb\n1\n2\n3\nb\n")

    def test_times_truncates(self):
        body = pattern(pattern="a", position="before", payload="z", times=1)
        out, outcome = apply_pattern(body, "a\na\n")
        self.assertEqual(outcome.status, "mismatch")
        self.assertEqual(out, "z\na\na\n")

    def test_wildcards_are_literal_otherwise(self):
        body = pattern(pattern="t[1] = ?*", position="at", payload="ok")
        out, _ = apply_pattern(body, "t[1] = 5\nt1 = 5\n")
        self.assertEqual(out, "ok\nt1 = 5\n")


class RegexTest(unittest.TestCase):
    def test_indent_prepend_and_named_group(self):
        body = regex(pattern=r"(?<indent>[\t ]*)foo\(\)", position="after",
                     payload="\nbar()", line_prepend="$indent")
        out, _ = apply_regex(body, "    foo()\n")
        # line_prepend 加在 payload 的每一行前, 包括开头换行符所在的空行, 因此 foo() 后多出缩进.
        self.assertEqual(out, "    foo()    \n    bar()\n")

    def test_word_boundary_space(self):
        # 插入内容会与左右的标识符粘连时, lovely 在两侧补空格.
        body = regex(pattern="and", position="at", payload="or")
        out, _ = apply_regex(body, "a and b")
        self.assertEqual(out, "a or b")
        body = regex(pattern=r"\+", position="at", payload="x")
        out, _ = apply_regex(body, "a+b")
        self.assertEqual(out, "a x b")

    def test_crlf_line_end(self):
        # crlf 模式下 $ 在 \r 之前, . 也不匹配 \r.
        body = regex(pattern=r"(?<v>.+)$", position="at", payload="[$v]")
        out, _ = apply_regex(body, "ab\r\ncd\r\n")
        self.assertEqual(out, "[ab]\r\n[cd]\r\n")

    def test_empty_match_after_match_is_skipped(self):
        spans = [m.span() for m in rust_regex.iter_matches(rust_regex.compile_regex("a*"), "baaa")]
        self.assertEqual(spans, [(0, 0), (1, 4)])

    def test_interpolation_rules(self):
        text = rust_regex.interpolate("$1a|${1}a|$$|$", lambda i: "<%d>" % i, lambda _n: None)
        self.assertEqual(text, "|<1>a|$|$")

    def test_unsupported_syntax_is_rejected(self):
        for source in (r"(?=x)", r"\p{L}", r"[a&&b]", r"\1"):
            with self.assertRaises(rust_regex.RegexTranslateError, msg=source):
                rust_regex.translate(source)


class OrderTest(unittest.TestCase):
    def test_pattern_before_regex_then_priority(self):
        def loaded(kind, body, priority):
            return LoadedPatch(kind, body, priority, Origin("m", "f", 0))
        # 加载顺序是 regex, A, B. 期望: B (优先级 -1) 最先, 然后 A, 最后才是 regex.
        # regex 若先于 A 应用会找不到 A; 忽略优先级则 B 会排在 A 之后.
        patches = [
            loaded("regex", regex(pattern="A", position="at", payload="R"), 0),
            loaded("pattern", pattern(pattern="s", position="after", payload="A"), 0),
            loaded("pattern", pattern(pattern="s", position="after", payload="B"), -1),
        ]
        out, count = apply_all(patches, "a.lua", "s\n", {}, lambda _p, _o: None)
        self.assertEqual(count, 3)
        self.assertEqual(out, "s\nR\nB\n")

    def test_unregistered_var_fails(self):
        with self.assertRaises(PatchError):
            apply_all([], "a.lua", "{{lovely:NOPE}}", {}, lambda _p, _o: None)


class BuildTreeTest(unittest.TestCase):
    def setUp(self):
        log.set_verbose(False)
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.game = os.path.join(root, "game")
        self.mods = os.path.join(root, "mods")
        os.makedirs(self.game)
        os.makedirs(os.path.join(self.mods, "Demo"))
        self.write(self.game, "main.lua", "print('main')\n")
        self.write(self.game, "conf.lua", "function love.conf(t) end\n")
        self.write(self.game, "game.lua", "local speed = 1\n")

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def write(root, rel, text):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(textwrap.dedent(text))

    def read(self, out, rel):
        with open(os.path.join(out, rel), encoding="utf-8") as fh:
            return fh.read()

    def test_module_patch_dir_and_injection(self):
        self.write(self.mods, "Demo/boot.lua", "local here = false\n")
        self.write(self.mods, "Demo/lovely.toml", """
            [manifest]
            version = "1.0.0"

            [[patches]]
            [patches.module]
            source = "boot.lua"
            name = "demo.boot"
            before = "main.lua"
            load_now = true

            [[patches]]
            [patches.pattern]
            target = '=[lovely demo.boot "boot.lua"]'
            pattern = "local here = false"
            position = "at"
            payload = "local here = [[{{lovely_hack:patch_dir}}]]"
            match_indent = true

            [[patches]]
            [patches.pattern]
            target = "game.lua"
            pattern = "local speed = 1"
            position = "after"
            payload = "speed = 2"
            match_indent = true
            """)
        out = os.path.join(self.tmp.name, "out")
        report = build.build_tree(self.game, self.mods, out, "Demo-Modded", "test")
        self.assertEqual(report.failures(), [])
        self.assertEqual(self.read(out, "game.lua"), "local speed = 1\nspeed = 2\n")
        self.assertTrue(self.read(out, "main.lua").startswith(
            'require("lovely_shim.runtime").before("main.lua");print'))
        self.assertIn("wrap_conf()", self.read(out, "conf.lua"))
        module = self.read(out, "lovely_shim/modules/001.lua")
        self.assertIn("@@LOVELY_SHIM_MOD_DIR_1@@", module)
        manifest = self.read(out, "lovely_shim/manifest.lua")
        self.assertIn('["needs_mod_dir"] = true', manifest)
        self.assertIn('"Demo-Modded"', manifest)

    def test_patch_dir_in_game_file_is_rejected(self):
        self.write(self.mods, "Demo/lovely.toml", """
            [manifest]
            version = "1.0.0"

            [[patches]]
            [patches.pattern]
            target = "game.lua"
            pattern = "local speed = 1"
            position = "at"
            payload = "local dir = '{{lovely_hack:patch_dir}}'"
            match_indent = true
            """)
        with self.assertRaises(PatchError):
            build.build_tree(self.game, self.mods, os.path.join(self.tmp.name, "out"), None, "t")


if __name__ == "__main__":
    unittest.main()
