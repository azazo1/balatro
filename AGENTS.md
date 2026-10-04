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
上游 major/minor 各一位, patch 两位, 字母后缀两位 (a=1 ... z=26), 仓库三段各占一位,
例如 `1.0.1o-0.1.0` 得 `100115010`. 详见 README 的版本号一节.

### 禁止

- 不要改 `game/version.jkr`, 它属于上游资源.
- 不要用裸上游版本作 tag, `v1.0.1n` 会被 CI 拒绝.
- 不要绕过版本校验.

## agent 游玩

被要求玩游戏时, 启动和调用一律用 just, 接口说明见 `docs/agent-api.md`:

1. 后台运行 `just windows run-agent` (Windows) 或 `just macos run-agent` (macOS) 启动游戏.
   默认正常速度, 并按局录像到 `recordings/`, 游戏日志也在那里.
2. `just agent-wait` 等开场动画播完进入主菜单.
3. 每一步操作用 `just agent-call <方法> '<参数 JSON>'`.
4. 边玩边解说: 这一步的解说写进操作参数的 `reason` (先显示, 读完后操作才生效), 不要再另发 `notify` 重复;
   `notify` 只用于不跟操作的观察, 对比和复盘.
   观众只看得到画面和消息, 具体要求见 `docs/agent-commentary.md`, 开局前先读.

- 不要直接运行 `Balatro-Modded.app` 里的 love, 也不要自己设置 `BALATROBOT_*` 等环境变量.
- 不要开加速 (`run-agent on 1`), user 明确要求时才开.
- 每次返回都看 `overlay` 字段: `unlock` 时调用 `continue` 关掉解锁通知; `win` 时已经打赢,
  按 user 的要求调用 `endless` 继续或 `menu` 回主菜单.
- 规则和卡牌效果拿不准时, 用 `lookup` 查卡牌, 用 `docs_search`/`docs_read` 查规则手册, 不要凭印象猜.

### 在引擎里对局

不启动游戏, 改用 `just play` 让 agent 在引擎里逐步打完一局 (不需要图形环境), 详细用法见
`engine/README.md` 的 "让 agent 玩" 一节:

1. `just play step --seed <种子> --deck <牌组> --stake <赌注> --actions <动作文件>` 打印当前局面,
   含牌的中文名与效果, 盲注目标与跳过奖励, 以及会变的值 (每回合认的花色点数, 小丑成长值,
   摸牌堆分布).
2. 每步用 `--do '<动作 JSON>'`; 动作先执行, 成功了才写进动作文件, 所以被拒的动作不会污染历史.
3. `--emit <回放文件>` 把这局导出成游戏能回放的文件 (每步带引擎预测的摘要), 再交给
   `just macos replay <回放文件> tight` 逐步对拍 —— 游戏是裁判, 退出码 0 才算全过.
4. 规则与卡牌拿不准时用 `just play lookup` / `docs` / `search`, 提示词 (`just play prompt`) 里
   有规则要点.

- 会变的值 (认的花色点数, 成长值, 待办目标) 一律现查, 不要沿用上一回合的印象 —— 引擎与真游戏
  给的局内信息是对齐的, 猜就会输在信息差上.

## 开发

- agent mod 的纯逻辑改动后运行 `just test-agent`, 原生库 `native/bbnet` 改动后运行 `just native test`.
- 内置 agent 的设计与进度见 `docs/builtin-agent.md`, 其中 loop 与 bbnet, 录像, 回放, Android 各有分文档
  (`docs/agent-loop.md`, `docs/recording.md`, `docs/replay.md`, `docs/android.md`).
- 回放有两种入口: 主菜单 选项 -> 回放 (游戏内, 不需要环境变量), 以及 `just macos replay <回放文件>`
  (命令行, 按退出码结束). 两者共用 `mods/bbreplay/replay/` 下的播放器.
- mod 分四个: `bbcore` (端点, 弹窗拦截, 决策消息等公共部分), `balatrobot` (HTTP 接口与内置 agent),
  `bbreplay` (录像与回放), `bbdump` (把每步动作与完整状态追加写成 JSONL, 供离线分析与重写实现当基准).
  后三个只依赖 bbcore, 录像与回放用 `BB_CONTROL` 互斥, 见 `docs/modding.md` 的内置 mod 一节.
- macOS 沙箱内无法正常启动游戏.
- 主工作区追踪了大量二进制文件, 因此如果需要创建子工作区, 请使用稀疏工作区.
