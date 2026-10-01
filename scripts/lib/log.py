"""统一的日志与错误输出.

所有输出都走 stderr, 避免污染可能被管道消费的 stdout.
"""
import subprocess
import sys

# Windows 上输出被重定向到文件或管道时, Python 默认使用本地代码页 (如 cp1252):
# stdout 遇到中文会抛 UnicodeEncodeError, stderr 则会退化成 \uXXXX 转义, 两者都不理想.
# 这里统一改成 UTF-8, 让本机与 CI 的输出保持一致且可读.
for _stream in (sys.stdout, sys.stderr):
    reconfigure = getattr(_stream, "reconfigure", None)
    if reconfigure is not None:
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (ValueError, OSError):
            # 流已被替换或不支持重配置时保持原样, 不影响功能.
            pass

_prefix = "balatro"
_verbose = False


def set_prefix(name):
    """设置日志前缀, 通常是平台名."""
    global _prefix
    _prefix = name


def set_verbose(enabled):
    """开启后输出 debug 级别的细节日志."""
    global _verbose
    _verbose = bool(enabled)


def debug(message):
    if _verbose:
        print("[%s] 调试: %s" % (_prefix, message), file=sys.stderr, flush=True)


def info(message):
    print("[%s] %s" % (_prefix, message), file=sys.stderr, flush=True)


def warn(message):
    print("[%s] 警告: %s" % (_prefix, message), file=sys.stderr, flush=True)


def die(message):
    """打印错误并终止进程."""
    print("[%s] 错误: %s" % (_prefix, message), file=sys.stderr, flush=True)
    raise SystemExit(1)


def run(cmd, check=True, capture=False, quiet=False, cwd=None):
    """执行外部命令.

    capture 为真时返回捕获的输出文本, 否则返回 None. check 为真时非零退出码会抛错.
    quiet 为真时丢弃子进程的输出. cwd 指定工作目录 (有些工具按当前目录找配置文件).
    """
    if not quiet:
        info("执行: %s%s" % (" ".join(cmd), (" (在 %s)" % cwd) if cwd else ""))
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE if (capture or quiet) else None,
            stderr=subprocess.STDOUT if (capture or quiet) else None,
            text=True,
            cwd=cwd,
        )
    except FileNotFoundError:
        if check:
            die("找不到命令: %s" % cmd[0])
        return None
    output = result.stdout or ""
    if check and result.returncode != 0:
        if output:
            print(output, file=sys.stderr, flush=True)
        die("命令失败 (退出码 %d): %s" % (result.returncode, " ".join(cmd)))
    return output


def have(command):
    """判断命令是否存在于 PATH."""
    from shutil import which
    return which(command) is not None
