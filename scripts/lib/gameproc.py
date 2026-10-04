"""启动游戏进程并处理它的输出.

被 `run_agent.py` (agent 模式) 与 `replay_game.py` (回放模式) 共用. 两者的差别只在环境变量,
而"怎么定位可执行文件, 怎么把输出同时写终端与日志, 退出码怎么透传"是同一件事 ——
写两遍的话, 其中一份漏了"异常时不留后台游戏"那一段, 就会在中断后留下一个还在跑的游戏进程.

`sys.path` 由调用方 (just 直接跑 scripts/*.py 时仓库根已经在路径里) 保证, 模块内按
`from lib import ...` 取同目录的东西, 与 `run_agent.py` 的写法一致.
"""
import os
from pathlib import Path
import subprocess
import sys

from lib import layout


def game_executable(platform, version):
    """定位本次打包的产物, 不扫描目录或选择最近修改的旧版本."""
    if platform == "windows":
        bundle = "%s-%s-win64" % (layout.MODDED.file_stem, version)
        return Path(layout.WINDOWS_DIST) / bundle / (layout.APP_NAME + "-console.exe")
    return Path(layout.MACOS_DIST) / (layout.MODDED.file_stem + ".app") / "Contents/MacOS/love"


def stream_game(command, env, root, log_path, output=None):
    """实时复制游戏的 stdout/stderr 到终端与日志, 保留退出码, 异常时不留后台游戏."""
    if output is None:
        output = sys.stdout.buffer
    with open(log_path, "xb") as game_log:
        process = subprocess.Popen(command, cwd=root, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            # read1 不必攒满缓冲区才返回, 没有换行的输出也能实时写入日志.
            while chunk := process.stdout.read1(65536):
                game_log.write(chunk)
                game_log.flush()
                output.write(chunk)
                output.flush()
            return process.wait()
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            process.stdout.close()


def game_environment(base, **extra):
    """在父环境的基础上叠加变量, 只改子进程的那一份.

    传 `None` 表示把这个变量**删掉** —— 回放与 agent 是两种模式, 从一种切到另一种时,
    上一次留下的变量必须清掉, 否则会以相反的模式启动.
    """
    env = base.copy()
    for key, value in extra.items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = str(value)
    return env


def home_recordings():
    """游戏自己的录像目录 (存档目录下的 recordings).

    只用来在报错时提示"也可能在别处", 不参与实际的文件查找.
    """
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        return Path(home) / "Library/Application Support/Balatro-Modded/recordings"
    if os.name == "nt":
        return Path(home) / "AppData/Roaming/Balatro-Modded/recordings"
    return Path(home) / ".local/share/Balatro-Modded/recordings"
