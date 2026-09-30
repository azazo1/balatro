--[[
lovely 运行时替身.

补丁已经在打包时由 scripts/lib/modding 按 lovely 的规则打进游戏与 mod 文件, 这里只提供
mod 在运行时依赖的部分:

- require "lovely" 得到的模块: mod_dir, version, 变量存储, apply_patches 等.
- 模块补丁: 把打包时处理好的模块源码登记到 package.preload; load_now 模块在目标文件执行前求值.
- 首次启动或更新后, 把包内的 mod 释放到存档目录的 Mods 下, smods 按真实文件读取它们.
- LÖVE 内置着色器头部的 pattern 补丁, 在 love.graphics._shaderCodeToGLSL 的结果上重放.

目录名 lovely_shim 与 scripts/lib/modding/build.py 中的 SHIM_DIR 保持一致.
]]

local SHIM_DIR = "lovely_shim"
local MODS_DIR = "Mods"
local STAMP_PATH = MODS_DIR .. "/lovely/lovely-shim-bundle.txt"
local LOG_DIR = MODS_DIR .. "/lovely/log"
local LOG_PATH = LOG_DIR .. "/lovely-shim.log"
-- 存档目录中释放记录的格式版本, 格式变化时递增, 旧记录会被视为无效并重新释放.
local STAMP_FORMAT = "1"
local REPO = "https://github.com/ethangreen-dev/lovely-injector"

local M = {}
local manifest = require(SHIM_DIR .. ".manifest")
M.manifest = manifest

local booted = false

-- ---------------------------------------------------------------- 日志

-- 存档目录在 conf 阶段之后才确定, 在此之前的日志先缓存.
local pending = {}
local log_ready = false

local function now()
    if love.timer then return love.timer.getTime() end
    return os.clock()
end

