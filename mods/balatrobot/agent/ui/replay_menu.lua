--[[
游戏内回放的入口与界面: 主菜单的 选项 -> 回放.

- 按钮通过 BB_AGENT_MENU.menu_entries 挂钩插入 ESC 菜单, 与 agent 模式无关, 只在主菜单显示
  (回放要从开局开始), 内置 loop 运行中不可用.
- 列表: 扫描录像目录, 按时间倒序分页, 每行是开始时间, 牌组, 赌注, 种子, 结果, 步数, 原局时长.
  不能回放的文件不可点, 行的文字里带上原因.
- 确认页: 回放前的提示, 节奏 (tight / original), 是否录像, 然后开始.

开始时的动作: 检查互斥 -> 存档隔离 (agent/replay/session.lua) -> 按选择设定录像 -> 关掉菜单 ->
交给 agent/replay/player.lua. 结束时 player 回调到这里: 恢复录像设置, 恢复 agent 监听, 显示结果.
]]

local json = require("json")

---@type table agent/ui/widgets.lua, init 时注入
local W

local LOGGER = "BB.AGENT.REPLAY.MENU"
local PER_PAGE = 6

local M = {}

---@class BBReplayMenuDeps
---@field mod table SMODS mod 对象, 用于取存档目录
---@field agent_menu table agent/ui/agent_menu.lua
---@field runner table agent/runner.lua
---@field mode table agent/mode.lua 的实例
---@field recorder table agent/record/recorder.lua
---@field replay table agent/replay/player.lua
---@field session table agent/replay/session.lua
---@field library table agent/replay/library.lua
---@field snapshot table agent/replay/snapshot.lua
---@field format table agent/replay/format.lua
---@field toast table agent/toast.lua
---@field stream table agent/ui/stream_bar.lua
---@field widgets table agent/ui/widgets.lua (已 init)
local deps

local view = {
  page = 1,
  pages = 1,
  notice = "",
  header = "",
  lines = {}, -- 当前页每行的文字
  enabled = {}, -- 当前页每行能不能点
  entries = {}, -- 当前页对应的列表项
}

local confirm = {
  entry = nil,
  pacing = "tight",
  record = false,
  lines = {},
}

--- 录像目录: 与录像输出同一个目录, 回放文件写在录像旁边.
local function recordings_dir()
  local dir = os.getenv("BALATROBOT_RECORD_DIR")
  if dir and dir ~= "" then
    return dir:gsub("/+$", "")
  end
  return love.filesystem.getSaveDirectory() .. "/recordings"
end

--- 列表用的文件系统访问: 目录下的 *.replay.json.
---@return BBReplayFS
local function make_fs()
  local dir = recordings_dir()
  local fs = {}
  function fs.list()
    local out = {}
    for _, info in ipairs(SMODS.NFS.getDirectoryItemsInfo(dir, "file") or {}) do
      local name = info.name or ""
      if name:sub(-12) == ".replay.json" then
        out[#out + 1] = {
          name = name,
          size = info.size or 0,
          mtime = math.floor(info.modtime or 0),
        }
      end
    end
    return out
  end
  function fs.read(name)
    return SMODS.NFS.read(dir .. "/" .. name)
  end
  return fs
end

local cache = {}

