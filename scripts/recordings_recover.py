#!/usr/bin/env python3
"""补做录像合成: 扫描录像目录里游戏崩溃后残留的中间文件, 对还没有 -full.mp4 的局补做合成.

录制中每局只写中间文件 <stem>.video.mp4 (fragmented mp4), <stem>.pcm (s16le 44100Hz 双声道)
和合成脚本 <stem>.post.sh, 局末才合成 -full.mp4. 游戏崩溃时局末那一步没有发生,
这里补上: 优先执行现成的 .post.sh (开局时就写出的草稿);
没有脚本, 或脚本里的路径已经不在这个目录时, 按 mods/bbreplay/record/post.lua 的规则直接合成 -full.mp4.

每局一个文件夹 (<stem>/<stem>.*) 与旧版平铺 (<stem>.*) 两种布局都扫.

默认只列出不执行, 加 --run 才合成. 正在录制或正在合成的局会跳过.

用法:
    python3 scripts/recordings_recover.py                    # 列出 recordings/ 里的残留
    python3 scripts/recordings_recover.py --run              # 补做合成, 保留中间文件
    python3 scripts/recordings_recover.py --run --clean      # 全部成功后删除中间文件
    python3 scripts/recordings_recover.py 别处/recordings --run
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import layout, log

log.set_prefix("recover")

# 中间文件后缀, 与 mods/bbreplay/record/post.lua 一致. 合成脚本在 Windows 上是 .post.cmd.
SUFFIXES = (".video.mp4", ".pcm", ".post.sh", ".post.cmd")
GAME_PATTERN = "Balatro-Modded"
IS_WINDOWS = os.name == "nt"


def parse_args():
    parser = argparse.ArgumentParser(description="扫描录像目录里残留的中间文件并补做合成")
    parser.add_argument("dir", nargs="?", default=os.path.join(layout.ROOT_DIR, "recordings"),
                        help="录像目录, 默认仓库根目录的 recordings/")
    parser.add_argument("--run", action="store_true", help="执行合成, 不加时只列出")
    parser.add_argument("--clean", action="store_true", help="与 --run 一起用: 合成全部成功后删除中间文件")
    parser.add_argument("--idle", type=float, default=30,
                        help="游戏在运行时, 中间文件在这么多秒内有变化的局视为正在录制, 默认 30")
    parser.add_argument("--ffmpeg", help="ffmpeg 路径, 默认 $BALATROBOT_FFMPEG 或 PATH 中的 ffmpeg")
    parser.add_argument("-v", "--verbose", action="store_true", help="输出执行的命令等细节")
    return parser.parse_args()


def find_ffmpeg(explicit):
    for candidate in (explicit, os.environ.get("BALATROBOT_FFMPEG"), "ffmpeg",
                      "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if candidate:
            path = shutil.which(candidate)
            if path:
                return path
    return None


def game_running():
    """游戏进程是否在运行. 只读, 列不出进程时保守地认为在运行.

    Windows 上 exe 名固定为 Balatro.exe (变体只体现在目录名上), 用 tasklist 按映像名查;
    其余平台用 pgrep 按命令行里的 Balatro-Modded 查.
    """
    try:
        if IS_WINDOWS:
            output = subprocess.run(["tasklist", "/fi", "imagename eq Balatro.exe", "/fo", "csv", "/nh"],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
            return "balatro.exe" in output.lower()
        result = subprocess.run(["pgrep", "-f", GAME_PATTERN], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
    except OSError:
        log.warn("无法列出进程, 按游戏正在运行处理")
        return True
    return result.returncode == 0


def running_commands():
    """正在运行的合成脚本的命令行, 用于判断某个合成脚本是否正在执行. 只读."""
    try:
        if IS_WINDOWS:
            # tasklist 看不到命令行, 用 PowerShell 取 cmd.exe 的命令行.
            query = ("Get-CimInstance Win32_Process -Filter \"Name='cmd.exe'\" | "
                     "ForEach-Object { $_.CommandLine }")
            output = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", query],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
            return [line for line in output.splitlines() if ".post.cmd" in line]
        output = subprocess.run(["pgrep", "-lf", r"\.post\.sh"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True).stdout
    except OSError:
        log.warn("无法列出进程, 不检查合成脚本是否正在执行")
        return []
    return output.splitlines()


def size_of(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def human(n):
    if n < 1024:
        return "%d B" % n
    for unit in ("KB", "MB", "GB"):
        n /= 1024.0
        if n < 1024 or unit == "GB":
            return "%.1f %s" % (n, unit)


def scan(directory):
    """按局收集残留的中间文件. 返回 {键: {suffix: path}}.

    键是这一局相对录像目录的路径: 每局一个文件夹时是文件夹名, 旧版平铺时是文件名前缀 (stem).
    两种布局都扫: 文件夹里的文件, 与直接放在录像目录根下的文件.
    """
    runs = {}
    for name in sorted(os.listdir(directory)):
        folder = os.path.join(directory, name)
        if os.path.isdir(folder):
            for inner in sorted(os.listdir(folder)):
                for suffix in SUFFIXES:
                    if inner.endswith(suffix) and len(inner) > len(suffix):
                        key = name + "/" + inner[: -len(suffix)]
                        runs.setdefault(key, {})[suffix] = os.path.join(folder, inner)
                        break
        else:
            for suffix in SUFFIXES:
                if name.endswith(suffix) and len(name) > len(suffix):
                    runs.setdefault(name[: -len(suffix)], {})[suffix] = folder
                    break
    return runs


def script_of(files):
    """这一局的合成脚本 (.post.sh 或 Windows 的 .post.cmd), 没有时返回 None."""
    return files.get(".post.sh") or files.get(".post.cmd")


def display_name(key):
    """给人看的局名. 每局一个文件夹时 key 是 "<folder>/<stem>", 两者同名时只显示一次."""
    if "/" in key:
        folder, stem = key.split("/", 1)
        return folder if folder == stem else key
    return key


def script_kind(path):
    """草稿 (draft) 还是局末 (final) 脚本, 旧版本生成的脚本没有标记时返回 None."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            head = f.read(512)
    except OSError:
        return None
    for kind in ("draft", "final"):
        # sh 版是 "# bb-post: ...", 批处理版是 "rem bb-post: ..."
        if "# bb-post: " + kind in head or "rem bb-post: " + kind in head:
            return kind
    return None


