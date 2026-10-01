--[[
原生网络库 bbnet 的 ffi 封装, 以及加载失败时退回 SMODS.https 的同接口实现.

C ABI (与 Rust 端一致):
  int64_t bbnet_request(method, url, headers, body, body_len, timeout_ms); 句柄 > 0, 参数错 -1
  int bbnet_poll(id, *status, **out, *out_len); 0 NONE, 1 STATUS, 2 EVENT, 3 BODY, 4 DONE, 5 ERROR
  void bbnet_free(char *); void bbnet_cancel(id); void bbnet_close(id); const char *bbnet_version();

对外接口:
- M.load(mod_path) -> ok, err: 按顺序找库, 找到后 M.available() 为 true. 可重复调用.
- M.request(opts) -> handle | nil, err. opts: method, url, headers (表), body, timeout_ms.
- handle:poll() -> items: 一次取完当前已到达的全部项, 每项 {kind, status?, text?},
  kind 为 "status" | "event" | "body" | "done" | "error". 没有新数据时返回空表.
  "done" 与 "error" 是终态, 之后的 poll 都返回空表.
- handle:cancel(): 取消请求, 之后 poll 会交出 {kind = "error", text = "cancelled"}.
- handle:close(): 释放句柄 (未结束时先取消). 丢弃的句柄被回收时也会自动释放.

退路 (bbnet 不可用): 用 SMODS.https.asyncRequest 在线程里发请求, 完成后一次性交出 status 与整段
body, 响应是 SSE 时按空行拆成 event. 不能流式, 取消只是丢弃结果. Android 上 SMODS.https 没有后端,
请求直接以 "unavailable: ..." 错误结束.

纯 luajit 下也能加载 (不依赖 G/SMODS/love), 便于单测和本地调试.
]]

local M = {}

local KIND = { [0] = "none", "status", "event", "body", "done", "error" }
M.KIND = KIND

local LIB_FILE = {
  macos = "libbbnet.dylib",
  windows = "bbnet.dll",
  linux = "libbbnet.so",
  android = "libbbnet.so",
}

-- 每次 poll 最多取的项数, 防止一帧里处理过多数据.
local POLL_BUDGET = 1024
-- 退路的整体时限: timeout_ms 为 0 时取默认值; 非 0 时 (原生库里是空闲超时) 至少取下限,
-- 因为整段响应要等模型全部生成完.
local FALLBACK_TOTAL_MS = 300000
local FALLBACK_MIN_TOTAL_MS = 120000

local ffi -- 延迟 require, 纯 Lua 环境下也能加载本文件
local lib -- 加载成功的 ffi 库
local lib_path -- 成功加载的路径, 仅用于日志
local load_err -- 最近一次加载失败的原因
local version_str
local sse -- 退路拆分 SSE 用, 由 set_sse 注入

---@type fun(level: "info"|"warn"|"error", msg: string)?
local log_fn

local function log(level, msg)
  if log_fn then
    log_fn(level, msg)
  end
end

--- 注入日志函数 (游戏内传 sendInfoMessage 等的包装).
---@param fn fun(level: "info"|"warn"|"error", msg: string)?
function M.set_logger(fn)
  log_fn = fn
end

--- 注入 SSE 模块 (agent/llm/sse.lua), 退路用它把整段响应拆成事件.
---@param mod table
function M.set_sse(mod)
  sse = mod
end

local CDEF = [[
int64_t bbnet_request(const char *method, const char *url, const char *headers,
                      const char *body, size_t body_len, uint32_t timeout_ms);
int bbnet_poll(int64_t id, int *status, char **out, size_t *out_len);
void bbnet_free(char *p);
void bbnet_cancel(int64_t id);
void bbnet_close(int64_t id);
const char *bbnet_version(void);
]]

-------------------------------------------------------------------------------
-- 平台与加载
-------------------------------------------------------------------------------

local platform_override

--- 当前平台: "macos" | "windows" | "linux" | "android" | "ios" | "unknown".
---@return string
function M.platform()
  if platform_override then
    return platform_override
  end
  local os_name
  if type(love) == "table" and love.system and love.system.getOS then
    os_name = love.system.getOS()
  end
  if os_name == "OS X" then
    return "macos"
  elseif os_name == "Windows" then
    return "windows"
  elseif os_name == "Android" then
    return "android"
  elseif os_name == "iOS" then
    return "ios"
  elseif os_name == "Linux" then
    return "linux"
  end
  local jos = (jit and jit.os) or ""
  if jos == "OSX" then
    return "macos"
  elseif jos == "Windows" then
    return "windows"
  elseif jos == "Linux" then
    return os.getenv("ANDROID_ROOT") and "android" or "linux"
  end
  return "unknown"