local function log(level, fmt, ...)
    local ok, message = pcall(string.format, fmt, ...)
    if not ok then message = tostring(fmt) end
    local line = string.format("%s [%s] %s", os.date("%H:%M:%S"), level, message)
    if level ~= "DEBUG" then
        print("[lovely-shim] " .. level .. " " .. message)
    end
    if log_ready then
        love.filesystem.append(LOG_PATH, line .. "\n")
    else
        pending[#pending + 1] = line
    end
end
M.log = log

local function open_log()
    love.filesystem.createDirectory(LOG_DIR)
    local header = string.format("lovely-shim %s, lovely %s, 构建 %s, 系统 %s\n",
        manifest.runtime_version, manifest.lovely_version, manifest.build_version,
        love.system and love.system.getOS() or "?")
    log_ready = love.filesystem.write(LOG_PATH, header) and true or false
    if log_ready then
        for _, line in ipairs(pending) do
            love.filesystem.append(LOG_PATH, line .. "\n")
        end
    end
    pending = {}
end

-- ---------------------------------------------------------------- 变量存储

-- lovely 的变量存在进程内存里, 能跨过 love.event.quit("restart") 保留, 进程退出后消失.
-- smods 靠这一点在重启后识别自己触发的重启. Lua 状态在重启时会重建, 因此借用进程环境变量.
local env_get, env_set

do
    local ok, ffi = pcall(require, "ffi")
    if ok then
        local C = ffi.C
        if ffi.os == "Windows" then
            pcall(ffi.cdef, [[
                unsigned long GetEnvironmentVariableA(const char *name, char *buffer, unsigned long size);
                int SetEnvironmentVariableA(const char *name, const char *value);
            ]])
            env_get = function(key)
                local size = C.GetEnvironmentVariableA(key, nil, 0)
                if size == 0 then return nil end
                local buf = ffi.new("char[?]", size)
                local n = C.GetEnvironmentVariableA(key, buf, size)
                if n == 0 or n >= size then return nil end
                return ffi.string(buf, n)
            end
            env_set = function(key, value)
                C.SetEnvironmentVariableA(key, value)
            end
        else
            pcall(ffi.cdef, [[
                char *getenv(const char *name);
                int setenv(const char *name, const char *value, int overwrite);
                int unsetenv(const char *name);
            ]])
            env_get = function(key)
                local ptr = C.getenv(key)
                if ptr == nil then return nil end
                return ffi.string(ptr)
            end
            env_set = function(key, value)
                if value == nil then C.unsetenv(key) else C.setenv(key, value, 1) end
            end
        end
    else
        local memory = {}
        env_get = function(key) return memory[key] end
        env_set = function(key, value) memory[key] = value end
    end
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function unhex(s)
    return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function check_string(value, index)
    if type(value) == "number" then return tostring(value) end
    if type(value) ~= "string" then
        error(string.format("bad argument #%d (string expected, got %s)", index, type(value)), 3)
    end
    return value
end

-- 键与值都编码为十六进制, 避免环境变量对字符的限制; 值前加 v 以区分空串与未设置.
local function var_key(key)
    return "LOVELY_SHIM_VAR_" .. hex(key)
end

local function get_var(key)
    local raw = env_get(var_key(check_string(key, 1)))
    if raw == nil or raw:sub(1, 1) ~= "v" then return nil end
    return unhex(raw:sub(2))
end

local function set_var(key, value)
    env_set(var_key(check_string(key, 1)), "v" .. hex(check_string(value, 2)))
end

local function remove_var(key)
    local value = get_var(key)
    env_set(var_key(key), nil)
    return value
end

-- ---------------------------------------------------------------- 路径

local function mod_dir()
    local base = love.filesystem.getSaveDirectory():gsub("\\", "/"):gsub("/$", "")
    return base .. "/" .. MODS_DIR
end

-- 补丁里的 {{lovely_hack:patch_dir}} 在打包时换成了 @@LOVELY_SHIM_MOD_DIR_<序号>@@.
local function resolve_mod_dirs(text)
    local base = mod_dir()
    return (text:gsub("@@LOVELY_SHIM_MOD_DIR_(%d+)@@", function(n)
        local folder = manifest.mods[tonumber(n)]
        if not folder then error("补丁目录替身引用了不存在的 mod 序号 " .. n) end
        return base .. "/" .. folder
    end))
end

-- ---------------------------------------------------------------- lovely 模块

local lovely = {
    repo = REPO,
    version = manifest.lovely_version,
}

-- 打包时已经应用了全部补丁. 只有按内容查表的虚拟目标 (如 GLSL_ES_PATCHES.fs) 需要在这里处理,
-- 其余目标拿到的内容已是补丁后的结果, 原样返回.
function lovely.apply_patches(name, buffer)
    name = check_string(name, 1)
    buffer = check_string(buffer, 2)
    local dir = manifest.content_targets[name]
    if not dir then return buffer end
    local key = love.data.encode("string", "hex", love.data.hash("sha1", buffer))
    local path = SHIM_DIR .. "/" .. dir .. "/" .. key
    if love.filesystem.getInfo(path, "file") then
        log("DEBUG", "%s: 使用预先计算的结果 %s", name, key)
        return (love.filesystem.read(path))
    end
    log("DEBUG", "%s: 没有预先计算的结果 %s, 返回原内容", name, key)
    return buffer
end

-- 补丁在打包时已固定, 无法重新加载. smods 用它临时屏蔽冲突的 mod, 这里只记录.
function lovely.reload_patches()
    log("WARN", "reload_patches 被调用: 补丁在打包时已固定, 屏蔽 mod 需要重新打包")
    return true
end

lovely.set_var = set_var
lovely.get_var = get_var
lovely.remove_var = remove_var

-- ---------------------------------------------------------------- 释放 mod

local function read_stamp()
    local text = love.filesystem.read(STAMP_PATH)
    if not text then return nil end
    local stamp = { folders = {} }
    for line in text:gmatch("[^\r\n]+") do
        local key, value = line:match("^(%w+)=(.*)$")
        if key == "folder" then
            stamp.folders[#stamp.folders + 1] = value
        elseif key then
            stamp[key] = value
        end
    end
    return stamp
end

local function safe_folder(name)
    return type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
        and name ~= "lovely" and not name:find("[/\\]")
end

local function remove_tree(path)
    local info = love.filesystem.getInfo(path)
    if not info then return end
    -- getInfo 对符号链接返回 symlink, 只删除链接本身, 不进入它指向的目录.
    if info.type == "directory" then
        for _, item in ipairs(love.filesystem.getDirectoryItems(path)) do
            remove_tree(path .. "/" .. item)
        end
    end
    love.filesystem.remove(path)
end

local function is_symlink(path)
    local info = love.filesystem.getInfo(path)
    return info ~= nil and info.type == "symlink"
end

local function sync_mods()
    local started = now()
    love.filesystem.createDirectory(MODS_DIR .. "/lovely")

    local stamp = read_stamp()
    local present = true
    for _, folder in ipairs(manifest.mods) do
        local info = love.filesystem.getInfo(MODS_DIR .. "/" .. folder)
        if not info or info.type == "file" then present = false end
    end
    if stamp and stamp.format == STAMP_FORMAT and stamp.hash == manifest.bundle_hash and present then
        log("INFO", "包内 mod 未变化, 跳过释放 (%d 个)", #manifest.mods)
        return
    end

    local wanted = {}
    for _, folder in ipairs(manifest.mods) do wanted[folder] = true end
    local skipped = {}
    local folders = {}
    for _, folder in ipairs((stamp and stamp.folders) or {}) do folders[#folders + 1] = folder end
    for _, folder in ipairs(manifest.mods) do folders[#folders + 1] = folder end
    for _, folder in ipairs(folders) do
        local path = MODS_DIR .. "/" .. folder
        if not safe_folder(folder) then
            log("WARN", "释放记录中的文件夹名无效, 忽略: %s", tostring(folder))
        elseif is_symlink(path) then
            if wanted[folder] then skipped[folder] = true end
            log("WARN", "%s 是符号链接, 保持原样不覆盖", path)
        else
            remove_tree(path)
        end
    end

    local count = 0
    for _, rel in ipairs(manifest.files) do
        local folder = rel:match("^([^/]+)/")
        if not skipped[folder] then
            local data = love.filesystem.read(SHIM_DIR .. "/mods/" .. rel)
            if data == nil then error("包内缺少 mod 文件 " .. rel) end
            if manifest.sentinel_files[rel] then data = resolve_mod_dirs(data) end
            local parent = rel:match("^(.*)/[^/]*$")
            if parent then love.filesystem.createDirectory(MODS_DIR .. "/" .. parent) end
            local ok, err = love.filesystem.write(MODS_DIR .. "/" .. rel, data)
            if not ok then error("写入 " .. MODS_DIR .. "/" .. rel .. " 失败: " .. tostring(err)) end
            count = count + 1
        end
    end

    local lines = { "format=" .. STAMP_FORMAT, "hash=" .. manifest.bundle_hash }
    for _, folder in ipairs(manifest.mods) do lines[#lines + 1] = "folder=" .. folder end
    love.filesystem.write(STAMP_PATH, table.concat(lines, "\n") .. "\n")
    log("INFO", "已释放 %d 个 mod, %d 个文件, 耗时 %.2f 秒", #manifest.mods, count, now() - started)
end

-- ---------------------------------------------------------------- 模块补丁

local function load_module(entry)
    local source = love.filesystem.read(SHIM_DIR .. "/" .. entry.file)
    if source == nil then error("包内缺少模块源码 " .. entry.file) end
    if entry.needs_mod_dir then source = resolve_mod_dirs(source) end
    return load(source, entry.chunk)
end

local function install_modules()
    for _, entry in ipairs(manifest.modules) do
        if not entry.load_now then
            package.preload[entry.name] = function(...)
                local chunk, err = load_module(entry)
                if not chunk then error(err, 0) end
                return chunk(...)
            end
        end
    end
end

-- ---------------------------------------------------------------- LÖVE 内置脚本

local function split_keep(text)
    local lines = {}
    local pos = 1
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        if not nl then
            lines[#lines + 1] = text:sub(pos)
            break
        end
        lines[#lines + 1] = text:sub(pos, nl)
        pos = nl + 1
    end
    return lines
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function indent_payload(payload, indent)
    local out = {}
    for _, line in ipairs(split_keep(payload)) do out[#out + 1] = indent .. line end
    local text = table.concat(out)
    if payload:sub(-1) ~= "\n" then text = text .. "\n" end
    return text
end

-- 与 lovely 的 pattern 补丁相同: 逐行去掉首尾空白后整行匹配, 命中后跳过整个窗口.
local function apply_line_patch(text, patch)
    local lines = split_keep(text)
    local count = #patch.pattern
    local out = {}
    local i, hits = 1, 0
    while i <= #lines do
        local matched = i + count - 1 <= #lines and (patch.times == nil or hits < patch.times)
        if matched then
            for k = 1, count do
                if not trim(lines[i + k - 1]):find(patch.pattern[k]) then
                    matched = false
                    break
                end
            end
        end
        if matched then
            hits = hits + 1
            local indent = patch.match_indent and lines[i]:match("^[ \t]*") or ""
            local payload = indent_payload(patch.payload, indent)
            local block = table.concat(lines, "", i, i + count - 1)
            if patch.position == "before" then
                out[#out + 1] = payload .. block
            elseif patch.position == "after" then
                out[#out + 1] = block .. payload
            else
                out[#out + 1] = payload
            end
            i = i + count
        else
            out[#out + 1] = lines[i]
            i = i + 1
        end
    end
    return table.concat(out)
end

-- 生成的着色器代码由 LÖVE 的头部与用户代码拼成, 以 #line 分隔. 只改头部, 不碰用户代码.
-- 默认着色器在 LÖVE 启动时已经生成, 不经过这里, 保持原样.
local function patch_header(code, patches)
    if type(code) ~= "string" then return code end
    local cut = code:find("\n#line ", 1, true)
    local head = cut and code:sub(1, cut) or code
    local tail = cut and code:sub(cut + 1) or ""
    for _, patch in ipairs(patches) do head = apply_line_patch(head, patch) end
    return head .. tail
end

local function patch_love_internals()
    local patches = manifest.love_patches["wrap_GraphicsShader.lua"]
    if not patches then return end
    local graphics = love.graphics
    if not (graphics and graphics._shaderCodeToGLSL) then
        log("WARN", "love.graphics._shaderCodeToGLSL 不存在, 跳过着色器头部补丁")
        return
    end
    local original = graphics._shaderCodeToGLSL
    graphics._shaderCodeToGLSL = function(...)
        local vertex, pixel = original(...)
        return patch_header(vertex, patches), patch_header(pixel, patches)
    end
    log("INFO", "已接管着色器头部生成, %d 个补丁", #patches)
end

-- ---------------------------------------------------------------- 入口

function M.boot()
    if booted then return end
    booted = true
    local started = now()
    open_log()
    lovely.mod_dir = mod_dir()
    lovely.log_path = love.filesystem.getSaveDirectory():gsub("\\", "/") .. "/" .. LOG_PATH
    package.preload["lovely"] = function() return lovely end
    sync_mods()
    install_modules()
    patch_love_internals()
    log("INFO", "启动完成, %d 个模块, 耗时 %.2f 秒", #manifest.modules, now() - started)
end

-- 在 target 的代码执行之前调用: 完成启动, 然后求值声明了 load_now 且 before 为 target 的模块.
function M.before(target)
    M.boot()
    local entries = manifest.load_now[target]
    if not entries then return end
    for _, entry in ipairs(entries) do
        local chunk, err = load_module(entry)
        if not chunk then
            error("加载 load_now 模块 " .. entry.name .. " 失败:\n" .. tostring(err), 0)
        end
        local ok, result = xpcall(chunk, debug.traceback)
        if not ok then
            error("执行 load_now 模块 " .. entry.name .. " 失败:\n" .. tostring(result), 0)
        end
        package.preload[entry.name] = function() return result end
        log("INFO", "已执行 load_now 模块 %s", entry.name)
    end
end

-- 运行时覆盖存档标识的环境变量, 例如 agent 专用存档, 避免污染日常存档.
local IDENTITY_ENV = "BALATRO_SAVE_IDENTITY"

-- 追加在 conf.lua 末尾: 在原有配置之后覆盖存档标识, 让带 mod 的版本与原版存档互不影响.
function M.wrap_conf()
    local original = love.conf
    love.conf = function(t)
        if original then original(t) end
        if manifest.identity then t.identity = manifest.identity end
        local override = os.getenv(IDENTITY_ENV)
        if override and override ~= "" then
            -- 只接受单层目录名, 防止写到存档根目录之外.
            if override:match("^[%w%-_ ]+$") then
                t.identity = override
                log("INFO", "按 %s 使用存档目录 %s", IDENTITY_ENV, override)
            else
                log("WARN", "忽略非法的 %s: %s", IDENTITY_ENV, override)
            end
        end
    end
end

return M
