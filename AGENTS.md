# 仓库约定

## 版本号

版本号写作 `<上游版本>-<仓库版本>`, 例如 `1.0.1n-0.1.0`.

- 上游版本: 游戏自身版本, 取自 `game/version.jkr` 首行去掉 `-FULL`.
- 仓库版本: 本仓库重打包的版本, 语义化递增. 上游版本更新时从 `0.1.0` 重新计数.

同一份游戏会被重打包多次, 因此两者都要有: 只写上游版本则一个版本只能发布一次.

发布打 tag, 说明写在 `docs/changelog/<版本>.md`, 并用作 annotated tag 的正文:

```shell
git tag -a "v1.0.1n-0.1.0" --cleanup=verbatim -F "docs/changelog/1.0.1n-0.1.0.md"
git push origin main
git push origin "v1.0.1n-0.1.0"
```

CI 对 tag 做三项检查, 任一不过都不创建 release: tag 格式, 上游版本与 `game/version.jkr`
一致, tag 正文与说明文件逐字节一致.

日常构建不带版本参数, 自动得到 `<上游版本>+<短哈希>`, 与发布版本区分.

Android 的 `versionCode` 由两段版本折算, 保证单调递增, 否则无法覆盖安装.
上游三段各占两位十进制, 仓库三段各占一位, 例如 `1.0.1n-0.1.0` 得 `10001010`.

### 禁止

- 不要改 `game/version.jkr`, 它属于上游资源.
- 不要用裸上游版本作 tag, `v1.0.1n` 会被 CI 拒绝.
- 不要绕过版本校验.

## agent 游玩

被要求玩游戏时, 启动和调用一律用 just, 接口说明见 `docs/agent-api.md`:

1. 后台运行 `just macos run-agent` 启动游戏. 默认正常速度, 并按局录像到 `recordings/`, 游戏日志也在那里.
2. `just agent-wait` 等开场动画播完进入主菜单.
3. 每一步操作用 `just agent-call <方法> '<参数 JSON>'`, 并在参数里带简短的 `reason` 说明决策.

- 不要直接运行 `Balatro-Modded.app` 里的 love, 也不要自己设置 `BALATROBOT_*` 等环境变量.
- 不要开加速 (`run-agent skip 1`), user 明确要求时才开.
- 每次返回都看 `overlay` 字段: `unlock` 时调用 `continue` 关掉解锁通知; `win` 时已经打赢,
  按 user 的要求调用 `endless` 继续或 `menu` 回主菜单.
