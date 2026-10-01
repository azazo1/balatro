-- smods 读取的默认配置. 保存后的值写在存档目录的 config/bbreplay.jkr.
-- 配置版本号由 migrate.lua 写入, 不放在这里 (否则旧配置合并后也带上版本号, 无法识别).
-- smods 合并时存档值类型与默认值不同会被丢弃, 所以字符串字段的默认值用 "" 而不是 nil.
return {
  -- 录像: 是否录制, 保留方式 ("skip" 合成后删掉中间文件, "keep" 保留).
  -- 设了 BALATROBOT_RECORD / BALATROBOT_RECORD_KEEP 环境变量时以环境变量为准.
  record = false,
  record_keep = "skip",
}
