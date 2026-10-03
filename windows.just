# Windows 平台的打包入口.
python := if os_family() == "windows" { "python" } else { "python3" }

[private]
default:
    @just --justfile {{ quote(source_file()) }} --list

# 打包 Windows 免安装版, 产出 dist/windows/Balatro-<版本>-win64.zip.
dist:
    {{ python }} scripts/package_windows.py

# 额外产出带控制台窗口的 exe, 便于查看 print 输出.
console:
    {{ python }} scripts/package_windows.py --console

# just windows dist-modded [mod 目录]
# 打包带 mod 的免安装版, 同时产出带控制台的 exe 便于看日志.
dist-modded mods="mods":
    {{ python }} scripts/package_windows.py --mods {{ mods }} --console

# just windows fix-acl [产物目录]
# 把目录里产物的完整性级别修回 Medium, 去掉打包环境留下的 Low 标志 (目录自身不动).
# 沙箱内的进程抬不动这个标志, 需要在沙箱外的终端里执行.
fix-acl path="dist/windows":
    {{ python }} scripts/fix_acl.py --inside {{ path }}

# just windows recordings-recover [--run] [--clean] [录像目录]
# 扫描录像目录里崩溃后残留的中间文件并补做合成, 默认只列出,
# --run 执行, --clean 成功后删中间文件.
recordings-recover *args:
    {{ python }} scripts/recordings_recover.py {{ args }}
