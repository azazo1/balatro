-- 本仓库新增: 游戏手册的目录索引 (文件路径, 标题, 行数) 与 README 的 "按决策查阅" 表. 只读, 任何状态可用.
-- 手册的读取逻辑见 agent/knowledge/.

BB_KNOWLEDGE = BB_KNOWLEDGE or assert(SMODS.load_file("agent/knowledge/store.lua"))()

---@type Endpoint
return {
  name = "docs_index",

  description = "List the game manual files and the task-to-document guide",

  schema = {},

  requires_state = nil,

  ---@param _ table
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    local docs, err = BB_KNOWLEDGE.docs()
    if not docs then
      send_response({ message = err, name = BB_ERROR_NAMES.INTERNAL_ERROR })
      return
    end
    send_response(docs:index())
  end,
}
