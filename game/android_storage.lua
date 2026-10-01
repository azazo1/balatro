--|Android: 让存档目录能被文件管理器和 adb 读取.
--|
--|存档在 Android/data/<包名>/files/save/<存档名> 下 (conf.lua 的 t.externalstorage). 系统给
--|Android/data 下的内容用 ext_data_rw 组管理访问: 其他应用自己建的目录是 0770/2770, 文件是 0660,
--|MT 管理器, adb shell 这类带该组权限的工具都能读. LÖVE 用 PhysicsFS 读写, 而它在 POSIX 上把
--|权限写死为目录 0700, 文件 0600 (physfs_platform_posix.c), 组权限一开始就没有, umask 也补不回来.
--|结果是外部工具只能看到一个空的 save 目录.
--|
--|这里在建好之后补上组权限: 目录 2770, 文件 0660, 与系统给 Android/data 的权限一致.
--|- 存档目录确定时 (love.init 里的 setIdentity) 整棵树扫一遍, 修正以前留下的文件.
--|- 主线程经 love.filesystem 写入, 追加, 建目录之后, 立即修正这个路径及其上级目录.
--|- 存档线程是独立的 Lua 状态, 包装不到; io.open 之类也不经过 love.filesystem. 失去焦点
--|  或切到后台时再扫一遍, 此时 user 最可能去文件管理器里看.
--|只在 Android 上生效, 任何一步失败都只打印一行日志, 不影响游戏.

local M = {}

local DIR_MODE = tonumber("2770", 8)
local FILE_MODE = tonumber("0660", 8)
local SWEEP_DEBOUNCE = 2 -- 失去焦点与切到后台常常接连发生, 间隔内只扫一次

local DT_UNKNOWN, DT_DIR, DT_REG, DT_LNK = 0, 4, 8, 10

local ffi, C
local root -- 存档目录的绝对路径, 不在 Android/data 下时为 nil
local last_sweep = -math.huge
local hooked = false

local function log(fmt, ...)
  print("[android_storage] " .. string.format(fmt, ...))
end

local function clock()
  return love.timer and love.timer.getTime() or os.clock()
end

--|bionic 在所有 ABI 上都用 __DIRENT64_BODY 定义 struct dirent, 布局与下面一致.
--|函数用 asm 标签换成 bb_ 前缀的名字, 不占用 opendir 等常见名字, 免得和 mod 里的 ffi.cdef 冲突.
local function load_ffi()
  local ok, lib = pcall(require, "ffi")
  if not ok then
    return false
  end
  ffi = lib
  ok = pcall(ffi.cdef, [[
    struct bb_dirent {
      uint64_t d_ino;
      int64_t d_off;
      unsigned short d_reclen;
      unsigned char d_type;
      char d_name[256];
    };
    int bb_chmod(const char *path, unsigned int mode) __asm__("chmod");
    void *bb_opendir(const char *path) __asm__("opendir");
    struct bb_dirent *bb_readdir(void *dir) __asm__("readdir");
    int bb_closedir(void *dir) __asm__("closedir");
  ]])
  if not ok then
    return false
  end
  C = ffi.C
  return true
end

