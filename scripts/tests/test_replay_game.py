"""验证回放入口: 文件定位, 回放模式的环境, 以及它与 agent 模式的互斥."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

import replay_game


class ResolveReplayFileTest(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="replay-test-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.directory, ignore_errors=True))

    def write(self, name, text="{}"):
        path = self.directory / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_directory_with_one_replay_file(self):
        """一局一个文件夹是正常布局, 进去取那一个."""
        expected = self.write("game.replay.json")
        self.write("game.json")  # 同目录还有别的东西, 不该被当成回放
        self.assertEqual(replay_game.resolve_replay_file(str(self.directory), "."), expected)

    def test_directory_with_several_replay_files_is_refused(self):
        """混着好几局时不猜: 猜错就是回放了别的一局, 比报错更糟."""
        self.write("a.replay.json")
        self.write("b.replay.json")
        with self.assertRaises(ValueError) as caught:
            replay_game.resolve_replay_file(str(self.directory), ".")
        self.assertIn("没有唯一", str(caught.exception))

    def test_direct_file_is_taken_as_is(self):
        expected = self.write("only.replay.json")
        self.assertEqual(replay_game.resolve_replay_file(str(expected), "."), expected)

    def test_relative_path_resolves_against_invocation_directory(self):
        """相对路径按"用户敲命令时的目录"解析, 而不是 just 文件所在目录."""
        expected = self.write("rel.replay.json")
        self.assertEqual(
            replay_game.resolve_replay_file("rel.replay.json", str(self.directory)), expected)

    def test_missing_file_is_refused(self):
        with self.assertRaises(ValueError):
            replay_game.resolve_replay_file(str(self.directory / "nope.replay.json"), ".")


class ReplayEnvironmentTest(unittest.TestCase):
    def test_replay_mode_sets_its_variables_and_clears_agent_ones(self):
        """两种模式互斥: 留着 agent 的加速开关会让回放不等讲解."""
        original = {
            "PATH": "保留",
            "BALATROBOT_FAST": "1",
            "BALATROBOT_REPLAY": "旧回放",
            "BALATROBOT_REPLAY_PACING": "fast",
        }
        snapshot = original.copy()
        env = replay_game.replay_environment(original, Path("/tmp/now.replay.json"), "tight",
                                             Path("/tmp/recordings"))
        # 父环境不能被改 (just 里连着跑别的 recipe 时会看到).
        self.assertEqual(original, snapshot)
        self.assertEqual(env["PATH"], original["PATH"])
        self.assertEqual(env["BALATROBOT_ENABLE"], "1")
        self.assertEqual(env["BALATRO_SAVE_IDENTITY"], "Balatro-Replay")
        self.assertEqual(env["BALATROBOT_REPLAY"], "/tmp/now.replay.json")
        self.assertEqual(env["BALATROBOT_REPLAY_PACING"], "tight")
        self.assertEqual(env["BALATROBOT_RECORD_VIDEO"], "on")
        self.assertEqual(env["BALATROBOT_RECORD_PREFIX"], "replay-")
        self.assertNotIn("BALATROBOT_FAST", env)

    def test_agent_and_replay_environments_do_not_leak_into_each_other(self):
        """从一种模式切到另一种时, 上一次留下的变量必须清干净."""
        import run_agent
        # 先按回放配置, 再以它为基础配 agent: agent 那边不该看到回放变量.
        replay = replay_game.replay_environment({}, Path("/tmp/x.replay.json"), "fast",
                                               Path("/tmp/recordings"))
        agent = run_agent.game_environment(replay, "on", "0", "recordings")
        self.assertNotIn("BALATROBOT_REPLAY", agent)
        self.assertNotIn("BALATROBOT_REPLAY_PACING", agent)
        self.assertNotIn("BALATROBOT_RECORD_PREFIX", agent)
        self.assertEqual(agent["BALATRO_SAVE_IDENTITY"], "Balatro-Agent")
        self.assertEqual(agent["BALATROBOT_FAST"], "0")


if __name__ == "__main__":
    unittest.main()
