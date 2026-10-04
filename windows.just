# Windows 平台的打包入口.
python := if os_family() == "windows" { "python" } else { "python3" }
# 这个模块**可以**在 macOS 与 Linux 上调用 (打包脚本只做 zip, 没有平台守卫),
# 所以内联脚本不能用 `set script-interpreter := ['python']` 写死: 那在 macOS 上会找不到 python.
# 用 shebang 取平台对应的解释器.
python_shebang := if os_family() == "windows" { "python" } else { "/usr/bin/env python3" }

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

# just windows run-agent [on|off] [fast]
# 打包并启动外部 agent, 使用独立存档 Balatro-Agent, 默认正常速度, 录像与日志写入 recordings/.
run-agent record="on" fast="0":
    {{ python }} scripts/run_agent.py windows {{ record }} {{ fast }}

# just windows fix-acl [产物目录]
# 把目录里产物的完整性级别修回 Medium, 去掉打包环境留下的 Low 标志 (目录自身不动).
# 沙箱内的进程抬不动这个标志, 需要在沙箱外的终端里执行.
fix-acl path="dist/windows":
    {{ python }} scripts/fix_acl.py --inside {{ path }}

# just windows recordings-recover [--run] [--clean] [录像目录]
# 扫描录像目录里崩溃后残留的中间文件并补做合成, 默认只列出,
# --run 执行, --clean 成功后删中间文件.
# 用脚本 recipe 而不是把参数拼进命令行: `{{ args }}` 是不加引号拼的, 路径里有空格时
# 会被拆成两个参数. [positional-arguments] 会把每个参数按原样放进 argv.
[positional-arguments]
recordings-recover *args:
    #!{{ python_shebang }}
    import sys
    sys.path.insert(0, {{ quote(justfile_directory() + "/scripts") }})
    from recordings_recover import main
    sys.exit(main(sys.argv[1:]))