def script_matches(path, base):
    """脚本里的路径是否就是这个目录下的文件 (录像目录被移动过时不是).

    引号写法与 mods/bbreplay/record/post.lua 一致: sh 版用单引号; 批处理版用双引号, 反斜杠, % 写成 %%.
    """
    video = base + ".video.mp4"
    if path.endswith(".post.cmd"):
        needle = '"' + video.replace("/", "\\").replace("%", "%%") + '"'
    else:
        needle = "'" + video + "'"
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return needle in f.read()
    except OSError:
        return False


def classify(stem, files, directory, ctx):
    """返回 (状态, 说明). 状态: active, done, broken, recover."""
    base = os.path.join(directory, stem)
    script = script_of(files)
    if script and any(script in line for line in ctx["commands"]):
        return "active", "合成脚本正在执行"
    if ctx["game"]:
        latest = max(os.path.getmtime(p) for p in list(files.values()) + [base + ".json"]
                     if os.path.exists(p))
        if ctx["now"] - latest < ctx["idle"]:
            return "active", "游戏在运行, 中间文件 %.0f 秒前还在变化, 可能正在录制" % (ctx["now"] - latest)
    if size_of(base + "-full.mp4") > 0:
        return "done", "已有 -full.mp4, 残留的是清理失败或保留方式为 keep 留下的中间文件"
    if size_of(base + ".video.mp4") == 0:
        return "broken", "没有画面 (.video.mp4 缺失或为空), 无法合成"
    return "recover", None


