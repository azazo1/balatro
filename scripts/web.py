#!/usr/bin/env python3
"""Engine Web 的跨平台构建, 启动与测试入口."""
import argparse
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import tomllib

from lib import layout, log, version as versionlib
import web_game

ROOT = Path(layout.ROOT_DIR)
WEB = ROOT / "impls" / "web"
CLIENT = WEB / "client"
TARGET = WEB / "target"
TOOLS = ROOT / ".tmp" / "engine-web-tools"


def bindgen_version():
    """绑定生成器必须与锁文件中的 wasm-bindgen 完全同版."""
    with (WEB / "Cargo.lock").open("rb") as file:
        lock = tomllib.load(file)
    return next(p["version"] for p in lock["package"] if p["name"] == "wasm-bindgen")


def ensure_tools():
    version = bindgen_version()
    binary = TOOLS / "bin" / ("wasm-bindgen.exe" if os.name == "nt" else "wasm-bindgen")
    candidates = [binary, shutil.which("wasm-bindgen")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            result = subprocess.run([str(candidate), "--version"], capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip() == "wasm-bindgen " + version:
                return str(candidate)
    log.info("准备项目级 wasm-bindgen %s, 工具仅写入 .tmp/engine-web-tools" % version)
    log.run(["cargo", "install", "--root", str(TOOLS), "--locked", "--version", version, "--force", "wasm-bindgen-cli"], cwd=str(ROOT))
    return str(binary)


def sync_game_assets():
    """把原版图集, 字体与贴图清单同步到 client/public/game."""
    log.run([sys.executable, str(ROOT / "scripts" / "web_assets.py")], cwd=str(ROOT))


def build_assets(version=None, game=True):
    """game 为真时同时构建浏览器版游戏, 进入 dist/play/; 否则清掉旧的, 页面上的入口随之隐藏."""
    started = time.monotonic()
    version = version or versionlib.build_version()
    env = dict(os.environ, CARGO_TARGET_DIR=str(TARGET), PROJECT_BUILD_VERSION=version)
    installed = subprocess.run(["rustup", "target", "list", "--installed"], capture_output=True, text=True, check=True).stdout.split()
    if "wasm32-unknown-unknown" not in installed:
        log.die("缺少 wasm32-unknown-unknown, 请先安装该 Rust 编译目标")
    bindgen = ensure_tools()
    log.run(["bun", "install", "--frozen-lockfile"], cwd=str(CLIENT))
    log.info("构建 Rust WASM 引擎")
    log.run(["cargo", "build", "--release", "--locked", "--manifest-path", str(WEB / "Cargo.toml"),
             "-p", "balatro-web-wasm", "--target", "wasm32-unknown-unknown"], env=env)
    log.run([bindgen, "--target", "web", "--out-dir", str(CLIENT / "public" / "wasm"), "--out-name", "engine_lab",
             str(TARGET / "wasm32-unknown-unknown" / "release" / "balatro_web_wasm.wasm")])
    sync_game_assets()
    if game:
        web_game.build()
    elif web_game.OUT.exists():
        shutil.rmtree(web_game.OUT)
    log.run(["bun", "run", "build"], cwd=str(CLIENT), env=env)
    log.run(["bun", "run", str(ROOT / "scripts" / "engine_wasm_smoke.ts")] + ([version] if version else []), cwd=str(ROOT))
    for relative in ["index.html", "wasm/engine_lab.js", "wasm/engine_lab_bg.wasm", "game/sprites.json"]:
        if not (CLIENT / "dist" / relative).is_file():
            log.die("前端构建缺少 " + relative)
    log.info("Web/WASM 构建完成, %.1f 秒" % (time.monotonic() - started))
    return CLIENT / "dist"


def run_processes(commands, cwd, env=None):
    """任一子进程退出后收尾其它进程, Ctrl+C 也走同一路径."""
    processes = []
    try:
        for command in commands:
            log.info("启动: " + " ".join(map(str, command)))
            processes.append(subprocess.Popen(command, cwd=str(cwd), env=env))
        with ThreadPoolExecutor(max_workers=len(processes)) as pool:
            futures = [pool.submit(p.wait) for p in processes]
            try:
                finished, _ = wait(futures, return_when=FIRST_COMPLETED)
                return next(iter(finished)).result()
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                for process in processes:
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    except KeyboardInterrupt:
        log.info("启动器已退出")
        return 0
    finally:
        # 也覆盖第二个 Popen 启动失败, 避免留下先启动的服务.
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description="构建与运行 Engine Web")
    parser.add_argument("command", choices=["build", "run", "dev", "test", "tools"])
    parser.add_argument("--port", type=int, default=12347)
    parser.add_argument("--frontend-port", type=int, default=5173)
    parser.add_argument("--mode", choices=["http", "wasm"], default="http")
    parser.add_argument("--no-game", action="store_true", help="不构建浏览器版游戏 (/play/), 构建更快")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 1 <= args.frontend_port <= 65535:
        parser.error("端口须为 1..65535")
    log.set_prefix("web")
    if args.command == "tools":
        ensure_tools()
        return 0
    if args.command == "test":
        log.run(["cargo", "test", "--locked", "--manifest-path", str(WEB / "Cargo.toml"), "--workspace"])
        log.run(["cargo", "clippy", "--locked", "--manifest-path", str(WEB / "Cargo.toml"), "--workspace", "--all-targets", "--", "-D", "warnings"])
        log.run(["bun", "install", "--frozen-lockfile"], cwd=str(CLIENT))
        log.run(["bun", "run", "test"], cwd=str(CLIENT))
        build_assets(game=not args.no_game)
        return 0
    version = versionlib.build_version()
    def stop(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    assets = build_assets(version, game=not args.no_game)
    env = dict(os.environ, PROJECT_BUILD_VERSION=version)
    if args.command == "build":
        return 0
    if args.command == "run" and args.mode == "wasm":
        log.info("纯静态 WASM 页面: http://127.0.0.1:%d" % args.port)
        return run_processes([[sys.executable, "-m", "http.server", str(args.port), "--bind", "127.0.0.1", "--directory", str(assets)]], ROOT)
    cargo = ["cargo", "run", "--locked", "--manifest-path", str(WEB / "Cargo.toml"), "-p", "balatro-web-server", "--", "--port", str(args.port), "--static", str(assets)]
    if args.command == "run":
        log.info("双模式页面: http://127.0.0.1:%d" % args.port)
        return run_processes([cargo], ROOT, env=env)
    origin = "http://127.0.0.1:%d" % args.frontend_port
    cargo += ["--dev-origin", origin]
    env["ENGINE_WEB_API"] = "http://127.0.0.1:%d" % args.port
    log.info("开发页面: " + origin)
    return run_processes([cargo, ["bun", "run", "dev", "--port", str(args.frontend_port)]], CLIENT, env=env)


if __name__ == "__main__":
    sys.exit(main())