--- 重新扫描一遍, 刷新当前页的文字.
local function refresh()
  local fs = make_fs()
  local entries
  local ok, err = pcall(function()
    entries, cache = deps.library.list(fs, {
      supported_version = deps.format.VERSION,
      decode = json.decode,
      cache = cache,
      log = function(text)
        sendDebugMessage(text, LOGGER)
      end,
    })
  end)
  if not ok then
    view.notice = "扫描录像目录失败: " .. tostring(err)
    view.lines, view.enabled, view.entries = {}, {}, {}
    view.header = "回放"
    view.pages = 1
    return
  end
  local items, page, pages = deps.library.paginate(entries, view.page, PER_PAGE)
  view.page, view.pages = page, pages
  view.lines, view.enabled, view.entries = {}, {}, {}
  for i, entry in ipairs(items) do
    view.lines[i] = deps.library.line_text(entry)
    view.enabled[i] = entry.ok
    view.entries[i] = entry
  end
  view.header = string.format("回放 (%d 个文件, 第 %d / %d 页)", #entries, page, pages)
  view.notice = #entries == 0 and "录像目录里没有 *.replay.json: 打开录像后每局都会写一个" or ""
end

G.FUNCS.bb_replay_refresh = function(_e)
  if deps then
    refresh()
  end
end

local function page_by(delta)
  view.page = math.max(1, view.page + delta)
  refresh()
end

G.FUNCS.bb_replay_prev = function(_e)
  page_by(-1)
end

G.FUNCS.bb_replay_next = function(_e)
  page_by(1)
end

--- 一行按钮: 点了进确认页.
---@param index integer
---@return table
local function entry_row(index)
  return W.button({
    label = "",
    -- 翻页只换 view 里的内容, 菜单不重建: 这些函数每帧被调用, 新的文字直接反映出来.
    label_fn = function()
      return view.lines[index] or ""
    end,
    minw = 9,
    minh = 0.5,
    scale = 0.3,
    enabled = function()
      return view.enabled[index] == true
    end,
    on_click = function()
      confirm.entry = view.entries[index]
      if confirm.entry then
        G.FUNCS.bb_replay_confirm_page()
      end
    end,
  })
end

--- 列表页.
local function list_definition()
  refresh()
  local rows = {}
  for i = 1, PER_PAGE do
    if view.lines[i] then
      rows[#rows + 1] = entry_row(i)
    end
  end
  local nodes = {
    W.row({ W.text("回放", 0.5, G.C.FILTER) }, { align = "cm", padding = 0.05 }),
    W.row({ W.live(view, "header", 0.32) }, { align = "cm" }),
    W.row({ W.live(view, "notice", 0.3, G.C.UI.TEXT_INACTIVE) }, { align = "cm" }),
    W.col(rows, { align = "cm" }),
    W.row({
      W.col({
        W.button({
          label = "上一页",
          col = true,
          minw = 2,
          minh = 0.6,
          scale = 0.4,
          enabled = function()
            return view.page > 1
          end,
          on_click = function()
            G.FUNCS.bb_replay_prev()
          end,
        }),
        W.button({
          label = "下一页",
          col = true,
          minw = 2,
          minh = 0.6,
          scale = 0.4,
          enabled = function()
            return view.page < view.pages
          end,
          on_click = function()
            G.FUNCS.bb_replay_next()
          end,
        }),
      }, { align = "cm" }),
    }, { align = "cm", padding = 0.1 }),
  }
  return create_UIBox_generic_options({
    back_func = "options",
    contents = {
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.1, minw = 9 },
        nodes = { W.col(nodes, { align = "cm", padding = 0.05 }) },
      },
    },
  })
end

G.FUNCS.bb_replay_list = function(_e)
  G.SETTINGS.paused = true
  view.page = 1
  G.FUNCS.overlay_menu({ definition = list_definition() })
end

