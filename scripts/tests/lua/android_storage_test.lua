-- Android 存档目录权限模块的单元测试, 用 luajit 在仓库根目录运行: just test-agent
-- 在 macOS/Linux 上跑: chmod, mkdir, opendir 的行为与本机一致, 可以真实验证目录补建与权限修正.
-- 目录遍历 (walk) 依赖 bionic 的 struct dirent 布局, 在开发机上会判定布局不符并停止, 这里不覆盖.

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

---@param path string
---@return integer? mode 八进制权限位
local function mode_of(path)
  local pipe = io.popen("stat -f %Lp '" .. path .. "' 2>/dev/null")
  local out = pipe and pipe:read("*a")
  if pipe then
    pipe:close()
  end
  return tonumber((out or ""):match("%d+"))
end

---@param path string
local function exists(path)
  local pipe = io.popen("[ -e '" .. path .. "' ] && echo y")
  local out = pipe and pipe:read("*a")
  if pipe then
    pipe:close()
  end
  return (out or ""):find("y") ~= nil
end

local function mktemp_root()
  local pipe = io.popen("mktemp -d")
  local dir = (pipe:read("*a")):gsub("%s+$", "")
  pipe:close()
  return dir
end

--- 假环境: love.filesystem 只实现本模块用到的那几个函数, 写到本机的临时目录里.
---@param root string 临时目录
---@param os_name string
local function make_love(root, os_name)
  local files = {}
  local fs = {}
  local save = root .. "/Android/data/com.test/files/save/Balatro-Modded"

  function fs.getSaveDirectory()
    return files.identity and save or (root .. "/Android/data/com.test/files")
  end
  -- 真实 LÖVE 在 POSIX 上不补父目录: files/save 不存在时它会失败并打印
  -- "Could not create save directory". 这里就照这个行为, 目录由 android_storage 自己补.
  function fs.setIdentity(name)
    files.identity = name
    return true
  end
  --- 相对路径按 LÖVE 的规则解析: 设了存档名之后是相对存档目录, 否则相对存档根目录.
  local function resolve(path)
    if path:sub(1, 1) == "/" then
      return path
    end
    local base = files.identity and save or (root .. "/Android/data/com.test/files")
    return base .. "/" .. path
  end
  function fs.createDirectory(path)
    local pipe = io.popen("mkdir -p '" .. resolve(path) .. "' 2>/dev/null")
    local ok = pipe and pipe:close()
    return ok ~= nil
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
  function fs.remove(path)
    os.remove(resolve(path))
    return true
  end

  return {
    _os = os_name,
    filesystem = fs,
    timer = { getTime = function() return os.clock() end },
    mouse = { setVisible = function() end },
    handlers = {},
    graphics = { getWidth = function() return 100 end },
  }
end

local function rmrf(path)
  os.execute("chmod -R u+w '" .. path .. "' 2>/dev/null; rm -rf '" .. path .. "'")
end

do -- 存档名的父目录缺失时补建, 并把存档目录本身按目录模式建出来
  local root = mktemp_root()
  os.execute("mkdir -p '" .. root .. "/Android/data/com.test/files'")
  love = make_love(root, "Android")
  M.install()
  check("父目录缺失时 setIdentity 仍返回成功", love.filesystem.setIdentity("Balatro-Modded") == true)
  local save = root .. "/Android/data/com.test/files/save/Balatro-Modded"
  check("补建出 save 与存档目录", exists(save))
  -- 只比低三位: macOS 不保留 setgid 位, Android 上才是 2770
  check("补建的目录是 0770", mode_of(save) % 1000 == 770, tostring(mode_of(save)))
  check("中间层 save 也是 0770", mode_of(root .. "/Android/data/com.test/files/save") % 1000 == 770)
  rmrf(root)
end

do -- 目录已经存在时不重复建, 也不改坏
  local root = mktemp_root()
  local save = root .. "/Android/data/com.test/files/save/Balatro-Modded"
  os.execute("mkdir -p '" .. save .. "' && chmod 700 '" .. save .. "'")
  love = make_love(root, "Android")
  M.install()
  love.filesystem.setIdentity("Balatro-Modded")
  check("已存在的存档目录被扫成 0770", mode_of(save) % 1000 == 770, tostring(mode_of(save)))
  rmrf(root)
