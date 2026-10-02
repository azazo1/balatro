-- smods-fixes: 模组配置必须写到 LÖVE 存档目录, 不能跟进程 cwd.
-- luajit scripts/tests/lua/smods_config_path_test.lua

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local SAVE_DIR = "/save/Balatro-Modded"
local cwd = "/"
local files = {}
local nfs_writes = {}

love = {
  filesystem = {
    getSaveDirectory = function()
      return SAVE_DIR
    end,
    createDirectory = function(path)
      files[path] = files[path] or { dir = true }
      return true
    end,
    write = function(path, data)
      files[path] = data
      return true
    end,
    read = function(path)
      local data = files[path]
      if type(data) == "string" then
        return data
      end
      return nil
    end,
  },
}

NFS = {
  setWorkingDirectory = function(path)
    cwd = path
    return true
  end,
  write = function(path, data)
    nfs_writes[#nfs_writes + 1] = { cwd = cwd, path = path, data = data }
    return true
  end,
  read = function(path)
    return nil
  end,
}

function serialize(t)
  return string.format('{["record"] = %s}', t.record and "true" or "false")
end

local orig_save_called = 0
SMODS = {
  save_mod_config = function()
    orig_save_called = orig_save_called + 1
    return true
  end,
  load_mod_config = function(mod)
    return mod.config
  end,
}

function create_toggle(args)
  return args
end
function create_option_cycle(args)
  return args
end

dofile("mods/smods-fixes/main.lua")

cwd = "/"
local mod = { id = "bbreplay", config = { record = true, record_keep = "keep" } }
local saved = SMODS.save_mod_config(mod)
check("save 返回成功", saved == true)
check("不走 nativefs 相对路径", #nfs_writes == 0, tostring(#nfs_writes))
check("不调用 Steamodded 原 save", orig_save_called == 0, tostring(orig_save_called))
check("写入存档目录的 config/bbreplay.jkr", type(files["config/bbreplay.jkr"]) == "string", tostring(files["config/bbreplay.jkr"]))
check("内容含改过的值", (files["config/bbreplay.jkr"] or ""):find("true", 1, true) ~= nil, files["config/bbreplay.jkr"])

cwd = "/Applications/Balatro-Modded.app/Contents/Resources"
SMODS.load_mod_config(mod)
check("load 前把 cwd 拨回存档目录", cwd == SAVE_DIR, tostring(cwd))

local empty = SMODS.save_mod_config({ id = "x", config = {} })
check("空配置不写文件", empty == false)

if failures > 0 then
  os.exit(1)
end
print(string.format("%d failed", failures))
