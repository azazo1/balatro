--|Android: 让存档目录能被文件管理器和 adb 读取.
--|
--|存档在 Android/data/<包名>/files/save/<存档名> 下 (conf.lua 的 t.externalstorage). 下面几点在真机上
--|实测确认, 详见 docs/builtin-agent.md:
--|- LÖVE 用的 PhysicsFS 把权限写死为目录 0700, 文件 0600, 而且 mkdir 不补父目录: 新装的包第一次启动时
--|  files/save 不存在, 存档目录直接建失败. 所以要逐级补建.
--|- 进程 umask 是 0077, mkdir 请求的组位会被削掉, 但 chmod 有效, 所以建完再 chmod.
--|- adb shell, MT 管理器靠 ext_data_rw 组访问 Android/data, 而应用建的条目属组是应用自己, chown 到该组
--|  会 EPERM. 所以先试改属组 (目录 2770, 文件 0660), 改不动就退回 other 位 (目录 0777, 文件 0666):
--|  Android/data/<包名> 由系统的 FUSE 拦着, 能进来的只有本应用, adb shell 和有存储权限的文件管理器.
--|- 含密钥的配置 (PRIVATE_FILES) 始终 0600.
--|
--|时机有三个:
--|- setIdentity 之后: 补建缺失的目录, 修正 files, save 这几级 (扫描从存档目录往下, 够不到它们),
--|  再把存档目录整棵扫一遍, 修正以前留下的文件.
--|- 主线程经 love.filesystem 写入, 追加, 建目录之后, 立即修正这个路径及其上级目录.
--|- 存档线程是独立的 Lua 状态, 包装不到; io.open 之类也不经过 love.filesystem. 失去焦点
--|  或切到后台时再扫一遍, 此时 user 最可能去文件管理器里看.
--|只在 Android 上生效, 任何一步失败都只打印一行日志, 不影响游戏.

local M = {}

local DIR_MODE = tonumber("2770", 8)
local FILE_MODE = tonumber("0660", 8)
local OPEN_DIR_MODE = tonumber("0777", 8)
local OPEN_FILE_MODE = tonumber("0666", 8)
local PRIVATE_MODE = tonumber("0600", 8)
local SWEEP_DEBOUNCE = 2 -- 失去焦点与切到后台常常接连发生, 间隔内只扫一次

--|含密钥的文件, 路径相对存档目录.
local PRIVATE_FILES = {
  ["config/balatrobot.jkr"] = true,
}

local DT_UNKNOWN, DT_DIR, DT_REG = 0, 4, 8

local ffi, C
local root -- 存档目录的绝对路径
local real_set_identity -- love.filesystem.setIdentity 的原实现
local target_gid -- 包目录 Android/data/<包名> 的属组 (ext_data_rw), 拿不到时为 nil
local group_ok -- 改属组是否可行, nil 表示还没试过
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
--|只装载一次: 重复 install (例如测试里换一套 love) 时 ffi.cdef 不允许重定义同一个结构体.
local function load_ffi()
  if ffi ~= nil then
    return true
  end
  local ok, lib = pcall(require, "ffi")
  if not ok then
    return false
  end
  ok = pcall(lib.cdef, [[
    struct bb_dirent {
      uint64_t d_ino;
      int64_t d_off;
      unsigned short d_reclen;
      unsigned char d_type;
      char d_name[256];
    };
    int bb_chmod(const char *path, unsigned int mode) __asm__("chmod");
    int bb_mkdir(const char *path, unsigned int mode) __asm__("mkdir");
    int bb_stat(const char *path, void *buf) __asm__("stat");
    int bb_chown(const char *path, unsigned int uid, unsigned int gid) __asm__("chown");
    void *bb_opendir(const char *path) __asm__("opendir");
    struct bb_dirent *bb_readdir(void *dir) __asm__("readdir");
    int bb_closedir(void *dir) __asm__("closedir");
  ]])
  if not ok then
    return false
  end
  ffi = lib
  C = ffi.C
  return true
end

--- 相对存档目录的路径拼接: 存档目录本身是 "", 其下第一级不带前导斜杠, 与 PRIVATE_FILES 的键一致.
---@param rel string
---@param name string
---@return string
local function join_rel(rel, name)
  if rel == "" then
    return name
  end
  return rel .. "/" .. name
end

--- 取一个路径的属组. 不声明完整的 struct stat, 只按 64 位 ABI 的偏移读 st_gid;
--- 其他 ABI 返回 nil, 此时不改属组, 只改 mode.
---@param path string
---@return integer?
local function gid_of(path)
  local offset = (jit.arch == "arm64" and 28) or (jit.arch == "x64" and 32) or nil
  if not offset then
    return nil
  end
  local buf = ffi.new("char[256]")
  if C.bb_stat(path, buf) ~= 0 then
    return nil
  end
  return ffi.cast("uint32_t *", buf + offset)[0]
end

