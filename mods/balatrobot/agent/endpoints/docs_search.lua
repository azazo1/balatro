-- 本仓库新增: 在游戏手册里做子串搜索 (不区分大小写), 返回 "路径:行号: 内容". 只读, 任何状态可用.

BB_KNOWLEDGE = BB_KNOWLEDGE or assert(SMODS.load_file("agent/knowledge/store.lua"))()

---@class Request.Endpoint.DocsSearch.Params
---@field query string 搜索的子串
---@field path string? 限定文件或目录
---@field limit integer? 最多返回的条数, 默认 20

---@type Endpoint
return {
  name = "docs_search",

  description = "Search the game manual for a substring, case-insensitive",

  schema = {
    query = { type = "string", required = true, description = "Substring to search for" },
    path = { type = "string", required = false, description = "Limit to a file or directory of the manual" },
    limit = { type = "integer", required = false, description = "Maximum number of matches, defaults to 20, capped at 100" },
  },

  requires_state = nil,

  ---@param args Request.Endpoint.DocsSearch.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    local docs, err = BB_KNOWLEDGE.docs()
    if not docs then
      send_response({ message = err, name = BB_ERROR_NAMES.INTERNAL_ERROR })
      return
    end
    local result, search_err = docs:search(args)
    if not result then
      send_response({ message = search_err, name = BB_ERROR_NAMES.BAD_REQUEST })
      return
    end
    send_response(result)
  end,
}
