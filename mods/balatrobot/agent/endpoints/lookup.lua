-- 本仓库新增: 按 id, 中文名或英文名查卡牌/对象的精简记录, 并带出机制文档中提到它的行. 只读, 任何状态可用.

BB_KNOWLEDGE = BB_KNOWLEDGE or assert(SMODS.load_file("agent/knowledge/store.lua", "balatrobot"))()

---@class Request.Endpoint.Lookup.Params
---@field keys string[] id, 中文名或英文名

---@type Endpoint
return {
  name = "lookup",

  description = "Look up cards by id, Chinese or English name, with related mechanics lines",

  schema = {
    keys = {
      type = "array",
      required = true,
      items = "string",
      description = "Card ids (e.g. j_blueprint), Chinese or English names",
    },
  },

  requires_state = nil,

  ---@param args Request.Endpoint.Lookup.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    local catalog, err = BB_KNOWLEDGE.catalog()
    if not catalog then
      send_response({ message = err, name = BB_ERROR_NAMES.INTERNAL_ERROR })
      return
    end
    local result, lookup_err = catalog:lookup(args.keys)
    if not result then
      send_response({ message = lookup_err, name = BB_ERROR_NAMES.BAD_REQUEST })
      return
    end
    send_response(result)
  end,
}
