--|Android: 让存档目录能被文件管理器和 adb 读取.
--|
--|存档在 Android/data/<包名>/files/save/<存档名> 下 (conf.lua 的 t.externalstorage). 系统给
--|Android/data 下的内容用 ext_data_rw 组管理访问: 其他应用自己建的目录是 0770/2770, 文件是 0660,
--|MT 管理器, adb shell 这类带该组权限的工具都能读. LÖVE 用 PhysicsFS 读写, 而它在 POSIX 上把
--|权限写死为目录 0700, 文件 0600 (physfs_platform_posix.c), 组权限一开始就没有, umask 也补不回来.
--|结果是外部工具只能看到一个空的 save 目录.
--|
--|另外 PhysicsFS 的 mkdir 不补父目录: 新装的包第一次启动时 files/save 这一层还不存在, 存档目录
--|会直接建失败 (日志里是 "Could not create save directory"). 所以在 setIdentity 之后补一次:
--|缺哪几级就 mkdir 哪几级, 再让 PhysicsFS 重设一次写目录.
--|
--|这里在建好之后补上组权限: 目录 2770, 文件 0660, 与系统给 Android/data 的权限一致.
--|同时还试着把属组改成 ext_data_rw: 带组权限的工具都在这个组里, 而应用建的条目属组是应用自己.
--|改不动属组时 (进程不在该组, 实测设备上如此) 改用 other 位兜底 (目录 0777, 文件 0666): 能进
--|Android/data/<包名> 的工具本来就只有本应用, adb shell 和有存储权限的文件管理器.
--|例外是含密钥的配置文件 (config/balatrobot.jkr): 保持 0600, 不给组权限, 见 PRIVATE_FILES.
--|时机有三个:
--|- 存档目录确定时 (love.init 里的 setIdentity) 整棵树扫一遍, 修正以前留下的文件.
--|- 主线程经 love.filesystem 写入, 追加, 建目录之后, 立即修正这个路径及其上级目录.
--|- 存档线程是独立的 Lua 状态, 包装不到; io.open 之类也不经过 love.filesystem. 失去焦点
--|  或切到后台时再扫一遍, 此时 user 最可能去文件管理器里看.
--|只在 Android 上生效, 任何一步失败都只打印一行日志, 不影响游戏.

local M = {}

local DIR_MODE = tonumber("2770", 8)
local FILE_MODE = tonumber("0660", 8)
-- 改不了属组时的兜底 (见 apply_*): 组权限位对别的工具没用 (它们的组不是本应用), 只能靠 other 位.
local OPEN_DIR_MODE = tonumber("0777", 8)
local OPEN_FILE_MODE = tonumber("0666", 8)
local PRIVATE_MODE = tonumber("0600", 8)
local SWEEP_DEBOUNCE = 2 -- 失去焦点与切到后台常常接连发生, 间隔内只扫一次

--|含密钥的文件: 保持 0600, 不给组权限, 扫描时也不放宽. PhysicsFS 本来就按 0600 写, 这里只是不让
--|别的步骤把它带成 0660. 路径相对存档目录, 用半角小写匹配.
local PRIVATE_FILES = {
  ["config/balatrobot.jkr"] = true,
}

local DT_UNKNOWN, DT_DIR, DT_REG, DT_LNK = 0, 4, 8, 10

local ffi, C
local root -- 存档目录的绝对路径, 不在 Android/data 下时为 nil
local identity_name -- 最近一次 setIdentity 用的存档名, 补建目录后要重新设一次
local real_set_identity -- love.filesystem.setIdentity 的原实现
local target_gid -- 系统给 Android/data/<包名> 的属组 (ext_data_rw), 拿不到时为 nil
local group_ok -- 上一次改属组是否成功, nil 表示还没试过
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

