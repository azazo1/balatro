# Windows 平台的打包入口.
python := if os_family() == "windows" { "python" } else { "python3" }

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
