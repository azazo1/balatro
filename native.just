# 原生库 native/bbnet (网络与录像用的颜色转换) 的编译与测试.
python := if os_family() == "windows" { "python" } else { "python3" }

[private]
default:
    @just --justfile {{ quote(source_file()) }} --list

# 运行原生库的单元测试与集成测试 (本地起 TCP 服务, 不联网).
test:
    {{ python }} scripts/build_native.py test

# just native build macos|windows|android [abi...]
# 编译原生库到 dist/native/<平台>/ (android 默认 arm64-v8a). 打 modded 包时会自动编译, 一般不用单独跑.
build platform *abis:
    {{ python }} scripts/build_native.py build {{ platform }} {{ abis }}
