--[[
选项菜单 (ESC 菜单, Android 上是 "选项") 里的公共入口 (BB_MENU).

lovely 补丁 (lovely/menu.toml) 在 create_UIBox_options 里调用 BB_MENU.button(), 插进 "统计" 按钮之前.
各 mod 往 entries 里追加函数: balatrobot 的 "Agent", bbreplay 的 "回放". 函数返回 UI 节点, 返回 nil 表示不显示.
按加载顺序排列 (bbcore, balatrobot, bbreplay), 多个按钮时包成一行.
]]

local LOGGER = "BB.MENU"

local M = {
  ---@type (fun(): table?)[]
  entries = {},
}

--- lovely 补丁调用: 返回要插进选项菜单的节点, 没有时返回 nil.
---@return table?
function M.button()
  local nodes = {}
  for _, entry in ipairs(M.entries) do
    local ok, node = pcall(entry)
    if not ok then
      sendErrorMessage("Options menu entry failed: " .. tostring(node), LOGGER)
    elseif node then
      nodes[#nodes + 1] = node
    end
  end
  if #nodes <= 1 then
    return nodes[1]
  end
  -- 多个按钮时包成一行, 中间留出与原版按钮相同的间距.
  local spaced = {}
  for i, node in ipairs(nodes) do
    if i > 1 then
      spaced[#spaced + 1] = { n = G.UIT.R, config = { minh = 0.2 }, nodes = {} }
    end
    spaced[#spaced + 1] = node
  end
  return { n = G.UIT.R, config = { align = "cm", padding = 0 }, nodes = spaced }
end

return M