end

--- 测试用: 指定平台, 传 nil 恢复自动判断.
---@param name string?
function M.set_platform(name)
  platform_override = name
end

local function join(dir, name)
  if dir == "" then
    return name
  end
  if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
    return dir .. name
  end
  return dir .. "/" .. name
end

--- Android: 从 /proc/self/maps 找到 liblove.so 所在目录, 拼出 libbbnet.so 的完整路径.
---@return string?
local function android_lib_from_maps()
  local f = io.open("/proc/self/maps", "r")
  if not f then
    return nil
  end
  local found
  for line in f:lines() do
    local path = line:match("(/%S*/liblove%.so)%s*$")
    -- 库直接从 APK 里映射时 (路径含 .apk!/) 没法拼出文件路径, 跳过.
    if path and not path:find("%.apk!") then
      found = path:match("^(.*)/[^/]+$")
      break
    end
  end
  f:close()
  return found and join(found, "libbbnet.so") or nil
end

--- 按顺序列出要尝试的库路径 (或库名).
---@param mod_path string?
---@return string[]
function M.candidates(mod_path)
  local list = {}
  local env = os.getenv("BALATROBOT_BBNET")
  if env and env ~= "" then
    list[#list + 1] = env
  end
  local plat = M.platform()
  local file = LIB_FILE[plat]
  if plat == "android" then
    list[#list + 1] = "bbnet"
    list[#list + 1] = "libbbnet.so"
    local from_maps = android_lib_from_maps()
    if from_maps then
      list[#list + 1] = from_maps
    end
  elseif file and type(mod_path) == "string" and mod_path ~= "" then
    list[#list + 1] = join(join(join(mod_path, "native"), plat), file)
  end
  return list
end

local function try_load(path)
  if M.platform() == "windows" then
    -- LoadLibrary 不保证接受正斜杠.
    path = path:gsub("/", "\\")
  end
  local ok, res = pcall(ffi.load, path)
  if not ok then
    return nil, tostring(res)
  end
  -- 缺符号时这里就会报错, 免得请求时才发现 ABI 不一致.
  local sym_ok, sym_err = pcall(function()
    local _ = res.bbnet_request, res.bbnet_poll, res.bbnet_free, res.bbnet_cancel, res.bbnet_close
    return res.bbnet_version
  end)
  if not sym_ok then
    return nil, "缺少符号: " .. tostring(sym_err)
  end
  return res
end

--- 加载原生库. 已加载时直接返回 true.
---@param mod_path string? mod 目录 (游戏内是 SMODS.current_mod.path)
---@return boolean ok
---@return string? err 失败时为各候选路径的错误汇总
function M.load(mod_path)
  if lib then
    return true
  end
  local has_ffi, ffi_mod = pcall(require, "ffi")
  if not has_ffi then
    load_err = "当前 Lua 没有 ffi"
    return false, load_err
  end
  ffi = ffi_mod
  -- 重复 cdef 会报 "attempt to redefine", 模块被加载两次时忽略即可.
  pcall(ffi.cdef, CDEF)

  local errors = {}
  for _, path in ipairs(M.candidates(mod_path)) do
    local loaded, err = try_load(path)
    if loaded then
      lib, lib_path = loaded, path
      local ok_v, v = pcall(function()
        local p = lib.bbnet_version()
        return p ~= nil and ffi.string(p) or "?"
      end)
      version_str = ok_v and v or "?"
      load_err = nil
      log("info", string.format("bbnet %s loaded from %s", version_str, path))
      return true
    end
    errors[#errors + 1] = path .. ": " .. tostring(err)
  end
  load_err = #errors > 0 and table.concat(errors, "; ") or ("没有适用于平台 " .. M.platform() .. " 的候选路径")
  log("warn", "bbnet unavailable, " .. load_err)
  return false, load_err
end

--- 原生库是否可用 (可以流式).
---@return boolean
function M.available()
  return lib ~= nil
end

--- 当前后端: "bbnet" (原生, 流式) | "smods" (SMODS.https, 非流式) | "none".
---@return string
function M.backend()
  if lib then
    return "bbnet"
  end
  if M.platform() ~= "android" and M.smods_https() then
    return "smods"
  end
  return "none"
end

---@return string? version 原生库版本
---@return string? path 加载路径
---@return string? err 最近一次加载失败的原因
function M.info()
  return version_str, lib_path, load_err
end

-------------------------------------------------------------------------------
-- 公共
-------------------------------------------------------------------------------

--- 请求头表拼成 "Name: value\n" 文本. 键排序, 值里的换行去掉, 防止注入额外的头.
---@param headers table<string, string>?
---@return string
function M.format_headers(headers)
  if type(headers) ~= "table" then
    return ""
  end
  local names = {}
  for k, v in pairs(headers) do
    if type(k) == "string" and v ~= nil then
      names[#names + 1] = k
    end
  end
  table.sort(names)
  local out = {}
  for _, k in ipairs(names) do
    local name = k:gsub("[\r\n:]", "")
    local value = tostring(headers[k]):gsub("[\r\n]", "")
    out[#out + 1] = name .. ": " .. value .. "\n"
  end
  return table.concat(out)
end

local function normalize_opts(opts)
  if type(opts) ~= "table" or type(opts.url) ~= "string" or opts.url == "" then
    return nil, "缺少 url"
  end
  local body = opts.body
  if body ~= nil and type(body) ~= "string" then
    return nil, "body 必须是字符串"
  end
  local method = opts.method or (body and "POST" or "GET")
  local timeout = math.floor(tonumber(opts.timeout_ms) or 0)
  if timeout < 0 then
    timeout = 0
  end
  return { method = method:upper(), url = opts.url, headers = opts.headers, body = body, timeout_ms = timeout }
end

-------------------------------------------------------------------------------
-- 原生句柄
-------------------------------------------------------------------------------

---@class BBNetItem
---@field kind "status"|"event"|"body"|"done"|"error"
---@field status integer? kind 为 "status" 时的状态码
---@field text string? status: 原始响应头; event: 一条 SSE 事件原文; body: 响应体片段; error: 错误描述

---@class BBNetHandle
---@field id any
---@field finished boolean 已交出 done 或 error
---@field closed boolean
local Native = {}
Native.__index = Native

local status_box, out_box, len_box

---@return BBNetItem[]
function Native:poll()
  local items = {}
  if self.closed or self.finished then
    return items
  end
  if not status_box then
    status_box = ffi.new("int[1]")
    out_box = ffi.new("char*[1]")
    len_box = ffi.new("size_t[1]")
  end
  for _ = 1, POLL_BUDGET do
    status_box[0], out_box[0], len_box[0] = 0, nil, 0
    local code = tonumber(lib.bbnet_poll(self.id, status_box, out_box, len_box))
    local text
    local ptr = out_box[0]
    if ptr ~= nil then
      text = ffi.string(ptr, tonumber(len_box[0]))
      lib.bbnet_free(ptr)
    end
    local kind = KIND[code]
    if not kind or kind == "none" then
      if not kind then
        items[#items + 1] = { kind = "error", text = "bbnet_poll 返回未知类型 " .. tostring(code) }
        self.finished = true
      end
      break
    end
    local item = { kind = kind, text = text }
    if kind == "status" then
      item.status = tonumber(status_box[0])
    end
    items[#items + 1] = item
    if kind == "done" or kind == "error" then
      self.finished = true
      break
    end
  end
  return items
end

function Native:cancel()
  if not self.closed and not self.finished then
    lib.bbnet_cancel(self.id)
  end
end

function Native:close()
  if self.closed then
    return
  end
  if not self.finished then
    lib.bbnet_cancel(self.id)
  end
  self.closed = true
  if self.guard then
    ffi.gc(self.guard, nil)
    self.guard = nil
  end
  lib.bbnet_close(self.id)
end

-------------------------------------------------------------------------------
-- 退路: SMODS.https
-------------------------------------------------------------------------------

local smods_https_cache

--- 取 SMODS.https 模块, 没有时返回 nil.
---@return table?
function M.smods_https()
  if smods_https_cache ~= nil then
    return smods_https_cache or nil
  end
  local mod = type(SMODS) == "table" and type(SMODS.https) == "table" and SMODS.https or nil
  if not mod then
    local ok, res = pcall(require, "SMODS.https")
    mod = ok and type(res) == "table" and res or nil
  end
  if mod and type(mod.asyncRequest) ~= "function" then
    mod = nil
  end
  smods_https_cache = mod or false
  return mod
end

local function now()
  if type(love) == "table" and love.timer and love.timer.getTime then
    return love.timer.getTime()
  end
  return os.clock()
end

---@class BBNetFallbackHandle
local Fallback = {}
Fallback.__index = Fallback

local function fb_push(self, item)
  self.queue[#self.queue + 1] = item
end

local function fb_finish(self, kind, text)
  if self.finished then
    return
  end
  self.finished = true
  fb_push(self, { kind = kind, text = text })
end

---@return BBNetItem[]
function Fallback:poll()
  if self.closed then
    return {}
  end
  if not self.finished and self.deadline and now() >= self.deadline then
    fb_finish(self, "error", "timeout")
  end
  local items = self.queue
  self.queue = {}
  return items
end

function Fallback:cancel()
  if not self.closed then
    fb_finish(self, "error", "cancelled")
  end
end

function Fallback:close()
  self:cancel()
  self.closed = true
  self.queue = {}
end

-- SMODS.https 回调: code 为 0 时 body 是错误描述.
local function fb_complete(self, code, body, headers)
  if self.finished then
    return -- 已取消或已超时, 迟到的结果丢弃
  end
  code = tonumber(code) or 0
  if code == 0 then
    fb_finish(self, "error", tostring(body or "request failed"))
    return
  end
  local header_text = type(headers) == "table" and M.format_headers(headers) or ""
  fb_push(self, { kind = "status", status = code, text = header_text })
  body = type(body) == "string" and body or ""
  local ctype = ""
  if type(headers) == "table" then
    for k, v in pairs(headers) do
      if type(k) == "string" and k:lower() == "content-type" then
        ctype = tostring(v):lower()
      end
    end
  end
  local is_sse = ctype:find("text/event-stream", 1, true) or (ctype == "" and body:match("^%s*data:"))
  if is_sse and sse then
    local events, rest = sse.split(body)
    if rest:match("%S") then
      events[#events + 1] = rest
    end
    for _, ev in ipairs(events) do
      fb_push(self, { kind = "event", text = ev })
    end
  elseif body ~= "" then
    fb_push(self, { kind = "body", text = body })
  end
  fb_finish(self, "done")
end

local function fallback_request(o)
  local self = setmetatable({ queue = {}, finished = false, closed = false, fallback = true }, Fallback)
  local https = M.platform() ~= "android" and M.smods_https() or nil
  if not https then
    fb_finish(self, "error", "unavailable: bbnet 未加载, 且没有 SMODS.https 后端")
    return self
  end
  -- 退路收完整个响应才返回, 超时只能按整体计.
  local total = o.timeout_ms > 0 and math.max(o.timeout_ms, FALLBACK_MIN_TOTAL_MS) or FALLBACK_TOTAL_MS
  self.deadline = now() + total / 1000
  local ok, err = pcall(https.asyncRequest, o.url, {
    method = o.method,
    headers = o.headers or {},
    data = o.body,
  }, function(code, body, headers)
    fb_complete(self, code, body, headers)
  end)
  if not ok then
    fb_finish(self, "error", "unavailable: " .. tostring(err))
  end
  return self
end

-------------------------------------------------------------------------------
-- 发起请求
-------------------------------------------------------------------------------

--- 发起请求. 原生库可用时流式, 否则走 SMODS.https 退路.
---@param opts {method: string?, url: string, headers: table<string,string>?, body: string?, timeout_ms: integer?}
---@return (BBNetHandle|BBNetFallbackHandle)? handle 参数错误时为 nil
---@return string? err
function M.request(opts)
  local o, err = normalize_opts(opts)
  if not o then
    return nil, err
  end
  if not lib then
    return fallback_request(o)
  end
  local body = o.body or ""
  local id = lib.bbnet_request(o.method, o.url, M.format_headers(o.headers), body, #body, o.timeout_ms)
  if id <= 0 then
    return nil, "bbnet_request 参数错误"
  end
  local self = setmetatable({ id = id, finished = false, closed = false }, Native)
  -- 句柄丢失 (调用方出错没走到 close) 时, 回收兜底释放原生资源.
  self.guard = ffi.gc(ffi.new("int64_t[1]", id), function(box)
    lib.bbnet_cancel(box[0])
    lib.bbnet_close(box[0])
  end)
  return self
end

return M
