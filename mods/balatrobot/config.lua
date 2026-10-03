-- 本仓库新增: smods 读取的默认配置. 保存后的值写在存档目录的 config/balatrobot.jkr.
-- 配置版本号由 agent/migrate.lua 写入, 不放在这里.
-- 兼容: 版本 1 以前的布尔开关 enabled 已改为 mode, 旧配置由 migrate.lua 迁移
-- (enabled = true 对应 "external", 否则 "off").
-- smods 合并时存档值类型与默认值不同会被丢弃, 所以字符串字段的默认值用 "" 而不是 nil.
return {
  -- agent 模式: "off" 关闭, "external" HTTP 接口 (just agent-call), "builtin" 内置 agent.
  -- 游戏内 模组 -> BalatroBot -> 配置 可切换; BALATROBOT_ENABLE=1 启动时锁定为 external, 不写回.
  mode = "off",
  -- 是否在游戏内显示 agent 的决策消息 (右侧: 模型给的 reason 与 notify 的解说).
  show_messages = true,
  -- 是否显示工具调用记录 (左侧: 工具中文名与本次参数的含义).
  show_calls = true,
  -- 右侧消息节奏: "normal" 阅读 (等讲解读完), "fast" 快速 (不拦操作).
  message_pace = "normal",

  -- 内置决策方式: llm / decision / hybrid. 两份连接独立保存, 切换方式不清空.
  builtin_backend = "llm",
  -- key 以明文保存在本机, 不写进日志.
  llm = {
    endpoint = "",
    model = "",
    auth = "bearer",
    api_key = "",
    -- 接口: chat / responses / anthropic.
    api_format = "chat",
    context_limit = 256000,
    reasoning_effort = "",
    thinking = "adaptive",
  },
  decision = {
    provider = "typesafe",
    endpoint = "https://api.typesafe.ai/v1/systemone",
    model = "jev-latest",
    auth = "bearer",
    api_key = "",
    -- 0 为不限制. 置信度不等于正确率, 低于阈值自动暂停.
    min_confidence = 0,
  },
  -- 单局 token 上限, 统计 LLM 与 Decision 的合计用量, 0 为不限.
  token_limit = 0,
  -- 内置 agent 赢下一局后: "menu" 回主菜单, "endless" 进入无尽模式继续打.
  after_win = "menu",
  -- 内置 agent 一局结束回到主菜单后: "stop" 停止 loop, "continue" 保留对话历史, 由模型自己开下一局.
  after_run = "stop",
  -- 内置 agent 的打法策略: user 自己写的一段文字, 拼在系统提示词末尾, 下一次开始时生效. 空为不加.
  strategy = "",
  -- 内置 agent 开局用的固定种子 (原版种子: 最多 8 位大写字母与数字). 空为随机.
  -- 设了以后内置 agent 每次开局都用它, 模型自己给的种子不算; 原版规定固定种子的局不计解锁和统计.
  seed = "",

  -- 录像: 是否录制, 保留方式 ("skip" 或 "keep"). 设了 BALATROBOT_RECORD 环境变量时以环境变量为准.
  record = false,
  record_keep = "skip",

  -- 开发用: 没有接入模型时用假数据驱动流式条, 验证运行控制和外观.
  demo_stream = false,
}