--- 修正一个目录或普通文件: 先试把属组改成 target_gid, 再 chmod. 第一次 chown 失败后不再尝试,
--- 之后一律用 other 位兜底.
---@param path string
---@param kind "dir"|"file"
---@return boolean chmod 成功
local function apply(path, kind)
  if target_gid and group_ok ~= false and gid_of(path) ~= target_gid then
    local changed = C.bb_chown(path, 0xFFFFFFFF, target_gid) == 0
    if group_ok == nil then
      group_ok = changed
      if not changed then
        log("cannot change group to %d (not a member), falling back to other-bits", target_gid)
      end
    end
  end
  local mode
  if group_ok == false then
    mode = kind == "dir" and OPEN_DIR_MODE or OPEN_FILE_MODE
  else
    mode = kind == "dir" and DIR_MODE or FILE_MODE
  end
  return C.bb_chmod(path, mode) == 0
end

--- 修正一个普通文件, 含密钥的配置固定 0600.
---@param path string
---@param rel string 相对存档目录的路径
---@return boolean chmod 成功, boolean 是否含密钥
local function apply_file(path, rel)
  if PRIVATE_FILES[rel] then
    return C.bb_chmod(path, PRIVATE_MODE) == 0, true
  end
  return apply(path, "file"), false
end

---@param path string
---@return boolean
local function is_dir(path)
  local dir = C.bb_opendir(path)
  if dir == nil then
    return false
  end
  C.bb_closedir(dir)
  return true
end

--- 从包目录往下到存档目录, 缺的逐级 mkdir, 每一级都修正权限. 包目录本身由系统建, 不动.
---@param base string 包目录 Android/data/<包名>
---@return integer created
local function prepare_levels(base)
  local created = 0
  local path = base
  for part in root:sub(#base + 2):gmatch("[^/]+") do
    path = path .. "/" .. part
    if not is_dir(path) then
      if C.bb_mkdir(path, DIR_MODE) ~= 0 then
        break -- 下面几级一定也建不出来
      end
      created = created + 1
    end
    apply(path, "dir")
  end
  return created
end

--|递归修正 path 下的权限. rel 是 path 相对存档目录的路径, 用来认含密钥的文件.
--|在一个目录里没读到 "." 时认为 dirent 布局不对, 标记 broken 并停止, 不拿错误的名字去改权限.
local function walk(path, rel, stats)
  if apply(path, "dir") then
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
    local child_rel = join_rel(rel, child.name)
    local kind = child.kind
    if kind == DT_UNKNOWN then
      kind = is_dir(full) and DT_DIR or DT_REG
    end
    if kind == DT_DIR then
      walk(full, child_rel, stats)
    elseif kind == DT_REG then
      local ok, private = apply_file(full, child_rel)
      if not ok then
        stats.failed = stats.failed + 1
      elseif private then
        stats.private = stats.private + 1
      else
        stats.files = stats.files + 1
      end
    end
    -- 符号链接等其余类型不动
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
  local stats = { dirs = 0, files = 0, private = 0, failed = 0, broken = false }
  local ok, err = pcall(walk, root, "", stats)
  if not ok then
    log("sweep (%s) failed: %s", reason, tostring(err))
  elseif stats.broken then
    log("sweep (%s) stopped: readdir did not return '.', dirent layout may differ", reason)
  else
    log(
      "sweep (%s): %d dirs, %d files, %d private, %d failed, %.0f ms",
      reason,
      stats.dirs,
      stats.files,
      stats.private,
      stats.failed,
      (clock() - started) * 1000
    )
  end
end

--|修正一次写入涉及的路径: 从存档目录往下, 每一级按实际类型处理.
---@param rel string 相对存档目录的路径
local function fix_written(rel)
  if not root then
    return
  end
  rel = rel:gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
  if rel == "" or rel:find("%.%.") then
    return
  end
  local path = root
  local walked = ""
  apply(path, "dir")
  for part in rel:gmatch("[^/]+") do
    path = path .. "/" .. part
    walked = join_rel(walked, part)
    if is_dir(path) then
      apply(path, "dir")
    else
      apply_file(path, walked)
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
  if hooked then
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

---@param name string setIdentity 的存档名, 补建目录后用它让 PhysicsFS 重设一次写目录
local function on_identity(name)
  root = love.filesystem.getSaveDirectory():gsub("/+$", "")
  -- 目标属组取自系统建的包目录, 每个设备的值不同, 不写死.
  local base = root:match("^(.*/Android/data/[^/]+)/")
  target_gid = base and gid_of(base)
  local missing = not is_dir(root)
  local created = base and prepare_levels(base) or 0
  if missing then
    log("save directory was missing, created %d level(s) for %s", created, root)
    pcall(real_set_identity, name)
    if not is_dir(root) then
      log("save directory still missing: %s", root)
      return
    end
  end
  M.sweep("startup")
  hook_handlers()
end

--- 修正存档目录下的一个绝对路径 (目录或文件).
--- 给不走 love.filesystem 的写入用: 录像线程与后台合成脚本产生的文件, 存档线程写的存档等.
--- 路径不在存档目录下时什么都不做. 返回是否处理过.
---@param path string
---@return boolean
function M.fix_path(path)
  if not root or type(path) ~= "string" then
    return false
  end
  local prefix = root .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return false
  end
  return (pcall(fix_written, path:sub(#prefix + 1)))
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
  real_set_identity = love.filesystem.setIdentity
  love.filesystem.setIdentity = function(name, ...)
    local ok = real_set_identity(name, ...)
    local done, err = pcall(on_identity, name)
    if not done then
      log("setup failed: %s", tostring(err))
    end
    return ok
  end
end

return M
