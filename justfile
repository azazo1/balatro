[private]
default:
    @just --list

alias dist := package-macos

# 把 game/ 中的游戏资源打包为 dist/Balatro.app, 使用 assets/icon.png 作为应用图标.
package-macos:
    scripts/package-macos.sh --icon assets/icon.png

# 用指定 png 作为应用图标打包, 例如: just package-macos-icon icon.png
package-macos-icon icon:
    scripts/package-macos.sh --icon {{ icon }}

# 打包时不使用自定义图标, 沿用 LÖVE 自带的图标.
package-macos-default-icon:
    scripts/package-macos.sh

# 把 game/ 装进官方 LÖVE Android 运行时并签名, 产出 dist/Balatro-<版本>.apk.
# 不需要 NDK 与 gradle, 也无需编译原生库.
package-android:
    scripts/package-android.sh

# 覆盖包名打包, 例如: just package-android-package com.foo.bar
package-android-package name:
    scripts/package-android.sh --package {{ name }}

# 用指定密钥打包, 例如: just package-android-keystore 我的.jks
package-android-keystore keystore:
    scripts/package-android.sh --keystore {{ keystore }}

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

# 删除打包产物 dist/.
clean:
    rm -rf dist