--|递归修正 path 下的权限. stats: {dirs, files, failed, broken}.
--|在一个目录里没读到 "." 时认为 dirent 布局不对, 标记 broken 并停止, 不拿错误的名字去改权限.
local function walk(path, stats)
  if C.bb_chmod(path, DIR_MODE) == 0 then
    stats.dirs = stats.dirs + 1
  else
    stats.failed = stats.failed + 1
  end
  local dir = C.bb_opendir(path)
  if dir == nil then
    return
  end
  local seen_dot = false
  local children = {}
  while true do
    local entry = C.bb_readdir(dir)
    if entry == nil then
      break
    end
    local name = ffi.string(entry.d_name)
    if name == "." then
      seen_dot = true
    elseif name ~= ".." then
      children[#children + 1] = { name = name, kind = entry.d_type }
    end
  end
  C.bb_closedir(dir)
  if not seen_dot then
    stats.broken = true
    return
  end
  for _, child in ipairs(children) do
    if stats.broken then
      return
    end
    local full = path .. "/" .. child.name
    local kind = child.kind
    if kind == DT_UNKNOWN then
      local probe = C.bb_opendir(full)
      if probe ~= nil then
        C.bb_closedir(probe)
        kind = DT_DIR
      else
        kind = DT_REG
      end
    end
    if kind == DT_DIR then
      walk(full, stats)
    elseif kind == DT_REG then
      if C.bb_chmod(full, FILE_MODE) == 0 then
        stats.files = stats.files + 1
      else
        stats.failed = stats.failed + 1
      end
    end
    -- DT_LNK 等其余类型不动
  end
end

--|整棵树扫一遍.
---@param reason string
function M.sweep(reason)
  if not root then
    return
  end
  local started = clock()
  last_sweep = started
  local stats = { dirs = 0, files = 0, failed = 0, broken = false }
  local ok, err = pcall(walk, root, stats)
  if not ok then
    log("sweep (%s) failed: %s", reason, tostring(err))
  elseif stats.broken then
    log("sweep (%s) stopped: readdir did not return '.', dirent layout may differ", reason)
  else
    log(
      "sweep (%s): %d dirs, %d files, %d failed, %.0f ms",
      reason,
      stats.dirs,
      stats.files,
      stats.failed,
      (clock() - started) * 1000
    )
  end
end

--|修正一次写入涉及的路径: 从存档目录往下, 每一级目录 2770, 最后一级按实际类型处理.
---@param rel string 相对存档目录的路径
local function fix_written(rel)
  if not root or type(rel) ~= "string" then
    return
  end
  rel = rel:gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
  if rel == "" or rel:find("%.%.") then
    return
  end
  local path = root
  C.bb_chmod(path, DIR_MODE)
  for part in rel:gmatch("[^/]+") do
    path = path .. "/" .. part
    local dir = C.bb_opendir(path)
    if dir ~= nil then
      C.bb_closedir(dir)
      C.bb_chmod(path, DIR_MODE)
    else
      C.bb_chmod(path, FILE_MODE)
    end
  end
end

--|包装 love.filesystem 的写函数: 调用成功后修正路径, 返回值原样传回.
local function wrap_writer(name)
  local orig = love.filesystem[name]
  if type(orig) ~= "function" then
    return
  end
  local function finish(path, ok, ...)
    if ok then
      pcall(fix_written, path)
    end
    return ok, ...
  end
  love.filesystem[name] = function(path, ...)
    return finish(path, orig(path, ...))
  end
end

--|失去焦点, 切到后台时扫一遍. love.handlers 在 love.init 调用 setIdentity 之前已经建好.
local function hook_handlers()
  if hooked or not love.handlers then
    return
  end
  hooked = true
  local function on_leave(label)
    if clock() - last_sweep >= SWEEP_DEBOUNCE then
      M.sweep(label)
    end
  end
  local focus = love.handlers.focus
  love.handlers.focus = function(f, ...)
    if not f then
      on_leave("focus lost")
    end
    if focus then
      return focus(f, ...)
    end
  end
  local visible = love.handlers.visible
  love.handlers.visible = function(v, ...)
    if not v then
      on_leave("hidden")
    end
    if visible then
      return visible(v, ...)
    end
  end
end

local function on_identity()
  local dir = love.filesystem.getSaveDirectory()
  if type(dir) ~= "string" or not dir:find("/Android/data/", 1, true) then
    root = nil
    log("save directory %s is not under Android/data, permissions left as is", tostring(dir))
    return
  end
  root = dir:gsub("/+$", "")
  M.sweep("startup")
  hook_handlers()
end

--|在 conf.lua 里调用. 非 Android 或取不到 ffi 时什么都不做.
function M.install()
  if love._os ~= "Android" or not love.filesystem then
    return
  end
  if not load_ffi() then
    log("ffi unavailable, save directory stays private")
    return
  end
  for _, name in ipairs({ "write", "append", "createDirectory" }) do
    wrap_writer(name)
  end
  local set_identity = love.filesystem.setIdentity
  love.filesystem.setIdentity = function(...)
    local ok = set_identity(...)
    local done, err = pcall(on_identity)
    if not done then
      log("setup failed: %s", tostring(err))
    end
    return ok
  end
end

return M
