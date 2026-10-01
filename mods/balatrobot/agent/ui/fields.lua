--[[
设置页字段的纯逻辑: key 掩码, 剪贴板内容清洗, 策略预览, token 上限选项. 不依赖 G/SMODS, 可以用 luajit 单测.

key 在界面上只显示首尾各几位, 露出的字数随长度增加, 但总共不超过约四分之一; 很短的 key 全部遮住.
]]

local M = {}

-- 单局 token 上限的选项, 0 表示不限.
M.TOKEN_LIMITS = { 0, 100000, 500000, 1000000, 5000000 }
M.TOKEN_LIMIT_LABELS = { "不限", "100K", "500K", "1M", "5M" }

-- 最大上下文的选项 (token). 上一次请求的用量到它的 80% 时压缩较早的对话.
M.CONTEXT_LIMITS = { 32000, 64000, 128000, 256000, 500000, 1000000 }
M.CONTEXT_LIMIT_LABELS = { "32K", "64K", "128K", "256K", "500K", "1M" }

--- 掩码显示 key, 例如 "sk-...ab12".
---@param key string?
---@return string
function M.mask_key(key)
  if type(key) ~= "string" or key == "" then
    return "未设置"
  end
  local n = #key
  if n < 12 then
    return "****"
  end
  local head = math.min(4, math.floor(n / 8))
  local tail = math.min(4, math.floor(n / 8))
  return key:sub(1, head) .. "..." .. key:sub(n - tail + 1) .. " (" .. n .. " 位)"
end

--- 清洗剪贴板内容. field 为 endpoint / model / api_key / strategy / seed.
--- 返回清洗后的值, 或 nil 与原因 (不回显内容, 避免把 key 显示出来).
--- strategy 是给模型看的一段说明, 保留换行, 不限长度, 只统一换行符并去掉其它控制字符.
---@param field string
---@param text any
---@return string? value
---@return string? reason
function M.clean_paste(field, text)
  if type(text) ~= "string" then
    return nil, "剪贴板为空"
  end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return nil, "剪贴板为空"
  end
  if field == "strategy" then
    text = text:gsub("\r\n?", "\n"):gsub("[%z\1-\8\11\12\14-\31\127]", "")
    return text
  end
  if field == "seed" then
    -- 与原版种子输入框一致: 最多 8 位, 自动转大写, 只有字母和数字.
    text = text:upper()
    if not text:find("^[A-Z0-9]+$") then
      return nil, "种子只能是字母和数字"
    end
    if #text > 8 then
      return nil, "种子最多 8 位"
    end
    return text
  end
  if #text > 4096 then
    return nil, "剪贴板内容太长"
  end
  -- 值会拼进 HTTP 头或请求体, 不接受中间带换行和控制字符的内容.
  if text:find("[%c]") then
    return nil, "内容含有换行或控制字符"
  end
  if field == "endpoint" then
    if not text:lower():find("^https?://[^/%s]") then
      return nil, "endpoint 要以 http:// 或 https:// 开头"
    end
  elseif field == "api_key" then
    -- 从别处复制时常带着 "Bearer " 前缀.
    text = text:gsub("^[Bb]earer%s+", "")
    if text:find("%s") then
      return nil, "key 中间不能有空白"
    end
  elseif field == "model" then
    if text:find("%s") then
      return nil, "模型名中间不能有空白"
    end
  else
    return nil, "未知字段: " .. tostring(field)
  end
  return text
end

--- 策略在设置页一行里的预览: 换行与连续空白并成一个空格, 之后再按宽度截取.
---@param strategy string?
---@return string? 空时为 nil
function M.strategy_preview(strategy)
  if type(strategy) ~= "string" or not strategy:find("%S") then
    return nil
  end
  return (strategy:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- 当前 token 上限在选项里的下标, 不在选项里时按 "不限".
---@param limit any
---@return integer
function M.token_limit_index(limit)
  for i, v in ipairs(M.TOKEN_LIMITS) do
    if v == limit then
      return i
    end
  end
  return 1
end

--- 当前最大上下文在选项里的下标, 不在选项里时按默认 (256K).
---@param limit any
---@return integer
function M.context_limit_index(limit)
  for i, v in ipairs(M.CONTEXT_LIMITS) do
    if v == limit then
      return i
    end
  end
  return 4
end

return M
