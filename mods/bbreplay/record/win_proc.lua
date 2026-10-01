--[[
Windows 上启动子进程: 直接调 kernel32 的 CreateProcessW (LuaJIT FFI), 不经过 io.popen / os.execute.

为什么不用 io.popen:
- Balatro.exe 是 GUI 程序 (融合自 love.exe), popen 经 cmd.exe 启动, 每次都会弹出一个控制台窗口,
  录像期间一直开着.
- popen 默认是文本模式, 写进去的 RGBA 字节里每个 0x0A 都会被改成 0x0D 0x0A, 画面全部错位.

这里: 子进程不开窗口 (CREATE_NO_WINDOW), 标准输入是二进制管道 (WriteFile 原样写),
标准输出与错误写进日志文件. 主线程与编码线程都会用到; 编码线程拿不到 SMODS, 由主线程读出本文件源码传过去,
在线程里 loadstring 执行.

命令行按 CommandLineToArgvW 的规则拼 (见 M.quote), 路径与参数按 UTF-8 传入, 这里转成 UTF-16.
]]

local ffi = require("ffi")

local M = {}

-- 每个 lua_State 只声明一次. 编码线程是独立的 lua_State, 各自声明, 不冲突.
pcall(
  ffi.cdef,
  [[
typedef struct {
  uint32_t nLength;
  void *lpSecurityDescriptor;
  int32_t bInheritHandle;
} bbr_SECURITY_ATTRIBUTES;

typedef struct {
  uint32_t cb;
  uint16_t *lpReserved;
  uint16_t *lpDesktop;
  uint16_t *lpTitle;
  uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
  uint16_t wShowWindow;
  uint16_t cbReserved2;
  uint8_t *lpReserved2;
  void *hStdInput;
  void *hStdOutput;
  void *hStdError;
} bbr_STARTUPINFOW;

typedef struct {
  void *hProcess;
  void *hThread;
  uint32_t dwProcessId;
  uint32_t dwThreadId;
} bbr_PROCESS_INFORMATION;

int32_t MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char *lpMultiByteStr, int32_t cbMultiByte,
  uint16_t *lpWideCharStr, int32_t cchWideChar);
int32_t CreatePipe(void **hReadPipe, void **hWritePipe, bbr_SECURITY_ATTRIBUTES *lpPipeAttributes, uint32_t nSize);
int32_t SetHandleInformation(void *hObject, uint32_t dwMask, uint32_t dwFlags);
void *CreateFileW(const uint16_t *lpFileName, uint32_t dwDesiredAccess, uint32_t dwShareMode,
  bbr_SECURITY_ATTRIBUTES *lpSecurityAttributes, uint32_t dwCreationDisposition, uint32_t dwFlagsAndAttributes,
  void *hTemplateFile);
int32_t CreateProcessW(const uint16_t *lpApplicationName, uint16_t *lpCommandLine,
  bbr_SECURITY_ATTRIBUTES *lpProcessAttributes, bbr_SECURITY_ATTRIBUTES *lpThreadAttributes, int32_t bInheritHandles,
  uint32_t dwCreationFlags, void *lpEnvironment, const uint16_t *lpCurrentDirectory,
  bbr_STARTUPINFOW *lpStartupInfo, bbr_PROCESS_INFORMATION *lpProcessInformation);
int32_t WriteFile(void *hFile, const void *lpBuffer, uint32_t nNumberOfBytesToWrite, uint32_t *lpNumberOfBytesWritten,
  void *lpOverlapped);
uint32_t WaitForSingleObject(void *hHandle, uint32_t dwMilliseconds);
int32_t GetExitCodeProcess(void *hProcess, uint32_t *lpExitCode);
int32_t TerminateProcess(void *hProcess, uint32_t uExitCode);
int32_t CloseHandle(void *hObject);
uint32_t GetLastError(void);
]]
)

local K = ffi.os == "Windows" and ffi.load("kernel32") or nil

