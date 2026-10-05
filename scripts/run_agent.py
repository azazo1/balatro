"""跨平台打包并启动外部 agent, 共用独立存档, 录像目录与游戏日志.

    just windows run-agent [on|off] [0|1]
    just macos run-agent [on|off] [0|1]

由 just 直接调用, 不经过 shell 拼接参数. Windows 使用控制台版 exe 获取游戏输出.
"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import subprocess
import sys

from lib import layout, log, version as versionlib


def game_executable(platform, version):
    """定位本次打包的产物, 不扫描目录或选择最近修改的旧版本."""
    if platform == "windows":
        bundle = "%s-%s-win64" % (layout.MODDED.file_stem, version)
        return Path(layout.WINDOWS_DIST) / bundle / (layout.APP_NAME + "-console.exe")
    return Path(layout.MACOS_DIST) / (layout.MODDED.file_stem + ".app") / "Contents/MacOS/love"


def game_environment(base, record, fast, recordings):
    """只修改子进程环境, 参数优先于继承的环境变量和存档设置."""
    env = base.copy()
    env.update({
        "BALATROBOT_ENABLE": "1",
        "BALATROBOT_FAST": fast,
        "BALATRO_SAVE_IDENTITY": "Balatro-Agent",
        "BALATROBOT_RECORD_VIDEO": record,
        "BALATROBOT_RECORD_REPLAY": base.get("BALATROBOT_RECORD_REPLAY", record),
        "BALATROBOT_RECORD_DIR": str(Path(recordings).resolve()),
    })
    # 普通 agent 启动不应被之前回放任务的环境切换成回放模式.
    for key in ("BALATROBOT_REPLAY", "BALATROBOT_REPLAY_PACING", "BALATROBOT_RECORD_PREFIX"):
        env.pop(key, None)
    return env


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


def main(argv=None):
    parser = argparse.ArgumentParser(description="打包并启动外部 agent")
    parser.add_argument("platform", choices=("macos", "windows"))
    parser.add_argument("record", nargs="?", choices=("on", "off"), default="on")
    parser.add_argument("fast", nargs="?", choices=("0", "1"), default="0")
    args = parser.parse_args(argv)
    log.set_prefix("agent")
    expected_host = "win32" if args.platform == "windows" else "darwin"
    if sys.platform != expected_host:
        log.die("%s run-agent 需要在对应的平台上运行" % args.platform)

    try:
        # 打包和定位使用同一版本, 不受多个历史产物或重复版本探测影响.
        version = versionlib.build_version()
        build_env = os.environ.copy()
        build_env["PROJECT_BUILD_VERSION"] = version
        command = [sys.executable, str(Path(layout.SCRIPTS_DIR) / ("package_%s.py" % args.platform)),
                   "--mods"]
        if args.platform == "windows":
            command.append("--console")
        log.info("打包 %s agent 版本: %s" % (args.platform, version))
        built = subprocess.run(command, cwd=layout.ROOT_DIR, env=build_env)
        if built.returncode != 0:
            return built.returncode

        executable = game_executable(args.platform, version)
        if not executable.is_file():
            log.die("找不到本次打包的游戏: %s" % executable)
        recordings = Path(layout.ROOT_DIR) / "recordings"
        recordings.mkdir(parents=True, exist_ok=True)
        log_path = recordings / (datetime.now().strftime("%Y%m%d-%H%M%S-%f") + "-game.log")
        env = game_environment(os.environ, args.record, args.fast, recordings)
        log.info("启动游戏: %s (录制 %s, 加速 %s)" % (executable, args.record, args.fast))
        log.info("游戏日志: %s" % log_path)
        result = stream_game([str(executable)], env, layout.ROOT_DIR, log_path)
        if result != 0:
            log.warn("游戏退出码: %d, 详情见 %s" % (result, log_path))
        return result
    except KeyboardInterrupt:
        log.info("启动任务已中止")
        return 130
    except OSError as exc:
        log.die("启动任务失败: %s" % exc)


if __name__ == "__main__":
    sys.exit(main())