end

do -- 写入之后的权限修正: 目录 2770, 普通文件 0660, 含密钥的配置 0600
  local root = mktemp_root()
  os.execute("mkdir -p '" .. root .. "/Android/data/com.test/files'")
  love = make_love(root, "Android")
  M.install()
  love.filesystem.setIdentity("Balatro-Modded")

  love.filesystem.createDirectory("config")
  love.filesystem.write("config/balatrobot.jkr", "secret")
  love.filesystem.write("settings.jkr", "s")
  local save = root .. "/Android/data/com.test/files/save/Balatro-Modded"
  check("含密钥的配置是 0600", mode_of(save .. "/config/balatrobot.jkr") == 600, tostring(mode_of(save .. "/config/balatrobot.jkr")))
  check("配置目录是 0770", mode_of(save .. "/config") % 1000 == 770, tostring(mode_of(save .. "/config")))
  check("普通存档文件是 0660", mode_of(save .. "/settings.jkr") == 660, tostring(mode_of(save .. "/settings.jkr")))
  rmrf(root)
end

do -- 改不动属组时的兜底: 目录 0777, 普通文件 0666, 含密钥的配置不受影响
  check("属组可改时目录是 2770", M.effective_mode(tonumber("2770", 8), "dir", true) == tonumber("2770", 8))
  check("属组可改时文件是 0660", M.effective_mode(tonumber("0660", 8), "file", true) == tonumber("0660", 8))
  check("尚未试过时不动", M.effective_mode(tonumber("2770", 8), "dir", nil) == tonumber("2770", 8))
  check("属组不可改时目录是 0777", M.effective_mode(tonumber("2770", 8), "dir", false) == tonumber("0777", 8))
  check("属组不可改时文件是 0666", M.effective_mode(tonumber("0660", 8), "file", false) == tonumber("0666", 8))
  -- 含密钥的配置不走这两个入口, 单独 chmod 0600
  check("私有模式是 0600", tonumber("600", 8) == 384)
end

do -- 早期版本留下的 2700 目录: 启动时把存档目录到包目录之间的各级修正成 0770
  local root = mktemp_root()
  local pkg = root .. "/Android/data/com.test"
  local save = pkg .. "/files/save/Balatro-Modded"
  -- 模拟 PhysicsFS 与 umask 0077 的结果: 组权限位被削掉
  os.execute("mkdir -p '" .. save .. "' && chmod 700 '" .. pkg .. "/files' && chmod 700 '" .. pkg .. "/files/save' && chmod 700 '" .. save .. "'")
  local pkg_mode_before = mode_of(pkg)
  love = make_love(root, "Android")
  M.install()
  love.filesystem.setIdentity("Balatro-Modded")
  check("补建不到的 files 被修正", mode_of(pkg .. "/files") % 1000 == 770, tostring(mode_of(pkg .. "/files")))
  check("补建不到的 save 被修正", mode_of(pkg .. "/files/save") % 1000 == 770, tostring(mode_of(pkg .. "/files/save")))
  check("包目录本身不动", mode_of(pkg) == pkg_mode_before, tostring(mode_of(pkg)))
  rmrf(root)
end

do -- 非 Android 平台什么都不做: 不建目录, 不换 setIdentity
  local root = mktemp_root()
  os.execute("mkdir -p '" .. root .. "/Android/data/com.test/files'")
  love = make_love(root, "OS X")
  local before = love.filesystem.setIdentity
  M.install()
  check("非 Android 时不动 setIdentity", love.filesystem.setIdentity == before)
  check("非 Android 时不建 save", not exists(root .. "/Android/data/com.test/files/save"))
  rmrf(root)
end

if failures > 0 then
  print(string.format("%d 项失败", failures))
  os.exit(1)
end
print("android_storage 全部通过")
