-- 手册查询 4 个方法在左侧工具调用弹窗里的文案 (bbcore 的 BB_CALL_NOTE 在加载时登记).
-- 标题是工具中文名, 正文是这次参数的含义; 没有参数时给该工具功能的一句话.

local M = {}

---@param text string
---@return string
local function clip(text)
  -- 与 bbcore 的正文上限一致 (那里还会再截一次)
  if #text <= 80 then
    return text
  end
  local chars, count = {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    count = count + 1
    if count > 77 then
      break
    end
    chars[#chars + 1] = ch
  end
  return table.concat(chars) .. "..."
end

M.docs_index = {
  title = "手册目录",
  hint = "看手册目录与按决策查阅表",
}

M.docs_read = {
  title = "读手册",
  hint = "读手册里的一节",
  format = function(params)
    if not params.path then
      return nil
    end
    local text = "读 " .. tostring(params.path)
    if params.section then
      text = text .. " 的 " .. tostring(params.section) .. " 节"
    end
    if params.offset then
      text = text .. ", 从第 " .. tostring(params.offset) .. " 行"
    end
    return text
  end,
}

M.docs_search = {
  title = "搜手册",
  hint = "在手册里搜关键词",
  format = function(params)
    if not params.query then
      return nil
    end
    local text = "搜 " .. clip(tostring(params.query))
    if params.path then
      text = text .. " (限 " .. tostring(params.path) .. ")"
    end
    return text
  end,
}

M.lookup = {
  title = "查卡牌",
  hint = "按 id 或中文名查卡牌",
  format = function(params)
    local keys = params.keys
    if type(keys) ~= "table" or #keys == 0 then
      return nil
    end
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = tostring(key)
    end
    return clip("查 " .. table.concat(parts, ", "))
  end,
}

return M
