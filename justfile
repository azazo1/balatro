[private]
default:
    @just --list

alias dist := package-macos

# 跨平台的 python 调用方式: Windows 上是 python, 其余平台是 python3
python := if os_family() == "windows" { "python" } else { "python3" }

# 把 game/ 中的游戏资源打包为 dist/macos/Balatro.app, 默认使用 assets/icon.png 作为图标.
package-macos:
    {{ python }} scripts/package_macos.py

# 用指定 png 作为应用图标打包, 例如: just package-macos-icon icon.png
package-macos-icon icon:
    {{ python }} scripts/package_macos.py --icon {{ icon }}

# 打包时不使用自定义图标, 沿用 LÖVE 自带的图标.
package-macos-default-icon:
    {{ python }} scripts/package_macos.py --no-icon

# 打包 Android 安装包, 产出 dist/android/Balatro-<版本>.apk.
package-android:
    {{ python }} scripts/package_android.py

# 用 LuaJIT 校验 game/ 下所有 lua 脚本的语法.
check-lua:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    for f in $(find game -name '*.lua' | sort); do
        if ! luajit -e "assert(loadfile('$f'))" 2>&1; then
            echo "语法错误: $f"
            failed=1
        fi
    done
    if [ "$failed" -eq 0 ]; then
        echo "game/ 下 lua 脚本语法校验通过"
    fi
    exit "$failed"

# 校验打包脚本的 python 语法.
check-scripts:
    {{ python }} -m compileall -q scripts

# 删除打包产物 dist/.
clean:
    {{ python }} -c "import shutil; shutil.rmtree('dist', ignore_errors=True)"