--- 取一个路径的属主与权限位. 不依赖 struct stat 的完整布局, 只按 ABI 读前面几个字段.
--- 32 位 ABI 的布局不同, 那里返回 nil (此时不改属组, 只按 mode 处理).
---@param path string
---@return {mode: integer, uid: integer, gid: integer}?
local function stat_of(path)
  local offsets -- mode, uid, gid 在 struct stat 里的字节偏移
  if jit.arch == "arm64" then
    offsets = { 16, 24, 28 }
  elseif jit.arch == "x64" then
    offsets = { 24, 28, 32 }
  else
    return nil
  end
  local buf = ffi.new("char[256]")
  if C.bb_stat(path, buf) ~= 0 then
    return nil
  end
  local function field(offset)
    return ffi.cast("uint32_t *", buf + offset)[0]
  end
  return { mode = field(offsets[1]) % 4096, uid = field(offsets[2]), gid = field(offsets[3]) }
end

--- 取一个路径的权限位与属主, 只用于日志.
---@param path string
---@return string?
local function describe_path(path)
  local st = stat_of(path)
  if not st then
    return nil
  end
  return string.format("mode %o, uid %d, gid %d", st.mode, st.uid, st.gid)
end

--- 实际要落盘的 mode. 改不动属组时 (group_ok 为 false) 目录与普通文件改用 other 位兜底.
--- 纯逻辑, 单测直接用.
---@param wanted integer
---@param kind "dir"|"file"
---@param group_ok boolean?
---@return integer
function M.effective_mode(wanted, kind, group_ok)
  if group_ok == false then
    return kind == "dir" and OPEN_DIR_MODE or OPEN_FILE_MODE
  end
  return wanted
end

--- 修正一个路径的权限, 并尽量把属组改成系统给 Android/data 的组.
--- 两件事都要做:
--- - mode: PhysicsFS 按 0700/0600 建, 组与其他位都是 0, 别的工具进不去.
--- - 属组: 应用建的条目属组是应用自己 (u0_aXXX). 带组权限的工具 (adb shell, 文件管理器) 在
---   ext_data_rw 组里, 组不匹配时 mode 的组位不起作用.
--- chown 到 ext_data_rw 需要在那个组里, 普通应用往往不在 (实测设备上 EPERM). 这时改用 other 位兜底:
--- Android/data/<包名> 本身由系统的 FUSE 拦着, 只有本应用, adb shell 和有存储权限的文件管理器
--- 能进来. 含密钥的配置文件始终 0600, 不参与兜底.
---@param path string
---@param wanted integer 期望的 mode (属组不可改时会换成兜底 mode)
---@param kind "dir"|"file"
---@return boolean chmod 成功
local function apply_mode(path, wanted, kind)
  if target_gid then
    local st = stat_of(path)
    if st and st.gid ~= target_gid then
      if group_ok == nil then
        group_ok = C.bb_chown(path, 0xFFFFFFFF, target_gid) == 0
        if not group_ok then
          log("cannot change group to %d (not a member), falling back to other-bits", target_gid)
        end
      elseif group_ok then
        C.bb_chown(path, 0xFFFFFFFF, target_gid)
      end
    end
  end
  return C.bb_chmod(path, M.effective_mode(wanted, kind, group_ok)) == 0
end

---@param path string
---@return boolean
local function apply_dir(path)
  return apply_mode(path, DIR_MODE, "dir")
end

---@param path string
---@return boolean
local function apply_file(path)
  return apply_mode(path, FILE_MODE, "file")
end

--- 含密钥的配置: 永远 0600, 不给组与其他任何权限.
---@param path string
---@return boolean
local function apply_private(path)
  return C.bb_chmod(path, PRIVATE_MODE) == 0
end

--- 路径存在吗 (目录能打开即算存在).
---@param path string
---@return boolean
local function exists(path)
  local dir = C.bb_opendir(path)
  if dir == nil then
    return false
  end
  C.bb_closedir(dir)
  return true
end

--- 把 path 里缺失的各级目录建出来. PhysicsFS 的 mkdir 不补父目录, 新装的包第一次启动时
--- files/save 还不存在, 存档目录就建不起来 (日志里是 "Could not create save directory").
--- 这里从最上面缺失的一级开始逐级 mkdir.
--- mkdir 传入的模式会被进程的 umask 削掉组权限位 (实测 Android 上是 0077, 2770 会变成 2700),
--- 所以建完再 chmod 一次.
---@param path string
---@return integer created
local function ensure_dirs(path)
  if exists(path) then
    return 0
  end
  local prefix = path:sub(1, 1) == "/" and "" or "."
  local created = 0
  for part in path:gmatch("[^/]+") do
    prefix = prefix .. "/" .. part
    if not exists(prefix) then
      if C.bb_mkdir(prefix, DIR_MODE) ~= 0 then
        -- 建不出来就不再往下试, 后面的父目录一定也缺
        break
      end
      apply_dir(prefix)
      created = created + 1
    end
  end
  return created
