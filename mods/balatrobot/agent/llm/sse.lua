--[[
SSE (server-sent events) 的纯逻辑部分, 不依赖游戏, 单测直接加载.

- parse: 把一条事件原文 (不含末尾空行) 解析成 data 字符串. 多行 data: 按规范用 "\n" 拼接,
  以 ":" 开头的注释行 (如 keep-alive) 忽略. 没有 data 行的事件返回 nil.
- is_done: data 是否为 OpenAI 风格的结束标记 [DONE].
- split: 把一段原始文本按空行拆成完整事件, 同时认 "\n\n" 与 "\r\n\r\n". 原生库 bbnet 已在
  Rust 里分帧, 这里只给退路 (SMODS.https 一次性交出整段响应) 用.
]]

local M = {}

M.DONE = "[DONE]"

--- 解析一条 SSE 事件原文.
---@param raw string 事件原文, 可含多行
---@return string? data 多行 data 拼接后的内容; 没有 data 行时为 nil
---@return string? event event 字段, 没有时为 nil
function M.parse(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, nil
  end
  local data, event
  -- 统一换行后逐行处理, 末尾补一个换行保证最后一行也能匹配到.
  local text = raw:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"
  for line in text:gmatch("([^\n]*)\n") do
    if line ~= "" and line:sub(1, 1) ~= ":" then
      local field, value = line:match("^([^:]*):(.*)$")
      if not field then
        field, value = line, ""
      end
      -- 规范: 冒号后的第一个空格不算值的一部分.
      if value:sub(1, 1) == " " then
        value = value:sub(2)
      end
      if field == "data" then
        data = data and (data .. "\n" .. value) or value
      elseif field == "event" then
        event = value
      end
    end
  end
  return data, event
end

--- data 是否为结束标记.
---@param data string?
---@return boolean
function M.is_done(data)
  if type(data) ~= "string" then
    return false
  end
  return data:match("^%s*(.-)%s*$") == M.DONE
end

--- 按空行拆分事件. 返回完整事件列表与剩余的半截文本, 半截文本可以和后续数据拼接后再拆.
---@param buffer string
---@return string[] events 完整事件原文, 不含分隔空行
---@return string rest 尚未结束的剩余文本
function M.split(buffer)
  local events = {}
  local text = (buffer or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local pos = 1
  while true do
    local s, e = text:find("\n\n", pos, true)
    if not s then
      break
    end
    local chunk = text:sub(pos, s - 1)
    if chunk ~= "" then
      events[#events + 1] = chunk
    end
    pos = e + 1
    -- 连续多个空行视为一个分隔.
    while text:sub(pos, pos) == "\n" do
      pos = pos + 1
    end
  end
  return events, text:sub(pos)
end

return M
