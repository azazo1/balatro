--[[
文本小工具: UTF-8 安全的按字节截断. 纯逻辑, 不依赖游戏, 有单测.

为什么需要它: 请求体里的字符串是原样发出的 (json 库与本仓库自己的编码器都只转义控制字符, 非 ASCII 字节
直接写进请求体). 用 string.sub 按字节截断时, 若切点落在一个多字节字符中间, 请求体里就会出现非法 UTF-8,
服务端直接拒绝整个请求 (实测 400: invalid unicode code point). 手册查询结果超过上限时就会被截断,
所以这里统一按字符边界切.
]]

local M = {}

-- 一个字符的首字节: ASCII (0xxxxxxx) 或 UTF-8 前导字节 (110xxxxx 及以上).
-- 续字节是 10xxxxxx (0x80~0xBF).
---@param byte integer?
---@return boolean
local function is_lead(byte)
  return byte == nil or byte < 0x80 or byte >= 0xC0
end

--- 从 limit 处往前找到字符边界, 返回可以安全保留的字节数.
---@param text string
---@param limit integer
---@return integer
local function safe_length(text, limit)
  if limit >= #text then
    return #text
  end
  local cut = math.max(0, limit)
  -- 切点后一个字节是续字节时, 说明切点落在字符中间, 往前退到该字符的首字节之前.
  while cut > 0 and not is_lead(text:byte(cut + 1)) do
    cut = cut - 1
  end
  return cut
end

--- 按字节上限截断, 保证结果仍是合法的 UTF-8 (末尾不会留下半个字符).
---@param text string
---@param limit integer 字节数上限
---@return string
function M.cut(text, limit)
  text = tostring(text or "")
  return text:sub(1, safe_length(text, limit))
end

--- text 是否是合法的 UTF-8 (不含孤立的续字节与截断的字符).
---@param text string
---@return boolean ok
---@return integer? at 第一个非法字节的位置
function M.valid_utf8(text)
  local i = 1
  while i <= #text do
    local b = text:byte(i)
    local extra
    if b < 0x80 then
      extra = 0
    elseif b >= 0xC2 and b <= 0xDF then
      extra = 1
    elseif b >= 0xE0 and b <= 0xEF then
      extra = 2
    elseif b >= 0xF0 and b <= 0xF4 then
      extra = 3
    else
      return false, i
    end
    for k = 1, extra do
      local c = text:byte(i + k)
      if not c or c < 0x80 or c > 0xBF then
        return false, i
      end
    end
    i = i + extra + 1
  end
  return true
end

-- U+FFFD (替换字符) 的 UTF-8 字节
local REPLACEMENT = "\239\191\189"

--- 把非法 UTF-8 字节换成 U+FFFD, 合法时原样返回.
--- 请求体的兜底: 一个坏字节就会让服务端拒掉整个请求, 并让 agent 停下, 所以发出去之前统一修一次.
--- 纯 ASCII 的字符串直接跳过 (绝大多数), 合法的非 ASCII 只扫一遍不重建.
---@param text string
---@return string
function M.sanitize_utf8(text)
  if type(text) ~= "string" or not text:find("[\128-\255]") then
    return text
  end
  if M.valid_utf8(text) then
    return text
  end
  local out, i, n = {}, 1, #text
  while i <= n do
    local b = text:byte(i)
    local extra = 0
    if b < 0x80 then
      extra = 0
    elseif b >= 0xC2 and b <= 0xDF then
      extra = 1
    elseif b >= 0xE0 and b <= 0xEF then
      extra = 2
    elseif b >= 0xF0 and b <= 0xF4 then
      extra = 3
    else
      extra = -1 -- 孤立的首字节或续字节
    end
    if extra >= 0 then
      for k = 1, extra do
        local c = text:byte(i + k)
        if not c or c < 0x80 or c > 0xBF then
          extra = -1
          break
        end
      end
    end
    if extra < 0 then
      out[#out + 1] = REPLACEMENT
      i = i + 1
    else
      out[#out + 1] = text:sub(i, i + extra)
      i = i + extra + 1
    end
  end
  return table.concat(out)
end

return M
