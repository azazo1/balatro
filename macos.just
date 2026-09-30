# macOS 平台的打包入口.
python := if os_family() == "windows" { "python" } else { "python3" }

# 打包 macOS 应用包, 产出 dist/macos/Balatro.app.
dist:
    {{ python }} scripts/package_macos.py

# 打包并运行, 便于马上验证产物.
run: dist
    open dist/macos/Balatro.app

# just macos dist-modded [mod 目录]
# 打包带 mod 的应用, 产出 dist/macos/Balatro-Modded.app, 与原版可同时安装.
dist-modded mods="mods":
    {{ python }} scripts/package_macos.py --mods {{ mods }}

# 在终端里运行带 mod 的应用, 便于直接看到日志.
run-modded: dist-modded
    dist/macos/Balatro-Modded.app/Contents/MacOS/love

# just macos run-agent [fast]
# 打包带 mod 的应用并开启 agent 接口运行, 使用独立存档目录 Balatro-Agent, fast=1 时 10 倍速.
run-agent fast="0": dist-modded
    BALATROBOT_ENABLE=1 BALATROBOT_FAST={{ fast }} BALATRO_SAVE_IDENTITY=Balatro-Agent dist/macos/Balatro-Modded.app/Contents/MacOS/love

# 用指定 png 作为应用图标打包, 例如: just macos icon 图标.png
icon path:
    {{ python }} scripts/package_macos.py --icon {{ path }}

# 打包时沿用 LÖVE 自带图标, 不生成自定义图标.
default-icon:
    {{ python }} scripts/package_macos.py --no-icon
