# 原生库 (native/bbnet) 的编译与测试.
# bbnet 同时提供网络 (HTTP/TLS/SSE) 与录像用的颜色转换, 所以这里不需要按库再分一层.
python := if os_family() == "windows" { "python" } else { "python3" }

# 跑原生库的单元测试与集成测试 (颜色转换的用例也在其中, 本地起 TCP 服务, 不联网).
test:
    {{ python }} scripts/build_native.py test

# just native build macos
# 编译 macOS 版并直接放进 mod 的原生目录 (随 mod 树进各平台安装包).
build platform *abis:
    {{ python }} scripts/build_native.py build {{ platform }} {{ abis }}