--- 确认页上的提示文字: 原局有手动操作, 版本不一致, 读档开局.
local function confirm_warnings(entry)
  local list = {}
  if entry.manual_inputs and entry.manual_inputs > 0 then
    list[#list + 1] = string.format("原局里有 %d 次手动操作, 结果可能与原局不同", entry.manual_inputs)
  end
  if entry.resumed then
    list[#list + 1] = "这是读档开局的局, 回放会从原局的存档接着走"
  end
  return list
end

local function confirm_definition()
  local entry = confirm.entry
  local lines = {
    "文件: " .. tostring(entry.name),
    string.format("原局: %s | %s | %s | 种子 %s", entry.deck or "?", entry.stake or "?", entry.result or "?", entry.seed or "?"),
    string.format("步数 %d, 原局时长 %s", entry.steps or 0, deps.library.duration_text(entry.duration or 0)),
  }
  for _, text in ipairs(confirm_warnings(entry)) do
    lines[#lines + 1] = text
  end
  confirm.lines = lines

  local rows = {}
  for i = 1, #confirm.lines do
    rows[#rows + 1] = W.row({ W.live(confirm.lines, tostring(i), 0.3) }, { align = "cm" })
  end

  local nodes = {
    W.row({ W.text("回放这一局", 0.5, G.C.FILTER) }, { align = "cm", padding = 0.05 }),
    W.col(rows, { align = "cm" }),
    W.row({
      W.text("节奏", 0.32),
      W.radio({
        { "tight", "紧凑" },
        { "original", "原速" },
      }, function()
        return confirm.pacing
      end, function(value)
        confirm.pacing = value
      end),
    }, { align = "cm", padding = 0.06 }),
    W.row({
      W.text("录像", 0.32),
      W.radio({
        { false, "不录" },
        { true, "录" },
      }, function()
        return confirm.record
      end, function(value)
        confirm.record = value
      end),
    }, { align = "cm", padding = 0.06 }),
    W.row({
      W.col({
        W.button({
          label = "开始回放",
          col = true,
          minw = 2.5,
          minh = 0.6,
          scale = 0.4,
          colour = G.C.GREEN,
          enabled = function()
            return not deps.runner.is_busy()
          end,
          on_click = function()
            M.start_selected()
          end,
        }),
        W.button({
          label = "返回列表",
          col = true,
          minw = 2.5,
          minh = 0.6,
          scale = 0.4,
          on_click = function()
            G.FUNCS.bb_replay_list()
          end,
        }),
      }, { align = "cm" }),
    }, { align = "cm", padding = 0.1 }),
  }
  return create_UIBox_generic_options({
    back_func = "bb_replay_list",
    contents = {
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.1, minw = 9 },
        nodes = { W.col(nodes, { align = "cm", padding = 0.05 }) },
      },
    },
  })
end

G.FUNCS.bb_replay_confirm_page = function(_e)
  if not confirm.entry then
    return
  end
  G.SETTINGS.paused = true
  G.FUNCS.overlay_menu({ definition = confirm_definition() })
end

--- 回放结束后的收尾: 恢复录像设置, 让 agent 按当前模式重新生效, 显示结果.
---@param previous {enabled: boolean, prefix: string}
local function on_finish(previous, code, result, warnings)
  deps.recorder.set_enabled(previous.enabled == true, "replay end")
  deps.recorder.set_prefix(previous.prefix or "")
  deps.mode.apply()
  local text = string.format("回放%s", result)
  if code == 1 then
    text = "回放跑偏, 已停止"
  elseif code == 2 then
    text = "回放已中止"
  elseif code == 3 then
    text = "回放无法继续"
  end
  local detail = #warnings > 0 and ("; " .. table.concat(warnings, ", ")) or ""
  deps.toast.push("回放", text .. detail, 6)
  deps.stream.show_status(text .. detail, 6)
  -- 回放结束时多半已经回到主菜单; 还在局内就自己回主菜单.
  if G.STATE ~= G.STATES.MENU then
    local ok, err = pcall(G.FUNCS.go_to_menu, {})
    if not ok then
      sendWarnMessage("回主菜单失败: " .. tostring(err), LOGGER)
    end
  end
end

--- 确认页上点 "开始回放".
function M.start_selected()
  local entry = confirm.entry
  if not entry then
    return
  end
  if deps.runner.is_busy() then
    deps.toast.push("回放", "内置 agent 正在运行, 先停止再回放", 4)
    return
  end
  local path = recordings_dir() .. "/" .. entry.name
  local ok, reason = deps.session.begin({
    "settings.jkr",
    tostring(G.SETTINGS.profile or 1) .. "/profile.jkr",
    tostring(G.SETTINGS.profile or 1) .. "/meta.jkr",
    tostring(G.SETTINGS.profile or 1) .. "/save.jkr",
  })
  if not ok then
    deps.toast.push("回放", "无法开始: " .. tostring(reason), 5)
    return
  end
  local previous = { enabled = deps.recorder.enabled == true, prefix = deps.recorder.get_prefix() }
  deps.recorder.set_prefix("replay-")
  deps.recorder.set_enabled(confirm.record == true, "in-game replay")
  -- 回放要开局, 不能停在菜单上.
  G.FUNCS.exit_overlay_menu()
  local started, err = deps.replay.start({
    path = path,
    pacing = confirm.pacing,
    on_finish = function(code, result, warnings)
      on_finish(previous, code, result, warnings)
    end,
    session = deps.session,
  })
  if not started then
    deps.recorder.set_enabled(previous.enabled, "replay rollback")
    deps.recorder.set_prefix(previous.prefix)
    deps.session.finish()
    deps.toast.push("回放", "无法开始: " .. tostring(err), 5)
    G.FUNCS.bb_replay_list()
    return
  end
  -- 回放期间不开端口: 外部模式下暂停监听 (mode.apply 里据此判断), 结束后由 on_finish 恢复.
  deps.mode.apply()
end

--- ESC 菜单的 "回放" 按钮: 只在主菜单显示, 内置 loop 运行中不可用.
---@return table?
local function replay_entry()
  if G.STAGE ~= G.STAGES.MENU then
    return nil
  end
  if deps.replay.active then
    return nil
  end
  return W.button({
    label = "回放",
    minw = 5,
    minh = 0.9,
    scale = 0.5,
    padding = 0,
    outer_padding = 0,
    colour = G.C.BLUE,
    enabled = function()
      return not deps.runner.is_busy()
    end,
    on_click = function()
      G.FUNCS.bb_replay_list()
    end,
  })
end

---@param options BBReplayMenuDeps
function M.init(options)
  deps = options
  W = options.widgets
  deps.agent_menu.menu_entries[#deps.agent_menu.menu_entries + 1] = replay_entry
end

return M
