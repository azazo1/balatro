--[[
录像的清晰度 (画面高度), 帧率与码率: 可选值, 平台默认, 以及环境变量 / 设置页 / 默认值之间的取舍.
纯逻辑, 不碰 love, 单测直接加载.

- 设置页存可选值之一, 0 表示跟随默认: 清晰度与帧率按平台, 码率为自动.
- 环境变量优先 (桌面上用 just 启动时设), 其次是设置页, 最后是平台默认. Android 没有环境变量.
- 码率为自动时: Android 按像素数与帧率估算, 桌面用编码器的固定画质参数, 体积随画面复杂度变化.
]]

local M = {}

M.HEIGHTS = { 360, 540, 720, 1080 }
M.FPS = { 24, 30, 60 }
M.BITRATES = { 0, 2, 4, 8, 16 } -- Mbps, 0 为自动

-- 设置项 -> 环境变量. 码率的单位是 Mbps, 可以带小数.
M.ENV = {
  height = "BALATROBOT_RECORD_HEIGHT",
  fps = "BALATROBOT_RECORD_FPS",
  bitrate = "BALATROBOT_RECORD_BITRATE",
}

local CHOICES = { height = M.HEIGHTS, fps = M.FPS, bitrate = M.BITRATES }

--- 平台默认. Android 默认 540p 24fps: 手机屏幕小, 540p 够看; 退到软编时 24fps 比 30fps 省四分之一 CPU.
--- 桌面默认 720p30.
---@param android boolean
---@return {height: integer, fps: integer, bitrate: number}
function M.defaults(android)
  if android then
    return { height = 540, fps = 24, bitrate = 0 }
  end
  return { height = 720, fps = 30, bitrate = 0 }
end

--- 设置页的值: 是可选值时原样返回, 0, nil 或不在可选范围内 (手改了配置文件) 时返回平台默认.
---@param key "height"|"fps"|"bitrate"
---@param value any
---@param android boolean
---@return number
function M.pick(key, value, android)
  if value ~= 0 then
    for _, choice in ipairs(CHOICES[key]) do
      if choice == value then
        return value
      end
    end
  end
  return M.defaults(android)[key]
end

--- 环境变量的值. 清晰度与帧率取正整数, 码率取非负数; 不合法时返回 nil (当作没设).
---@param key "height"|"fps"|"bitrate"
---@param raw string?
---@return number?
local function from_env(key, raw)
  local n = tonumber(raw or "")
  if not n then
    return nil
  end
  if key == "bitrate" then
    return n >= 0 and n or nil
  end
  n = math.floor(n)
  return n > 0 and n or nil
end

--- 实际使用的参数.
---@param config {height: any, fps: any, bitrate: any}? 设置页的值
---@param getenv fun(name: string): string? 一般是 os.getenv
---@param android boolean
---@return {height: integer, fps: integer, bitrate: number, env: table<string, string>} env: 由环境变量决定的项及其原值
function M.resolve(config, getenv, android)
  local out = { env = {} }
  for key in pairs(CHOICES) do
    local raw = getenv(M.ENV[key])
    local value = from_env(key, raw)
    if value then
      out[key] = value
      out.env[key] = raw
    else
      out[key] = M.pick(key, config and config[key], android)
    end
  end
  return out
end

return M
