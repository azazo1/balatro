--[[
浏览器 (love.js, PUC Lua 5.1) 的语言兼容层, 由打包脚本插到 conf.lua 第一行.
这时 love 只加载了 filesystem 等少数模块, 这里不碰 love.thread / love.timer.

- load(string), math.log(x, base), string.format("%s", 非字符串): 补齐 5.1 与 LuaJIT 的差异.
- bit / jit / socket: LuaJIT 内置或原生库的替身.
- math.random: 换成 LuaJIT 的 TW223 算法, 同一种子抽出与桌面版相同的随机数.
- os.getenv: 页面用 ?replay= 起局时给的那几个变量优先于真环境变量.
]]

if rawget(_G, "__WEB_COMPAT_LANG") then return end
__WEB_COMPAT_LANG = true

local raw_load = load
function load(chunk, name, mode, env)
    local fn, err
    if type(chunk) == "string" then
        fn, err = loadstring(chunk, name)
    else
        fn, err = raw_load(chunk, name)
    end
    if fn and env then setfenv(fn, env) end
    return fn, err
end

local raw_log = math.log
math.log = function(x, base)
    if base then return raw_log(x) / raw_log(base) end
    return raw_log(x)
end

-- LuaJIT 的 %s 对任意值调用 tostring, 5.1 只接受字符串与数字.
local raw_format = string.format
string.format = function(fmt, ...)
    if type(fmt) ~= "string" or not fmt:find("%%s") then return raw_format(fmt, ...) end
    local n = select("#", ...)
    local args = { ... }
    local i = 0
    for _, conv in fmt:gmatch("%%([%-%+ #0]*%d*%.?%d*)([%a%%])") do
        if conv ~= "%" then
            i = i + 1
            if conv == "s" and i <= n then
                local t = type(args[i])
                if t ~= "string" and t ~= "number" then args[i] = tostring(args[i]) end
            end
        end
    end
    return raw_format(fmt, unpack(args, 1, n))
end

package.preload["bit"] = function() return require("web_compat.bit") end
bit = require("bit")

jit = rawget(_G, "jit") or {
    os = "Web",
    arch = "wasm32",
    version = "Lua 5.1 (web-compat)",
    status = function() return false end,
    on = function() end,
    off = function() end,
    flush = function() end,
}

do
    local prng = require("web_compat.prng")
    math.random = prng.random
    math.randomseed = prng.randomseed
end

-- 浏览器里没有 TCP; 调试日志服务器与 agent HTTP 接口都会安静地连接失败.
do
    local function fail() return nil, "sockets are not supported in the browser" end
    local sock_mt = { __index = function() return fail end }
    local socket = {
        _VERSION = "web-compat",
        gettime = function() return os.time() + os.clock() % 1 end,
        sleep = function() end,
        tcp = function() return setmetatable({}, sock_mt) end,
        udp = function() return setmetatable({}, sock_mt) end,
        bind = fail,
        connect = fail,
        select = function() return {}, {} end,
    }
    package.loaded["socket"] = socket
    package.loaded["socket.core"] = socket
end

-- 环境变量: 浏览器里没有可以传变量给 LOVE 的地方, 所以由 shell.html 在 ?replay= 时把
-- "命令行回放" 那套变量写进游戏目录的 web_env.lua, 这里读进来替掉 os.getenv.
-- 本文件在 conf.lua 第一行加载, 因此 love.conf 里读的 BALATRO_SAVE_IDENTITY 也吃得到.
do
    local overrides = rawget(_G, "__WEB_ENV")
    if overrides == nil and love.filesystem and love.filesystem.getInfo("web_env.lua") then
        local chunk = loadstring(love.filesystem.read("web_env.lua"), "=web_env")
        local ok, loaded = pcall(chunk)
        if ok and type(loaded) == "table" then overrides = loaded end
    end
    if type(overrides) == "table" then
        local raw_getenv = os.getenv
        os.getenv = function(name)
            local value = overrides[name]
            if value ~= nil then return value end
            return raw_getenv(name)
        end
        local names = {}
        for name in pairs(overrides) do names[#names + 1] = name end
        table.sort(names)
        print("[web-compat] 环境变量由页面提供: " .. table.concat(names, ", "))
    end
end

print("[web-compat] 语言兼容层已加载: " .. tostring(_VERSION))
