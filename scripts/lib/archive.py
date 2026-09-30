"""zip 解包与打包.

标准库的 zipfile 不还原符号链接与可执行位, 而 macOS 的 .app 内部大量使用符号链接
(Frameworks/*.framework/Versions/Current), 少了它们应用无法启动, 因此这里自行还原.

zip 里符号链接的判定方式是external_attr 的高 16 位为 unix 模式, 且文件类型为链接;
其数据内容就是链接目标.
"""
import io
import os
import stat
import zipfile

from . import log

S_IFLNK = 0o120000
S_IFMT = 0o170000


def _mode(info):
    """从 zip 条目取出 unix 权限位, 取不到时返回 None."""
    mode = info.external_attr >> 16
    return mode if mode else None


def is_symlink(info):
    mode = _mode(info)
    return bool(mode) and (mode & S_IFMT) == S_IFLNK


def extract_zip(zip_path, dest_dir):
    """解包 zip, 还原符号链接与可执行位, 返回解出的条目数."""
    count = 0
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            target = os.path.join(dest_dir, info.filename)
            # 防止归档里的路径逃逸到目标目录之外.
            real = os.path.realpath(os.path.dirname(target))
            if not real.startswith(os.path.realpath(dest_dir)):
                log.die("归档条目路径异常: %s" % info.filename)

            if info.is_dir():
                os.makedirs(target, exist_ok=True)
                count += 1
                continue

            os.makedirs(os.path.dirname(target), exist_ok=True)
            if is_symlink(info):
                link_target = zf.read(info).decode("utf-8", errors="surrogateescape")
                if os.path.lexists(target):
                    os.remove(target)
                try:
                    os.symlink(link_target, target)
                except (OSError, NotImplementedError):
                    # 没有创建符号链接的权限时退化为复制目标内容, 至少保留结构.
                    log.warn("无法创建符号链接 %s, 改为复制" % info.filename)
                    try:
                        with zf.open(info) as src, open(target, "wb") as dst:
                            dst.write(src.read())
                    except OSError:
                        pass
            else:
                with zf.open(info) as src, open(target, "wb") as dst:
                    dst.write(src.read())
                mode = _mode(info)
                if mode:
                    os.chmod(target, mode & 0o777)
            count += 1
    return count


def zip_dir(src_dir, out_path, deflate=True):
    """把一个目录打包为 zip, 保持相对结构与可执行位."""
    method = zipfile.ZIP_DEFLATED if deflate else zipfile.ZIP_STORED
    count = 0
    with zipfile.ZipFile(out_path, "w", method, compresslevel=9 if deflate else None) as zf:
        for dirpath, dirnames, filenames in os.walk(src_dir):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                if os.path.islink(full):
                    continue
                rel = os.path.relpath(full, src_dir).replace(os.sep, "/")
                info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = method
                info.external_attr = (os.stat(full).st_mode & 0o777) << 16
                with open(full, "rb") as fh:
                    zf.writestr(info, fh.read())
                count += 1
    return count


def fuse_executable(base_exe, payload, out_exe, required=("main.lua", "conf.lua")):
    """把载荷直接追加到可执行文件末尾, 得到融合发行版.

    Windows 版就是这个原理: LÖVE 会用 PhysicsFS 从自身文件尾部的 zip 读取游戏,
    因此不需要额外的游戏文件.

    融合之后立刻回读尾部并当作 zip 打开, 确认 LÖVE 能在运行时找到游戏;
    这一步能挡掉"文件写坏但看起来正常"的情况.
    """
    base_size = os.path.getsize(base_exe)
    with open(out_exe, "wb") as out:
        for path in (base_exe, payload):
            with open(path, "rb") as fh:
                while True:
                    block = fh.read(1024 * 1024)
                    if not block:
                        break
                    out.write(block)

    with open(out_exe, "rb") as fh:
        fh.seek(base_size)
        tail = fh.read()
    try:
        with zipfile.ZipFile(io.BytesIO(tail)) as zf:
            names = set(zf.namelist())
    except zipfile.BadZipFile:
        raise ValueError("融合后的文件尾部不是有效的 zip: %s" % out_exe)
    for name in required:
        if name not in names:
            raise ValueError("融合后的游戏载荷缺少 %s" % name)
    return os.path.getsize(out_exe)


def size_of(path):
    return os.path.getsize(path)


def dir_size(path):
    """统计目录内真实文件的总大小, 跳过符号链接以免重复计数."""
    total = 0
    for dirpath, _dirnames, filenames in os.walk(path):
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            total += os.path.getsize(full)
    return total


def human_size(num):
    for unit in ("B", "KB", "MB", "GB"):
        if num < 1024 or unit == "GB":
            return "%.1f %s" % (num, unit) if unit != "B" else "%d B" % num
        num /= 1024.0


def make_executable(path):
    mode = os.stat(path).st_mode
    os.chmod(path, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
