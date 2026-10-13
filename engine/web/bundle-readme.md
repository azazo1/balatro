# Engine 综合包

这是 CLI, Python 绑定和 Web 调试台的统一发行包, 不需要源码或 Node.js.

## Web 调试台

启动 `bin/balatro-engine-web` (Windows 使用 `bin/balatro-engine-web.exe`), 然后打开
<http://127.0.0.1:12347>. 它会自动找到旁边的 `web/`.

- 默认 WASM 模式, 游戏规则在浏览器的 Worker 中本地运行.
- 页面右上角可切换 HTTP 模式, 规则在刚启动的本地服务内执行.
- 调试默认关闭. 历史回溯不会删除后续路线, 从旧节点操作会产生新分支.
- 自动存档属于此浏览器与此页面 Origin, 不是永久备份. 离开前建议下载会话文件.
- 文件导入会验证版本并重建全部分支. 经过状态修改的路径不能导出普通动作记录.

纯 WASM 部署只需把 `web/` 发布到普通静态 HTTP/HTTPS 服务. 没有 API 服务时不能选 HTTP 模式.
不支持直接双击 `web/index.html` 通过 `file://` 使用, Worker 与 WASM 需要 HTTP/HTTPS.
本包的 HTTP 服务只监听 loopback, 不用于公网托管或多用户服务.

## CLI

`bin/play --help` 查看种子, 配置, 动作文件与回放参数.
`bin/replay_check --help` 查看回放对拍入口. Windows 使用对应 `.exe` 文件.

## Python

安装 `python/` 中唯一的 `.whl` 后即可 `import balatro_engine`.
它是 abi3 扩展, 支持 Python 3.8 及以上. 用 `balatro_engine.build_version` 核对引擎版本.
macOS universal 包的 wheel 是真正的 universal2. Linux 包与构建环境的 glibc 基线一致,
不保证能在更旧的 Linux 发行版运行.

## 目录与验证

```text
bin/            play, replay_check, balatro-engine-web
python/         当前平台的 Python wheel
web/            React 页面, Worker, WASM
manifest.json   平台, 架构, 统一构建版本与每个文件的 SHA256
```

GitHub Release 的外层归档另有 SHA256SUMS. 内层 manifest 校验和在打包阶段已经回读验证.