def fallback_full(ffmpeg, base, verbose):
    """没有可用脚本时, 按 post.lua 的规则只合成 -full.mp4. 先写临时文件, 成功后再改名."""
    video = base + ".video.mp4"
    pcm = base + ".pcm"
    out = base + "-full.mp4"
    tmp = base + "-full.recover.mp4"
    cmd = [ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-i", video]
    if size_of(pcm) > 0:
        cmd += ["-f", "s16le", "-ar", "44100", "-ac", "2", "-i", pcm,
                "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k",
                # 崩溃后声音通常比画面长 (画面按约 2 秒的分片落盘), 按短的一方截齐
                "-shortest"]
    else:
        cmd += ["-c", "copy"]
    cmd += ["-movflags", "+faststart", "-f", "mp4", tmp]
    if verbose:
        log.debug("执行: %s" % " ".join(cmd))
    result = subprocess.run(cmd, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0 or size_of(tmp) == 0:
        if result.stderr:
            log.warn(result.stderr.strip())
        if os.path.exists(tmp):
            os.remove(tmp)
        return False
    os.replace(tmp, out)
    return True


def recover(stem, files, directory, ffmpeg, args):
    base = os.path.join(directory, stem)
    script = script_of(files)
    started = time.time()
    is_cmd = bool(script) and script.endswith(".post.cmd")
    if script and is_cmd and not IS_WINDOWS:
        log.warn("%s: 合成脚本是 Windows 的 .post.cmd, 这里不能运行, 改为只合成 -full.mp4" % display_name(stem))
        script = None
    if script and script_matches(script, base):
        kind = script_kind(script)
        cmd = ["cmd", "/d", "/c", script] if is_cmd else ["/bin/sh", script]
        # 草稿脚本带 --clean 才删中间文件; 局末脚本 (或旧版本脚本) 成功后总是删除
        if kind == "draft" and args.clean:
            cmd.append("--clean")
        log.info("%s: 执行 %s 脚本" % (display_name(stem), kind or "旧版"))
        code = subprocess.run(cmd, stdin=subprocess.DEVNULL).returncode
        # 批处理的局末脚本删掉自身后退出码不可靠, 以产物为准.
        ok = (is_cmd and kind == "final") or code == 0
        ok = ok and size_of(base + "-full.mp4") > 0
    else:
        if ffmpeg is None:
            log.warn("%s: 没有可用的合成脚本, 也找不到 ffmpeg, 跳过" % display_name(stem))
            return False
        why = "脚本里的路径不在这个目录 (目录被移动过)" if script else "没有合成脚本"
        log.info("%s: %s, 只合成 -full.mp4" % (display_name(stem), why))
        ok = fallback_full(ffmpeg, base, args.verbose)
        if ok and args.clean:
            for suffix in SUFFIXES:
                path = base + suffix
                if os.path.exists(path):
                    os.remove(path)
    elapsed = time.time() - started
    if ok:
        log.info("%s: 完成, -full.mp4 %s, 用时 %.1f 秒"
                 % (display_name(stem), human(size_of(base + "-full.mp4")), elapsed))
    else:
        log.warn("%s: 合成失败, 中间文件保留, ffmpeg 的报错见 %s.ffmpeg.txt"
                 % (display_name(stem), base))
    return ok


def main():
    args = parse_args()
    log.set_verbose(args.verbose)
    directory = os.path.abspath(args.dir)
    if not os.path.isdir(directory):
        log.die("录像目录不存在: %s" % directory)
    if args.clean and not args.run:
        log.die("--clean 需要和 --run 一起用")

    stems = scan(directory)
    if not stems:
        log.info("%s 里没有残留的中间文件" % directory)
        return 0
    ctx = {"game": game_running(), "commands": running_commands(), "now": time.time(), "idle": args.idle}
    if ctx["game"]:
        log.info("游戏正在运行, 最近 %.0f 秒内还在变化的局会跳过" % args.idle)

    todo = []
    for stem, files in stems.items():
        status, note = classify(stem, files, directory, ctx)
        parts = ", ".join("%s %s" % (suffix, human(size_of(path))) for suffix, path in sorted(files.items()))
        kind = script_kind(script_of(files)) if script_of(files) else None
        label = {"active": "跳过", "done": "已合成", "broken": "无法合成", "recover": "待合成"}[status]
        log.info("[%s] %s: %s%s%s" % (label, display_name(stem), parts, " (%s 脚本)" % kind if kind else "",
                                      ", " + note if note else ""))
        if status == "recover":
            todo.append((stem, files))

    if not todo:
        log.info("没有需要补做合成的局")
        return 0
    if not args.run:
        log.info("%d 局待合成, 加 --run 执行" % len(todo))
        return 0

    ffmpeg = find_ffmpeg(args.ffmpeg)
    failed = 0
    for i, (stem, files) in enumerate(todo, 1):
        log.info("(%d/%d) %s" % (i, len(todo), display_name(stem)))
        if not recover(stem, files, directory, ffmpeg, args):
            failed += 1
    log.info("完成 %d 局, 失败 %d 局" % (len(todo) - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
