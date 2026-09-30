# macOS 平台的打包入口.
python := if os_family() == "windows" { "python" } else { "python3" }

# 打包 macOS 应用包, 产出 dist/macos/Balatro.app.
dist:
    {{ python }} scripts/package_macos.py

# 打包并运行, 便于马上验证产物.
run: dist
    open dist/macos/Balatro.app

# 用指定 png 作为应用图标打包, 例如: just macos icon 图标.png
icon path:
    {{ python }} scripts/package_macos.py --icon {{ path }}

# 打包时沿用 LÖVE 自带图标, 不生成自定义图标.
default-icon:
    {{ python }} scripts/package_macos.py --no-icon
