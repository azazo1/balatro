-- 本仓库新增: smods 读取的默认配置. 保存后的值写在存档目录的 config/balatrobot.jkr.
-- 配置版本号由 agent/migrate.lua 写入, 不放在这里.
return {
  -- 是否开启 agent 接口, 游戏内 Mods > BalatroBot > Config 可切换.
  enabled = false,
  -- 是否在游戏内显示 agent 的决策消息.
  show_messages = true,
}
