"""验证 agent 启动环境, 产物定位, 日志转发和跨平台 JSON 参数."""
import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from lib import layout
import run_agent


class RunAgentTest(unittest.TestCase):
    def test_environment_overrides_without_changing_parent(self):
        original = {
            "PATH": "保留",
            "BALATROBOT_ENABLE": "0",
            "BALATROBOT_FAST": "1",
            "BALATROBOT_RECORD_VIDEO": "on",
            "BALATROBOT_RECORD_DIR": "旧目录",
            "BALATROBOT_REPLAY": "旧回放",
            "BALATROBOT_REPLAY_PACING": "fast",
            "BALATROBOT_RECORD_PREFIX": "replay-",
        }
        snapshot = original.copy()
        env = run_agent.game_environment(original, "off", "0", "recordings")
        self.assertEqual(original, snapshot)
        self.assertEqual(env["PATH"], original["PATH"])
        self.assertEqual(env["BALATROBOT_ENABLE"], "1")
        self.assertEqual(env["BALATROBOT_FAST"], "0")
        self.assertEqual(env["BALATROBOT_RECORD_VIDEO"], "off")
        self.assertEqual(env["BALATROBOT_RECORD_REPLAY"], "off")
        self.assertEqual(env["BALATRO_SAVE_IDENTITY"], "Balatro-Agent")
        self.assertEqual(env["BALATROBOT_RECORD_DIR"], str(Path("recordings").resolve()))
        self.assertNotIn("BALATROBOT_REPLAY", env)
        self.assertNotIn("BALATROBOT_REPLAY_PACING", env)
        self.assertNotIn("BALATROBOT_RECORD_PREFIX", env)

    def test_replay_recording_is_independent_of_video_argument(self):
        for video, replay in (("on", "off"), ("off", "on")):
            env = run_agent.game_environment({"BALATROBOT_RECORD_REPLAY": replay}, video, "0", "recordings")
            self.assertEqual(env["BALATROBOT_RECORD_VIDEO"], video)
            self.assertEqual(env["BALATROBOT_RECORD_REPLAY"], replay)

    def test_executable_matches_current_build(self):
        windows = run_agent.game_executable("windows", "1.0.1o+abcdef0")
        self.assertEqual(windows, Path(layout.WINDOWS_DIST) /
                         "Balatro-Modded-1.0.1o+abcdef0-win64" / "Balatro-console.exe")
        self.assertNotEqual(windows, run_agent.game_executable("windows", "1.0.1o+1234567"))
        self.assertEqual(run_agent.game_executable("macos", "unused"),
                         Path(layout.MACOS_DIST) / "Balatro-Modded.app/Contents/MacOS/love")

    def test_failed_build_does_not_launch_game(self):
        with patch.object(run_agent.sys, "platform", "win32"), \
                patch.object(run_agent.versionlib, "build_version", return_value="1.0.1o+abcdef0"), \
                patch.object(run_agent.subprocess, "run") as build, \
                patch.object(run_agent, "stream_game") as launch:
            build.return_value.returncode = 9
            self.assertEqual(run_agent.main(["windows"]), 9)
            command = build.call_args.args[0]
            self.assertEqual(command[-2:], ["--mods", "--console"])
            self.assertEqual(build.call_args.kwargs["env"]["PROJECT_BUILD_VERSION"], "1.0.1o+abcdef0")
            launch.assert_not_called()

    def test_interrupted_output_stops_game(self):
        scratch = Path(layout.ROOT_DIR) / ".tmp"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory, \
                patch.object(run_agent.subprocess, "Popen") as spawn:
            process = spawn.return_value
            process.stdout.read1.side_effect = KeyboardInterrupt
            process.poll.return_value = None
            with self.assertRaises(KeyboardInterrupt):
                run_agent.stream_game(["game"], {}, directory,
                                      Path(directory) / "game-output.txt", io.BytesIO())
            process.terminate.assert_called_once()
            process.wait.assert_called_once_with(timeout=5)
            process.stdout.close.assert_called_once()

    def test_binary_log_and_exit_code(self):
        # 使用真实子进程, 检查没有换行的 UTF-8 输出, stderr 和非零退出码也能被保留.
        scratch = Path(layout.ROOT_DIR) / ".tmp"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            log_path = Path(directory) / "game-output.txt"
            output = io.BytesIO()
            data = "没有换行的游戏输出".encode("utf-8")
            code = ("import sys; sys.stdout.buffer.write(bytes.fromhex(%r)); "
                    "sys.stdout.flush(); sys.stderr.buffer.write(b'\\x00error'); "
                    "sys.stderr.flush(); sys.exit(7)") % data.hex()
            result = run_agent.stream_game([sys.executable, "-c", code], os.environ.copy(),
                                           directory, log_path, output)
            self.assertEqual(result, 7)
            self.assertEqual(output.getvalue(), data + b"\x00error")
            self.assertEqual(log_path.read_bytes(), output.getvalue())


@unittest.skipUnless(shutil.which("just"), "需要 just 验证真实 recipe 参数")
class AgentRecipeTest(unittest.TestCase):
    def test_rpc_recipes_preserve_json_and_wait_arguments(self):
        received = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                received.append(request)
                body = json.dumps({"jsonrpc": "2.0", "id": request["id"],
                                   "result": {"state": "MENU"}}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # 一次覆盖双引号, 单引号, 反斜杠, 换行, 中文和 shell 元字符.
            params = {"cards": [0, 1], "reason": "中文 '双引号\" C:\\路径\\牌\n$HOME & ; {{表达式}}"}
            command = [shutil.which("just"), "agent-call", "play",
                       json.dumps(params, ensure_ascii=False), str(server.server_port)]
            result = subprocess.run(command, cwd=layout.ROOT_DIR, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
            self.assertEqual(received[0]["method"], "play")
            self.assertEqual(received[0]["params"], params)
            self.assertEqual(json.loads(result.stdout)["result"]["state"], "MENU")

            result = subprocess.run([shutil.which("just"), "agent-wait", "MENU", "3",
                                     str(server.server_port)], cwd=layout.ROOT_DIR,
                                    capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
            self.assertEqual(received[1]["method"], "gamestate")
            self.assertEqual(received[1]["params"], {})
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
