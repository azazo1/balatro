--[[
浏览器 (love.js compat 版, 无线程) 的线程替身, 由打包脚本插到 main.lua 第一行.
语言差异见 web_compat/lang.lua, 它在 conf.lua 阶段已经加载.

love.thread: 用协程在主线程里跑线程脚本. 线程里 demand 在队列为空时挂起,
主线程 push 之后立即调度等待中的协程, 因此存档与音效请求在同一帧内处理完.
]]

require("web_compat.lang")

local function log(fmt, ...)
    print("[web-compat] " .. string.format(fmt, ...))
end

-- 错误处理: mod 会替换 love.errorhandler, 窗口未创建时它们直接返回, 错误正文就丢了.
-- 拦截对这两个字段的赋值, 包一层先把错误与 traceback 打到 console.
do
    local handlers = {}
    local function wrap(fn)
        return function(msg, ...)
            print("[web-compat] 错误: " .. debug.traceback(tostring(msg), 2))
            return fn(msg, ...)
        end
    end
    for _, key in ipairs({ "errorhandler", "errhand" }) do
        local fn = rawget(love, key)
        if fn then
            handlers[key] = wrap(fn)
            love[key] = nil
        end
    end
    setmetatable(love, {
        __index = function(_, k) return handlers[k] end,
        __newindex = function(t, k, v)
            if k == "errorhandler" or k == "errhand" then
                handlers[k] = type(v) == "function" and wrap(v) or v
            else
                rawset(t, k, v)
            end
        end,
    })
end

-- 文件不存在时 love 在 C++ 里抛异常, compat 版 love.js 对异常的处理会破坏 Lua 栈
-- (之后的报错行号错乱). 先用 getInfo 判断, 不存在就按 love 的约定返回 nil, 错误信息.
do
    local fs = love.filesystem
    for _, name in ipairs({ "read", "newFileData", "lines", "load" }) do
        local raw = fs[name]
        fs[name] = function(path, ...)
            if type(path) == "string" and not fs.getInfo(path) then
                -- mod 会把文件内容直接传给 newFileData (单参数), 按内容处理.
                if name == "newFileData" then
                    if select("#", ...) == 0 then return raw(path, "data") end
                    return raw(path, ...)
                end
                if name == "lines" then
                    error("Could not open file " .. path .. ". Does not exist.", 2)
                end
                return nil, "Could not open file " .. path .. ". Does not exist."
            end
            return raw(path, ...)
        end
    end
end

-- WebGL1 不能给非 2 次幂尺寸的纹理生成 mipmap, 图集都是任意尺寸, 去掉 mipmaps 选项.
do
    local g = love.graphics
    local raw_new = g.newImage
    g.newImage = function(src, settings)
        if type(settings) == "table" and settings.mipmaps then
            local copy = {}
            for k, v in pairs(settings) do copy[k] = v end
            copy.mipmaps = nil
            settings = copy
        end
        local img = raw_new(src, settings)
        -- Image 方法表所有图片共享, 首次创建时改一次: 没有 mipmap 的纹理忽略 setMipmapFilter.
        local mt = getmetatable(img)
        local methods = mt and (type(mt.__index) == "table" and mt.__index or mt)
        if methods and not methods.__web_mipmap then
            methods.__web_mipmap = true
            local raw_filter = methods.setMipmapFilter
            methods.setMipmapFilter = function(self, ...)
                if self:getMipmapCount() <= 1 then return end
                return raw_filter(self, ...)
            end
        end
        return img
    end
end

local threads = {}
local current = nil
local pumping = false

local function chunk_of(source)
    if type(source) == "string" then
        if source:find("\n") then return loadstring(source, "=thread") end
        return love.filesystem.load(source)
    end
    local name = source.getFilename and source:getFilename() or "thread"
    return loadstring(source:getString(), "=" .. name)
end

local Thread = {}
Thread.__index = Thread

local function resume(t, ...)
    current = t
    local ok, err = coroutine.resume(t.co, ...)
    current = nil
    if not ok then
        t.error = tostring(err)
        log("线程 %s 出错: %s", t.name, t.error)
    end
    if coroutine.status(t.co) == "dead" then t.running = false end
end

local function pump()
    if pumping then return end
    pumping = true
    local progressed = true
    while progressed do
        progressed = false
        for _, t in ipairs(threads) do
            if t.running and t.waiting and t.waiting:getCount() > 0 then
                local ch = t.waiting
                t.waiting = nil
                resume(t, ch:pop())
                progressed = true
            end
        end
    end
    pumping = false
