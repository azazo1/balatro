--[[
nativefs 的浏览器替身. 原版用 ffi 调 C 的文件接口, love.js 没有 ffi.
smods 用绝对路径访问存档目录下的 Mods, 这里把绝对路径换算成存档目录内的相对路径交给 love.filesystem;
存档目录之外的路径用 io 兜底 (只支持读写单个文件).
]]

local lfs = love.filesystem
local save = lfs.getSaveDirectory():gsub("\\", "/"):gsub("/$", "")
local cwd = save

local M = {}

local function absolute(p)
    p = tostring(p):gsub("\\", "/")
    if p:sub(1, 1) ~= "/" then p = cwd .. "/" .. p end
    local parts = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

-- 存档目录内返回相对路径 ("" 表示存档根), 之外返回 nil 与绝对路径.
local function relative(p)
    local a = absolute(p)
    if a == save then return "", a end
    if a:sub(1, #save + 1) == save .. "/" then return a:sub(#save + 2), a end
    return nil, a
end

local redirects = {}

local function redirect(p)
    for real, target in pairs(redirects) do
        if p == real then return target end
        if p:sub(1, #real + 1) == real .. "/" then return target .. p:sub(#real + 1) end
    end
end

-- 返回 love.filesystem 能用的路径, 或 nil 与绝对路径.
local function resolve(p)
    local r = redirect(tostring(p):gsub("\\", "/"))
    if r then return r end
    return relative(p)
end

function M.getWorkingDirectory() return cwd end

function M.setWorkingDirectory(p)
    cwd = absolute(p)
    return true
end

function M.getDriveList() return { "/" } end

function M.smodsAddRedirect(real, target)
    if redirects[real] then return false, "redirect exists: " .. real end
    redirects[real] = target
    return true
end

function M.getInfo(p, filtertype)
    local r, a = resolve(p)
    if r then return lfs.getInfo(r, filtertype) end
    local f = io.open(a, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    if filtertype and filtertype ~= "file" then return nil end
    return { type = "file", size = size }
end

function M.read(a1, a2, a3)
    local container, name, size
    if a3 then
        container, name, size = a1, a2, a3
    elseif a2 == nil then
        container, name = "string", a1
    elseif type(a2) == "number" or a2 == "all" then
        container, name, size = "string", a1, a2
    else
        container, name = a1, a2
    end
    if size == "all" then size = nil end
    local r, abs = resolve(name)
    if r then
        if container == "data" then return lfs.read("data", r, size) end
        return lfs.read(r, size)
    end
    local f = io.open(abs, "rb")
    if not f then return nil, "Could not open " .. abs end
    local s = size and f:read(size) or f:read("*a")
    f:close()
    if container == "data" then return lfs.newFileData(s, abs), #s end
    return s, #s
end

local function write_file(mode, name, data, size)
    if type(data) ~= "string" and data.getString then data = data:getString() end
    if size and size ~= "all" then data = data:sub(1, size) end
    local r, abs = resolve(name)
    if r then
        local parent = r:match("^(.*)/[^/]*$")
        if parent and parent ~= "" then lfs.createDirectory(parent) end
        if mode == "a" then return lfs.append(r, data) end
        return lfs.write(r, data)
    end
    local f = io.open(abs, mode == "a" and "ab" or "wb")
    if not f then return false, "Could not open " .. abs end
    f:write(data)
    f:close()
    return true
end

function M.write(name, data, size) return write_file("w", name, data, size) end
function M.append(name, data, size) return write_file("a", name, data, size) end

function M.newFileData(p)
    local r, abs = resolve(p)
    if r then return lfs.newFileData(r) end
    local s, err = M.read(p)
    if not s then return nil, err end
    return lfs.newFileData(s, abs)
end

function M.lines(p)
    local r, abs = resolve(p)
    if r then return lfs.lines(r) end
    return io.lines(abs)
end

function M.load(p)
    local s, err = M.read(p)
    if not s then return nil, err end
    return loadstring(s, "@" .. tostring(p))
end

function M.getDirectoryItems(p)
    local r = resolve(p)
    if not r then return {} end
    return lfs.getDirectoryItems(r)
end

function M.getDirectoryItemsInfo(p, filtertype)
    local r = resolve(p)
    if not r then return {} end
    local items = {}
    for _, name in ipairs(lfs.getDirectoryItems(r)) do
        local info = lfs.getInfo((r == "" and "" or r .. "/") .. name, filtertype)
        if info then
            info.name = name
            items[#items + 1] = info
        end
    end
    return items
end

function M.createDirectory(p)
    local r = resolve(p)
    if not r then return false, "outside save directory: " .. tostring(p) end
    if r == "" then return true end
    return lfs.createDirectory(r)
end

function M.remove(p)
    local r, abs = resolve(p)
    if r then return lfs.remove(r) end
    return os.remove(abs) and true or false
end

function M.mount(archive, mountpoint, append)
    local r = resolve(archive)
    if not r then return false end
    return lfs.mount(r, mountpoint, append)
end

function M.unmount(archive)
    local r = resolve(archive)
    if not r then return false end
    return lfs.unmount(r)
end

function M.newFile(p)
    local r, abs = resolve(p)
    if r then return lfs.newFile(r) end
    error("nativefs.newFile outside save directory is not supported: " .. abs)
end

function M.getNormalizedPath(p)
    if M.getInfo(p) then return p end
    p = tostring(p):gsub("\\", "/"):gsub("/$", "")
    local parent = p:gsub("/[^/]*$", "")
    if parent == p or parent == "" then return p end
    parent = M.getNormalizedPath(parent)
    for _, v in ipairs(M.getDirectoryItems(parent)) do
        if (parent .. "/" .. v):lower() == p:lower() then return parent .. "/" .. v end
    end
    return p
end

return M
