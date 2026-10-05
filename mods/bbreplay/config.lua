-- smods 读取的默认配置. 保存后的值写在存档目录的 config/bbreplay.jkr.
-- 配置版本号由 migrate.lua 写入, 不放在这里 (否则旧配置合并后也带上版本号, 无法识别).
-- smods 合并时存档值类型与默认值不同会被丢弃, 所以字符串字段的默认值用 "" 而不是 nil.
return {
  -- 视频开关与保留方式 ("skip" 合成后删掉中间文件, "keep" 保留).
  -- 设了 BALATROBOT_RECORD_VIDEO / BALATROBOT_RECORD_KEEP 时以环境变量为准.
  record_video = false,
  -- 回放文件独立于视频录制, 设了 BALATROBOT_RECORD_REPLAY 时以环境变量为准.
  record_replay = false,
  record_keep = "skip",
  -- 清晰度 (画面高度), 帧率, 码率 (Mbps). 0 为默认: 清晰度与帧率按平台 (桌面 720p30, Android 540p24),
  -- 码率自动. 可选值见 record/quality.lua. 设了 BALATROBOT_RECORD_HEIGHT / _FPS / _BITRATE 时以环境变量为准.
  record_height = 0,
  record_fps = 0,
  record_bitrate = 0,
}