local CP_UTF8 = 65001
local CREATE_NO_WINDOW = 0x08000000
local CREATE_NEW_PROCESS_GROUP = 0x00000200
local CREATE_BREAKAWAY_FROM_JOB = 0x01000000
local STARTF_USESTDHANDLES = 0x00000100
local HANDLE_FLAG_INHERIT = 0x00000001
local GENERIC_WRITE = 0x40000000
local FILE_SHARE_READ = 0x00000001
local CREATE_ALWAYS = 2
local OPEN_EXISTING = 3
local FILE_ATTRIBUTE_NORMAL = 0x80
local WAIT_OBJECT_0 = 0
local INVALID_HANDLE = ffi.cast("void *", -1)
local PIPE_BUFFER = 4 * 1024 * 1024

--- 按 CommandLineToArgvW (也是 MSVC 运行时) 的规则给一个参数加引号: 没有空白与引号时原样返回;
--- 否则包上双引号, 引号前的反斜杠加倍再转义引号, 结尾的反斜杠也加倍 (免得吃掉收尾的引号).
---@param arg string
---@return string
function M.quote(arg)
  arg = tostring(arg)
  if arg ~= "" and not arg:find('[%s"]') then
    return arg
  end
  local out = { '"' }
  local slashes = 0
  for i = 1, #arg do
    local ch = arg:sub(i, i)
    if ch == "\\" then
      slashes = slashes + 1
    elseif ch == '"' then
      out[#out + 1] = string.rep("\\", slashes * 2 + 1) .. '"'
      slashes = 0
    else
      out[#out + 1] = string.rep("\\", slashes) .. ch
      slashes = 0
    end
  end
  out[#out + 1] = string.rep("\\", slashes * 2) .. '"'
  return table.concat(out)
end

--- argv 拼成一条命令行.
---@param argv string[]
---@return string
function M.command_line(argv)
  local parts = {}
  for i, arg in ipairs(argv) do
    parts[i] = M.quote(arg)
  end
  return table.concat(parts, " ")
end

--- UTF-8 转成以 0 结尾的 UTF-16 缓冲 (可写, CreateProcessW 要求命令行可写).
---@param s string
---@return ffi.cdata*
local function wide(s)
  local n = K.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
  local buf = ffi.new("uint16_t[?]", n + 1)
  if n > 0 then
    K.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n)
  end
  buf[n] = 0
  return buf
end

local function last_error(what)
  return string.format("%s 失败 (GetLastError=%d)", what, tonumber(K.GetLastError()))
end

local function inheritable()
  local sa = ffi.new("bbr_SECURITY_ATTRIBUTES")
  sa.nLength = ffi.sizeof(sa)
  sa.bInheritHandle = 1
  return sa
end

--- 打开一个可继承的文件句柄, 给子进程当标准输出. path 为 nil 时用 NUL.
local function open_output(path)
  local handle = K.CreateFileW(
    wide(path or "NUL"),
    GENERIC_WRITE,
    FILE_SHARE_READ,
    inheritable(),
    path and CREATE_ALWAYS or OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL,
    nil
  )
  if handle == INVALID_HANDLE then
    return nil, last_error("打开 " .. tostring(path or "NUL"))
  end
  return handle
end

---@class BBWinProcess
---@field process ffi.cdata*
---@field stdin ffi.cdata*? 写端, 只有 spawn 时 stdin = true 才有

--- 启动子进程, 不开窗口.
--- opts.stdin: true 时建一个管道作标准输入, 用 M.write 写, M.close_stdin 关.
--- opts.output: 标准输出与错误写到这个文件 (覆盖); 不给时写到 NUL.
--- opts.detached: 新进程组, 并尽量脱离游戏所在的作业, 游戏退出不影响它 (后台合成用).
---@param command_line string 用 M.command_line 拼好的命令行
---@param opts {stdin: boolean?, output: string?, detached: boolean?}?
---@return BBWinProcess? proc
---@return string? err
function M.spawn(command_line, opts)
  if not K then
    return nil, "不是 Windows"
  end
  opts = opts or {}
  local si = ffi.new("bbr_STARTUPINFOW")
  si.cb = ffi.sizeof(si)
  si.dwFlags = STARTF_USESTDHANDLES

  local read_end, write_end
  if opts.stdin then
    local ends = ffi.new("void *[2]")
    if K.CreatePipe(ends, ends + 1, inheritable(), PIPE_BUFFER) == 0 then
      return nil, last_error("CreatePipe")
    end
    read_end, write_end = ends[0], ends[1]
    -- 写端留在本进程, 不能被子进程继承, 否则关掉写端后子进程也收不到 EOF.
    K.SetHandleInformation(write_end, HANDLE_FLAG_INHERIT, 0)
  end
  local out, out_err = open_output(opts.output)
  if not out then
    if read_end then
      K.CloseHandle(read_end)
      K.CloseHandle(write_end)
    end
    return nil, out_err
  end
  local null_in
  if not read_end then
    null_in = K.CreateFileW(wide("NUL"), 0x80000000, 0x3, inheritable(), OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nil)
  end
  si.hStdInput = read_end or null_in
  si.hStdOutput = out
  si.hStdError = out

  local flags = CREATE_NO_WINDOW
  if opts.detached then
    flags = flags + CREATE_NEW_PROCESS_GROUP + CREATE_BREAKAWAY_FROM_JOB
  end
  local pi = ffi.new("bbr_PROCESS_INFORMATION")
  local cmd = wide(command_line)
  local ok = K.CreateProcessW(nil, cmd, nil, nil, 1, flags, nil, nil, si, pi)
  if ok == 0 and opts.detached then
    -- 游戏所在的作业不允许脱离时 (ERROR_ACCESS_DENIED), 不脱离也照样能跑, 只是游戏被强杀时可能一起结束.
    flags = flags - CREATE_BREAKAWAY_FROM_JOB
    ok = K.CreateProcessW(nil, cmd, nil, nil, 1, flags, nil, nil, si, pi)
  end
  local err = ok == 0 and last_error("CreateProcessW") or nil
  -- 子进程已经继承了需要的句柄, 本进程这边的读端与输出文件都可以关了.
  if read_end then
    K.CloseHandle(read_end)
  end
  if null_in and null_in ~= INVALID_HANDLE then
    K.CloseHandle(null_in)
  end
  K.CloseHandle(out)
  if ok == 0 then
    if write_end then
      K.CloseHandle(write_end)
    end
    return nil, err
  end
  K.CloseHandle(pi.hThread)
  return { process = pi.hProcess, stdin = write_end }
end

--- 把 n 字节写进子进程的标准输入. 子进程退出后写入失败, 返回 false 与原因.
---@param proc BBWinProcess
---@param ptr ffi.cdata*|string
---@param n integer
---@return boolean ok
---@return string? err
function M.write(proc, ptr, n)
  local written = ffi.new("uint32_t[1]")
  local base = ffi.cast("const uint8_t *", ptr)
  local offset = 0
  while offset < n do
    if K.WriteFile(proc.stdin, base + offset, n - offset, written, nil) == 0 then
      return false, last_error("WriteFile")
    end
    offset = offset + written[0]
  end
  return true
end

--- 关掉标准输入 (子进程读到 EOF).
---@param proc BBWinProcess
function M.close_stdin(proc)
  if proc.stdin then
    K.CloseHandle(proc.stdin)
    proc.stdin = nil
  end
end

--- 等子进程退出, 返回退出码. 超时后结束它, 返回 nil 与原因.
---@param proc BBWinProcess
---@param timeout_ms integer
---@return integer? code
---@return string? err
function M.wait(proc, timeout_ms)
  M.close_stdin(proc)
  local code, err
  if K.WaitForSingleObject(proc.process, timeout_ms) == WAIT_OBJECT_0 then
    local out = ffi.new("uint32_t[1]")
    K.GetExitCodeProcess(proc.process, out)
    code = tonumber(out[0])
  else
    K.TerminateProcess(proc.process, 1)
    err = string.format("等待子进程超时 (%d ms), 已结束它", timeout_ms)
  end
  K.CloseHandle(proc.process)
  return code, err
end

--- 只放手不等 (后台合成): 关掉本进程持有的进程句柄, 子进程照常运行.
---@param proc BBWinProcess
function M.release(proc)
  M.close_stdin(proc)
  K.CloseHandle(proc.process)
end

--- 运行一条命令并等它结束, 返回退出码 (启动失败或超时时为 nil).
---@param argv string[]
---@param timeout_ms integer
---@return integer? code
---@return string? err
function M.run(argv, timeout_ms)
  local proc, err = M.spawn(M.command_line(argv))
  if not proc then
    return nil, err
  end
  return M.wait(proc, timeout_ms)
end

return M
