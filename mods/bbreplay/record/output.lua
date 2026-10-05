-- 视频与回放文件共用的输出命名和目录创建, 不加载编码器.
local M = {}
local LOGGER = "BB.REPLAY.OUTPUT"

local function fix_permissions(path)
  local ok, storage = pcall(require, "android_storage")
  if ok and type(storage) == "table" and storage.fix_path then
    pcall(storage.fix_path, path)
  end
end

function M.directory()
  local dir = os.getenv("BALATROBOT_RECORD_DIR")
  return (dir and dir ~= "") and dir:gsub("/+$", "") or (love.filesystem.getSaveDirectory() .. "/recordings")
end

--- 分配一局的输出位置. 两种录制都开时, 回放文件直接复用视频的位置, 不重复调用.
---@param prefix string?
---@return table? output
---@return string? error
function M.create(prefix)
  local dir = M.directory()
  local made, err = SMODS.NFS.createDirectory(dir)
  if not made then
    return nil, tostring(err)
  end
  fix_permissions(dir)
  local game = G.GAME or {}
  local seed = game.pseudorandom and game.pseudorandom.seed or "noseed"
  prefix = tostring(prefix or os.getenv("BALATROBOT_RECORD_PREFIX") or ""):gsub("[^%w%-_]", "")
  local stem = prefix .. os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(seed):gsub("[^%w%-_]", "")
  local suffix = 1
  local function exists(name)
    -- 平铺退路的文件也占用名字, 免得同一秒重开覆盖掉上一局.
    return SMODS.NFS.getInfo(dir .. "/" .. name)
      or SMODS.NFS.getInfo(dir .. "/" .. name .. ".replay.json")
      or SMODS.NFS.getInfo(dir .. "/" .. name .. ".json")
  end
  while exists(stem .. (suffix > 1 and ("-" .. suffix) or "")) do
    suffix = suffix + 1
  end
  if suffix > 1 then
    stem = stem .. "-" .. suffix
  end
  local folder = dir .. "/" .. stem
  local folder_ok, folder_err = SMODS.NFS.createDirectory(folder)
  if folder_ok then
    fix_permissions(folder)
  else
    sendWarnMessage(
      string.format("建不了录制文件夹 %s (%s), 这一局还是平铺着写", folder, tostring(folder_err)),
      LOGGER
    )
    folder = dir
  end
  return { stem = stem, base = folder .. "/" .. stem, started = love.timer.getTime() }
end

return M