end

--- 存档目录建不起来时补一次: 先把父目录建好, 再让 PhysicsFS 重新设一次写目录.
---@return boolean ok
local function ensure_save_directory()
  if exists(root) then
    return true
  end
  local created = ensure_dirs(root)
  log("save directory was missing, created %d level(s) for %s", created, root)
  if real_set_identity and identity_name then
    pcall(real_set_identity, identity_name)
  end
  if not exists(root) then
    log("save directory still missing: %s", root)
    return false
  end
  return true
end

--- 修正存档目录与包目录之间各级目录的权限.
--- 这些目录 (files, save) 由 PhysicsFS 按 0700 建出来, 进程 umask 又削掉组权限位, 于是最终是 2700:
--- 别的工具连进都进不去, 更看不到里面的内容. 它们不常被写, 扫描也够不到 (扫描从存档目录往下),
--- 所以启动时单独修一遍. 包目录本身 (Android/data/<包名>) 由系统建, 不动.
---@return integer fixed
local function fix_ancestors()
  local base = root:match("^(.*/Android/data/[^/]+)/")
  if not base then
    return 0
  end
  local fixed = 0
  local path = base
  for part in root:sub(#base + 2):gmatch("[^/]+") do
    path = path .. "/" .. part
    if apply_dir(path) then
      fixed = fixed + 1
    end
  end
  return fixed
end

--|递归修正 path 下的权限. rel 是 path 相对存档目录的路径 (存档目录本身是 ""), 用来认含密钥的文件.
--|stats: {dirs, files, private, failed, broken}.
--|在一个目录里没读到 "." 时认为 dirent 布局不对, 标记 broken 并停止, 不拿错误的名字去改权限.
local function walk(path, rel, stats)
  if apply_dir(path) then
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
      walk(full, join_rel(rel, child.name), stats)
    elseif kind == DT_REG then
      local child_rel = join_rel(rel, child.name)
      if PRIVATE_FILES[child_rel] then
        if apply_private(full) then
          stats.private = stats.private + 1
        else
          stats.failed = stats.failed + 1
        end
      elseif apply_file(full) then
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
  local walked = ""
  apply_dir(path)
  for part in rel:gmatch("[^/]+") do
    path = path .. "/" .. part
    walked = join_rel(walked, part)
    local dir = C.bb_opendir(path)
    if dir ~= nil then
      C.bb_closedir(dir)
      apply_dir(path)
    elseif PRIVATE_FILES[walked] then
      -- 含密钥的配置: 写入后立刻收回组权限, 免得被扫成 0660
      apply_private(path)
    else
      apply_file(path)
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
  root = dir:gsub("/+$", "")
  -- 目标属组取自系统建的包目录 (Android/data/<包名>), 它一直是 ext_data_rw. 每个设备的值不同, 不写死.
  local package_dir = root:match("^(.*/Android/data/[^/]+)/")
  local pkg_stat = package_dir and stat_of(package_dir)
  target_gid = pkg_stat and pkg_stat.gid or nil
  if not ensure_save_directory() then
    return
  end
  local fixed = fix_ancestors()
  M.sweep("startup")
  -- 每次启动打一行: 存档目录的权限位与属主, 用来核对文件管理器会看到什么.
  log("save directory ready (%d ancestors fixed): %s", fixed, tostring(describe_path(root)))
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
  local ok = pcall(fix_written, path:sub(#prefix + 1))
  return ok
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
    identity_name = name
    local ok = real_set_identity(name, ...)
    local done, err = pcall(on_identity)
    if not done then
      log("setup failed: %s", tostring(err))
    end
    return ok
  end
end

return M
