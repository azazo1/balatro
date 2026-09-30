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
