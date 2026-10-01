"""版本号解析与派生.

项目里同时存在两个版本号:

- 上游版本: 游戏自身的版本, 取自 `game/version.jkr` 首行, 例如 `1.0.1n`.
- 仓库版本: 本仓库重打包的版本, 只由发布 tag 决定, 例如 `0.1.0`.

发布版本的完整形式是 `<上游>-<仓库>`, 例如 `1.0.1n-0.1.0`. 这样同一份游戏被重打包多次时
各自有版本号, tag 不会互相占用; 只写上游版本则只能发布一次.

非发布构建使用 `<上游>+<短哈希>`, 例如 `1.0.1n+32cfe92`, 用于区分同一上游版本下的不同提交,
并与发布版本在形式上明确区分开.
"""
import os
import re

from . import layout, log

# 仓库版本恰好三段, 便于折算成 Android 的整数版本号.
_RELEASE_RE = re.compile(r"^([0-9]+\.[0-9]+(?:\.[0-9]+)?[A-Za-z]*)-([0-9]+)\.([0-9]+)\.([0-9]+)$")
# 只含上游版本时的形式, 用于解析非发布构建.
_UPSTREAM_RE = re.compile(r"^[0-9]+\.[0-9]+(?:\.[0-9]+)?[A-Za-z]*$")

# Android 的 versionCode 必须单调递增, 这里给各段分配固定的十进制位, 共 9 位, 不会超出上限.
# 上游 major/minor 各一位, patch 两位, 字母后缀两位 (无后缀为 0, a=1 ... z=26),
# 仓库 major/minor/patch 各一位. 字母后缀必须参与折算: 上游按 1.0.1n -> 1.0.1o 这样递增.
_GAME_MAJOR_SCALE = 100_000_000
_GAME_MINOR_SCALE = 10_000_000
_GAME_PATCH_SCALE = 100_000
_GAME_LETTER_SCALE = 1_000
_REPO_MAJOR_SCALE = 100
_REPO_MINOR_SCALE = 10
_REPO_PATCH_SCALE = 1
# Android 对 versionCode 的上限是 2^31 - 1.
_MAX_VERSION_CODE = 2_100_000_000


def upstream_version():
    """读取游戏自身的版本, 去掉发行后缀.

    `game/version.jkr` 首行为完整版本 (如 `1.0.1n-FULL`), 第二行为基础版本 (如 `1.0.1n`).
    该文件随仓库分发, 因此任何时候都能读到, 不需要靠构建参数注入.
    """
    path = os.path.join(layout.GAME_DIR, "version.jkr")
    try:
        with open(path, encoding="utf-8") as fh:
            first = fh.readline().strip()
    except OSError:
        log.die("无法读取版本文件: %s" % path)
    return first[:-5] if first.endswith("-FULL") else first


def _git_short_hash():
    """取当前提交的 7 位短哈希, 取不到时返回 None."""
    # quiet 让这次探测不写日志: 它对使用者没有意义, 只是版本号的一部分.
    output = log.run(["git", "rev-parse", "--short=7", "HEAD"],
                     check=False, capture=True, quiet=True)
    text = (output or "").strip()
    return text if re.fullmatch(r"[0-9a-f]{7,40}", text) else None


def build_version():
    """返回本次构建要写入产物的版本号.

    CI 通过 `PROJECT_BUILD_VERSION` 注入, 本地构建则自动拼出 `<上游>+<短哈希>`,
    以便与发布版本区分.
    """
    injected = os.environ.get("PROJECT_BUILD_VERSION", "").strip()
    if injected:
        return injected[1:] if injected.startswith("v") else injected

    upstream = upstream_version()
    short = _git_short_hash()
    return "%s+%s" % (upstream, short) if short else "%s+local" % upstream


def split(version):
    """把版本串拆成 (上游版本, 仓库版本), 非发布形式下仓库版本为 None.

    会忽略 `+` 之后的构建元数据, 因此对 `1.0.1n+32cfe92` 也能正确取到上游版本.
    """
    text = version.split("+", 1)[0]
    match = _RELEASE_RE.match(text)
    if match:
        return match.group(1), "%s.%s.%s" % (match.group(2), match.group(3), match.group(4))
    return text, None


def validate_release_version(version):
    """校验发布版本串的格式, 返回 (上游版本, 仓库版本).

    格式不对时直接报错, 因为 tag 一旦推上去就不容易更改.
    """
    match = _RELEASE_RE.match(version)
    if not match:
        log.die("发布版本格式不正确: %s\n应为 <上游版本>-<仓库版本>, 例如 1.0.1n-0.1.0" % version)
    repo = "%s.%s.%s" % (match.group(2), match.group(3), match.group(4))
    return match.group(1), repo


def _numbers(text, count):
    """把 `1.0.1n` 这类版本串取前 count 段数字, 不足处补 0."""
    digits = []
    for part in text.split("."):
        num = ""
        for ch in part:
            if ch.isdigit():
                num += ch
            else:
                break
        digits.append(int(num) if num else 0)
    while len(digits) < count:
        digits.append(0)
    return digits[:count]


def _letter(upstream):
    """取上游版本末尾的字母后缀序号: 无后缀为 0, a=1 ... z=26, 多于一个字母时报错."""
    suffix = re.search(r"[A-Za-z]*$", upstream).group(0).lower()
    if len(suffix) > 1:
        log.die("上游版本的字母后缀只支持一个字母: %s" % upstream)
    return ord(suffix) - ord("a") + 1 if suffix else 0


def android_version_code(version=None):
    """把版本串折算成 Android 的整数 versionCode.

    必须单调递增, 否则同一设备上无法覆盖安装. 因此上游各段, 上游字母后缀与仓库三段各占固定十进制位:

        1.0.1n        -> 100114000
        1.0.1n-0.1.0  -> 100114010
        1.0.1n-0.2.0  -> 100114020
        1.0.1o-0.1.0  -> 100115010
        1.0.2-0.1.0   -> 100200010

    上游升补丁, 升字母后缀或仓库升版本都会让结果变大, 单调性成立. 无后缀排在有后缀之前,
    即 1.0.1 < 1.0.1a, 与上游的发布顺序一致.
    """
    text = version or build_version()
    upstream, repo = split(text)
    if not _UPSTREAM_RE.match(upstream):
        log.die("上游版本格式不正确: %s" % upstream)

    g_major, g_minor, g_patch = _numbers(upstream, 3)
    if g_major > 9 or g_minor > 9 or g_patch > 99:
        log.die("上游版本 major/minor 需在 9 以内, patch 需在 99 以内: %s" % upstream)
    g_letter = _letter(upstream)

    r_major = r_minor = r_patch = 0
    if repo:
        r_major, r_minor, r_patch = _numbers(repo, 3)
        if r_major > 9 or r_minor > 9 or r_patch > 9:
            log.die("仓库版本各段需在 9 以内: %s" % repo)

    code = (g_major * _GAME_MAJOR_SCALE + g_minor * _GAME_MINOR_SCALE + g_patch * _GAME_PATCH_SCALE
            + g_letter * _GAME_LETTER_SCALE + r_major * _REPO_MAJOR_SCALE + r_minor * _REPO_MINOR_SCALE + r_patch * _REPO_PATCH_SCALE)
    if code > _MAX_VERSION_CODE:
        log.die("折算出的 versionCode 超出上限: %d" % code)
    return code
