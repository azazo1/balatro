--[[
手册查询的游戏内入口: 定位手册根目录, 用 SMODS.NFS 实现文件访问, 懒加载手册与目录.

手册根目录:
- 设了环境变量 BALATROBOT_KNOWLEDGE_DIR 时用它, 便于开发时直接读仓库的 docs/game/.
- 否则为 mod 目录下的 knowledge/, 由打包 (scripts/lib/modding/build.py) 从 docs/game/ 复制进来.

mod 路径在模块加载时缓存: 端点执行时 SMODS.current_mod 可能已经不是本 mod (见 balatrobot.lua 的 BB_AGENT.set_enabled).
4 个端点共用同一个实例, 由第一个加载的端点存进 BB_KNOWLEDGE.
]]

-- SMODS.load_file 只在 mod 首次加载期间可以省 id, agent/ 下一律显式给出.
local MOD_ID = "balatrobot"
local Docs = assert(SMODS.load_file("agent/knowledge/docs.lua", MOD_ID))()
local Catalog = assert(SMODS.load_file("agent/knowledge/catalog.lua", MOD_ID))()
local json = require("json")

local M = {}

local MOD_PATH = SMODS.current_mod and SMODS.current_mod.path or ""
local LOGGER = "BB.KNOWLEDGE"

---@return string root 以 "/" 结尾
---@return string source 手册来源, 用于日志与错误信息
local function resolve_root()
  local env = os.getenv("BALATROBOT_KNOWLEDGE_DIR")
  if env and env ~= "" then
    env = env:gsub("\\", "/")
    if env:sub(-1) ~= "/" then
      env = env .. "/"
    end
    return env, "BALATROBOT_KNOWLEDGE_DIR"
  end
  return MOD_PATH .. "knowledge/", "mod"
end

local ROOT, SOURCE = resolve_root()
local NFS = SMODS.NFS

---@param rel string
---@return string?
local function read(rel)
  local data = NFS.read(ROOT .. rel)
  if type(data) ~= "string" then
    return nil
  end
  return data
end

---@param rel string
---@return string[]
local function list(rel)
  local dir = rel == "" and ROOT or (ROOT .. rel .. "/")
  local out = {}
  for _, name in ipairs(NFS.getDirectoryItems(dir)) do
    local info = NFS.getInfo(dir .. name)
    if info and info.type == "directory" then
      out[#out + 1] = name .. "/"
    else
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---@type Knowledge.Docs?
local docs = nil
---@type Knowledge.Catalog?
local catalog = nil

--- 手册是否存在. 不存在时返回 nil 与说明.
---@return boolean? ok
---@return string? err
local function available()
  if NFS.getInfo(ROOT .. "README.md") then
    return true
  end
  if SOURCE == "mod" then
    return nil, "Game manual not found at " .. ROOT .. ". It is copied into the mod by the modded build "
      .. "(just mods-tree / packaging); running the plain game/ tree has no manual. "
      .. "Set BALATROBOT_KNOWLEDGE_DIR to the repository's docs/game/ for development"
  end
  return nil, "Game manual not found at BALATROBOT_KNOWLEDGE_DIR=" .. ROOT
end

--- 手册对象. 手册不存在时返回 nil 与说明.
---@return Knowledge.Docs? docs
---@return string? err
function M.docs()
  if docs then
    return docs
  end
  local ok, err = available()
  if not ok then
    return nil, err
  end
  docs = Docs.new({ read = read, list = list })
  sendInfoMessage("Game manual loaded from " .. ROOT .. " (" .. SOURCE .. ")", LOGGER)
  return docs
end

--- 结构化目录. 手册不存在时返回 nil 与说明.
---@return Knowledge.Catalog? catalog
---@return string? err
function M.catalog()
  if catalog then
    return catalog
  end
  local d, err = M.docs()
  if not d then
    return nil, err
  end
  catalog = Catalog.new({ read = read, decode = json.decode, docs = d })
  return catalog
end

return M
