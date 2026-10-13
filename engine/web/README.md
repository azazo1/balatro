# Engine Web 调试台

React + TypeScript 页面, 支持本地 WASM 和本地 HTTP 两种计算模式.
它是对局调试工具, 不是 LÖVE 游戏窗口, 使用原版贴图但不含动画.
规则仍由 std-only 的 Rust engine 计算.

## 启动

在仓库根目录:

```shell
just engine-web
just engine-web --mode wasm
just engine-web-dev
just engine-web-build
just test-engine-web
just engine-dist
```

- `engine-web` 默认在 <http://127.0.0.1:12347> 提供双模式页面.
- `--mode wasm` 只提供静态 Web 页面, 不启动 Rust HTTP 计算服务.
- 开发页面在 <http://127.0.0.1:5173>, API 通过 Vite 代理到本地服务.
- 可用 `--port` 改计算服务端口, `--frontend-port` 改开发页面端口.
- CLI 与 Web 的回归不需要启动真游戏. `test-engine-web` 还会实际执行构建后的 WASM.

需要已有 Rust, wasm32-unknown-unknown 编译目标, Bun 和 uv. 综合归档另需 maturin.
绑定生成器严格跟随 Rust 锁文件版本, 缺少时只作为项目工具安装在 `.tmp/engine-web-tools`.
启动器不会安装 Rust SDK 或修改用户级配置. Ctrl+C 会收尾启动的服务, 开发模式任一子进程退出也会收尾其它进程.

## 使用

页面仿原版布局, 一屏显示全部内容: 左侧信息栏, 中间牌桌, 右侧可收起的调试栏.

1. 新局面板里翻页选牌组, 点筹码选赌注, 填种子 (区分大小写), 选全解锁/新存档.
2. 按阶段选择盲注, 出牌, 弃牌, 结算, 购物和选包. 使用需要目标的消耗牌前先选手牌.
3. 点小丑或消耗牌弹出售出/使用按钮. 手牌, 小丑, 消耗牌可拖拽重排.
4. 悬停卡牌显示效果. 调试栏有历史树, 逐来源计分, 牌型等级, 动态值与调试修改.
5. 点击历史节点回溯. 回溯后执行新动作形成分支, 原路线仍保留.
6. WASM 与 HTTP 切换会复制当前会话到新后端, 规则和文件格式完全共用.

快捷键: `Z`/`Backspace` 上一步, `X` 下一步, `Enter` 出牌, `Shift+Enter` 弃牌, `Esc` 清空选择, `D` 开关调试栏.

贴图, 字体与贴图清单在构建时由 `scripts/engine_web_assets.py` 从 `game/` 生成到 `client/public/game/` (不入库),
坐标取自 `game/game.lua` 各原型表的 `pos`. 缺贴图的物品退回文字卡.

按钮先做阶段限制, 最终合法性仍由引擎判断. 被拒绝的动作不会推进历史或随机状态.
HTTP 使用 revision 防止旧页面提交过期目标, 冲突时拉取最新局面并清空选择.
同一页面仅允许一个修改请求进行, 防止双击造成重复动作.

## 调试与存档

调试模式下在出牌阶段选牌即预览计分: 引擎在状态副本上试出一手, 不写历史也不推进随机状态.
牌桌按原版顺序逐步回放, 触发的手牌或小丑会跳动并飘字, 左侧筹码 X 倍率同步滚动.
中部的步骤芯片可点击定位, 也可单步, 重播或直接看结果. 掷骰效果按当前随机状态预测.

调试默认关闭. 开启后能看真实牌堆, 弃牌堆, 随机状态和 digest, 并修改金钱, 得分,
出牌/弃牌预算, 基础槽位和手牌大小奖励. 输入范围与整数要求由共享 Rust 模型验证.
修改会记录独立事件并标记后继路径, 关闭调试不能清除标记. 回到修改前的节点可继续正常路径.

会话文件 v1 保存开局, 解锁档, 所有分支事件与当前节点, 不序列化内存快照.
导入会检查引擎版本与拓扑, 重放全部节点后才替换当前会话. 导入时调试始终关闭.
单局最多 5000 节点, 文件最多 10 MiB. HTTP 最多保留 8 个内存会话.

自动存档使用 IndexedDB, 按计算模式分别保存. 页面 Origin 不同会使用不同存储, 清理浏览器数据会删掉它.
HTTP 服务重启后可从自动存档重建. 新局和载入会替换当前会话, 请先下载需要保留的路线.
离开页面前建议下载会话文件, 自动存档不替代备份. 保存失败会在底部给出提示.

正常路径可导出 `.actions.jsonl`, 交给 `just play step --actions <文件>` 继续或检查.
修改过状态的路径只能用完整会话文件, 不能伪装成普通动作记录.
本页面不生成假的 LÖVE `.replay.json` 模板.

## 部署与边界

综合发行包只有一个平台归档, 包含 `bin/`, `python/`, `web/` 与内部 SHA256 manifest.
启动其中的 HTTP 服务即可自动找到静态产物. 纯 WASM 部署只需托管 `web/`.
仓库的调试台由 `.github/workflows/pages.yml` 在 main 更新时发布到
<https://azazo1.github.io/balatro/>, 该站点只含 WASM 模式.
必须通过 HTTP/HTTPS 打开, 不支持 `file://`. WASM 在 Worker 内运行, 不把大块计算放在 UI 线程.

HTTP 服务只绑定 127.0.0.1, 检查 Host 与 Origin, 不启用宽松 CORS, 不暴露本机文件路径接口.
它不是公网或多用户服务. 普通静态部署不能使用 HTTP 模式, 但 WASM 模式不需要 API.
默认资源全部在归档内部, 没有字体或框架 CDN 请求.

结构: `model/` 是历史与文件模型, `server/` 是 HTTP 包装, `wasm/` 是 WASM 包装,
`client/` 是页面与 Worker. Core 不依赖这些 crate, GUI 依赖不会污染 core 的 std-only 保证.
