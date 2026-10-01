-- 本仓库新增: 读取游戏手册的一个文件, 带行号. 可按 section (标题文字或锚点 id) 切章节, 或 offset/limit 分页.
-- 大文件不带 section/offset 时只返回大纲. 只读, 任何状态可用.

BB_KNOWLEDGE = BB_KNOWLEDGE or assert(SMODS.load_file("agent/knowledge/store.lua", "balatrobot"))()

---@class Request.Endpoint.DocsRead.Params
---@field path string 相对手册根目录的路径, 可带 "#锚点"
---@field section string? 标题文字或锚点 id
---@field offset integer? 起始行号 (1 起)
---@field limit integer? 最多读取的行数

---@type Endpoint
return {
  name = "docs_read",

  description = "Read a game manual file with line numbers, by section or offset/limit",

  schema = {
    path = { type = "string", required = true, description = "File path relative to the manual root, may end with #anchor" },
    section = { type = "string", required = false, description = "Heading text or anchor id" },
    offset = { type = "integer", required = false, description = "First line number (1-based)" },
    limit = { type = "integer", required = false, description = "Maximum number of lines, capped at 200" },
  },

  requires_state = nil,

  ---@param args Request.Endpoint.DocsRead.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    local docs, err = BB_KNOWLEDGE.docs()
    if not docs then
      send_response({ message = err, name = BB_ERROR_NAMES.INTERNAL_ERROR })
      return
    end
    local result, read_err = docs:read(args)
    if not result then
      send_response({ message = read_err, name = BB_ERROR_NAMES.BAD_REQUEST })
      return
    end
    send_response(result)
  end,
}
