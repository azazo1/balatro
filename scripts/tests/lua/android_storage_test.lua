-- Android 存档目录权限模块的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 在 macOS 上跑: chmod, mkdir, opendir 的行为与本机一致, 可以真实验证目录补建与权限修正.
-- 目录遍历 (walk) 依赖 bionic 的 struct dirent 布局, 改属组依赖 bionic 的 struct stat 布局,
-- 开发机上都不成立, 这里不覆盖.

local M = dofile("game/android_storage.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

--- 低三位权限 (macOS 不保留 setgid 位, Android 上目录是 2770), 路径不存在时为 nil.
---@param path string
---@return integer?
local function mode_of(path)
  local pipe = io.popen("stat -f %Lp '" .. path .. "' 2>/dev/null")
  local out = pipe:read("*a")
  pipe:close()
  local mode = tonumber(out:match("%d+"))
  return mode and mode % 1000
end

local function mktemp_root()
  local pipe = io.popen("mktemp -d")
  local dir = pipe:read("*a"):gsub("%s+$", "")
  pipe:close()
  return dir
end

local function rmrf(path)
  os.execute("rm -rf '" .. path .. "'")
end

--- 假 love: 只实现本模块用到的函数, 写到本机的临时目录里.
--- setIdentity 照真实 LÖVE 的行为不补父目录, 目录由 android_storage 自己补.
---@param root string 临时目录
---@param os_name string
local function make_love(root, os_name)
  local identity = nil
  local fs = {}
  function fs.getSaveDirectory()
    local base = root .. "/Android/data/com.test/files"
    return identity and (base .. "/save/" .. identity) or base
  end
  function fs.setIdentity(name)
    identity = name
    return true
  end
  local function resolve(path)
    return fs.getSaveDirectory() .. "/" .. path
  end
  function fs.createDirectory(path)
    return os.execute("mkdir -p '" .. resolve(path) .. "'") == 0
  end
  function fs.write(path, data)
    local file = io.open(resolve(path), "wb")
    if not file then
      return false
    end
    file:write(data)
    file:close()
    return true
  end
  return { _os = os_name, filesystem = fs, handlers = {} }
end

do -- 新装的包: files/save 不存在, 逐级补建, 写入后按类型修正, 含密钥的配置保持 0600
  local root = mktemp_root()
  os.execute("mkdir -p '" .. root .. "/Android/data/com.test/files'")
  love = make_love(root, "Android")
  M.install()
  check("父目录缺失时 setIdentity 仍返回成功", love.filesystem.setIdentity("Balatro-Modded") == true)
  local save = root .. "/Android/data/com.test/files/save/Balatro-Modded"
  check("补建的存档目录是 0770", mode_of(save) == 770, tostring(mode_of(save)))
  check("补建的中间层 save 是 0770", mode_of(root .. "/Android/data/com.test/files/save") == 770)

  love.filesystem.createDirectory("config")
  love.filesystem.write("config/balatrobot.jkr", "secret")
  love.filesystem.write("settings.jkr", "s")
  check("含密钥的配置是 0600", mode_of(save .. "/config/balatrobot.jkr") == 600, tostring(mode_of(save .. "/config/balatrobot.jkr")))
  check("新建的目录是 0770", mode_of(save .. "/config") == 770, tostring(mode_of(save .. "/config")))
  check("普通存档文件是 0660", mode_of(save .. "/settings.jkr") == 660, tostring(mode_of(save .. "/settings.jkr")))
  rmrf(root)
end

do -- 旧版本留下的 0700 目录: 启动时把包目录到存档目录之间的各级都修正成 0770
  local root = mktemp_root()
  local pkg = root .. "/Android/data/com.test"
  local save = pkg .. "/files/save/Balatro-Modded"
  os.execute("mkdir -p '" .. save .. "' && chmod 700 '" .. pkg .. "/files' '" .. pkg .. "/files/save' '" .. save .. "'")
  local pkg_mode_before = mode_of(pkg)
  love = make_love(root, "Android")
  M.install()
  love.filesystem.setIdentity("Balatro-Modded")
  check("files 被修正", mode_of(pkg .. "/files") == 770, tostring(mode_of(pkg .. "/files")))
  check("save 被修正", mode_of(pkg .. "/files/save") == 770, tostring(mode_of(pkg .. "/files/save")))
  check("存档目录被修正", mode_of(save) == 770, tostring(mode_of(save)))
  check("包目录本身不动", mode_of(pkg) == pkg_mode_before, tostring(mode_of(pkg)))
  rmrf(root)
end

do -- 非 Android 平台什么都不做
  local root = mktemp_root()
  os.execute("mkdir -p '" .. root .. "/Android/data/com.test/files'")
  love = make_love(root, "OS X")
  local before = love.filesystem.setIdentity
  M.install()
  love.filesystem.setIdentity("Balatro-Modded")
  check("非 Android 时不动 setIdentity", love.filesystem.setIdentity == before)
  check("非 Android 时不建 save", mode_of(root .. "/Android/data/com.test/files/save") == nil)
  rmrf(root)
end

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("android_storage 全部通过")