end

function Thread:start(...)
    if self.running then return end
    local fn, err = chunk_of(self.source)
    if not fn then
        self.error = tostring(err)
        log("线程 %s 加载失败: %s", self.name, self.error)
        return
    end
    -- 线程有自己的全局表, 读不到的回落到主线程, 避免同名全局 (PLAY_SOUND, CHANNEL) 互相覆盖.
    setfenv(fn, setmetatable({}, { __index = _G }))
    self.co = coroutine.create(fn)
    self.running = true
    threads[#threads + 1] = self
    log("启动线程 %s", self.name)
    resume(self, ...)
    pump()
end

function Thread:wait() end
function Thread:isRunning() return self.running end
function Thread:getError() return self.error end
function Thread:release() self.running = false end
function Thread:type() return "Thread" end
function Thread:typeOf(name) return name == "Thread" or name == "Object" end

love.thread.newThread = function(source)
    local name = type(source) == "string" and (source:find("\n") and "inline" or source) or "data"
    return setmetatable({ source = source, name = name, running = false }, Thread)
end

-- Channel 的方法表所有 Channel 共享, 改一次即可.
do
    local probe = love.thread.getChannel("__web_compat_probe")
    local mt = getmetatable(probe)
    local methods = type(mt.__index) == "table" and mt.__index or mt
    local raw_push, raw_pop = methods.push, methods.pop

    methods.push = function(self, value)
        local id = raw_push(self, value)
        pump()
        return id
    end
    methods.supply = function(self, value)
        raw_push(self, value)
        pump()
        return true
    end
    -- 模拟线程里队列为空时挂起协程; 主线程不能阻塞, 退化成 pop.
    methods.demand = function(self)
        local value = raw_pop(self)
        if value ~= nil then return value end
        if current and coroutine.running() == current.co then
            current.waiting = self
            return coroutine.yield()
        end
        return nil
    end
end

-- 不跟着设置自动全屏: 每次开局 Game:init_game_object 都会调 apply_window_changes(true),
-- 里面按设置里的屏幕模式 (默认 Borderless) 请求全屏, 而这一次又常搭着"点了开始"的用户手势成功,
-- 表现成"一点就被全屏". 所以把 _initial 那一次的全屏标志去掉; 用户在设置里主动改屏幕模式
-- (第一参数不是 true) 时放行, 手机上也就能从设置里进全屏. 桌面另有页面上的 F11, 见 shell.html.
-- (这段必须在 main.lua 之后跑: conf.lua 阶段 love.window 还没建出来.)
do
    local update_mode, get_fullscreen = love.window.updateMode, love.window.getFullscreen
    local told = false
    love.window.updateMode = function(width, height, flags)
        local auto = false
        if type(flags) == "table" and flags.fullscreen and type(debug) == "table" and debug.getlocal then
            -- 上一层就是 apply_window_changes; 只有它的第一个参数 _initial 为 true 才是开局自动应用.
            -- getlocal 先回变量名再回值; 这里也不能包 pcall, 那会多出一层栈, 层数便对不上.
            local _, value = debug.getlocal(2, 1)
            auto = value == true
        end
        if auto then
            local copy = {}
            for key, value in pairs(flags) do copy[key] = value end
            copy.fullscreen = false
            copy.fullscreentype = nil
            flags = copy
            if not told then
                told = true
                log("开局不自动全屏, 想全屏请按 F11, 或在设置里把屏幕模式改成全屏")
            end
        end
        return update_mode(width, height, flags)
    end
    -- 直接调 setFullscreen 的路径也压掉, 返回值就说当前的真实状态.
    love.window.setFullscreen = function() return get_fullscreen() end
end

-- 游戏里点退出 (love.event.quit) 时把窗口标题换成记号, 页面盯着标题, 见到就回调试台.
-- 走标题是因为页面读不到游戏的文件系统: love.js 只导出了 FS_create* 这类写入接口, 没有读的.
do
    local quit = love.event.quit
    local marker = "balatro-web-quit"
    love.event.quit = function(...)
        pcall(love.window.setTitle, marker)
        return quit(...)
    end
end

log("线程替身已加载, 系统 %s", love.system and love.system.getOS() or "?")

