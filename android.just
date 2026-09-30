# Android 平台的打包入口.
python := if os_family() == "windows" { "python" } else { "python3" }

# 打包 Android 安装包, 产出 dist/android/Balatro-<版本>.apk.
dist:
    {{ python }} scripts/package_android.py

# 打包并安装到已连接的设备.
install:
    {{ python }} scripts/package_android.py --install

# just android dist-modded [mod 目录]
# 打包带 mod 的安装包, 包名与原版不同, 可同时安装.
dist-modded mods="mods":
    {{ python }} scripts/package_android.py --mods {{ mods }}

# just android install-modded [mod 目录]
# 打包带 mod 的安装包并安装到已连接的设备.
install-modded mods="mods":
    {{ python }} scripts/package_android.py --mods {{ mods }} --install

# 用自定义包名打包, 例如: just android package com.foo.bar
package name:
    {{ python }} scripts/package_android.py --package {{ name }}

# 用指定密钥打包, 例如: just android keystore 我的.jks
keystore path:
    {{ python }} scripts/package_android.py --keystore {{ path }}
