--[[
游戏内回放的入口与界面: 主菜单的 选项 -> 回放.

- 按钮通过 BB_AGENT_MENU.menu_entries 挂钩插入 ESC 菜单, 与 agent 模式无关, 只在主菜单显示
  (回放要从开局开始), 内置 loop 运行中不可用.
- 列表: 扫描录像目录, 按时间倒序分页, 每行是开始时间, 牌组, 赌注, 种子, 结果, 步数, 原局时长.
  不能回放的文件不可点, 行的文字里带上原因.
- 确认页: 回放前的提示, 节奏 (tight / original), 是否录像, 然后开始.

开始时的动作: 检查互斥 -> 存档隔离 (agent/replay/session.lua) -> 按选择设定录像 -> 关掉菜单 ->
交给 agent/replay/player.lua. 结束时 player 回调到这里: 恢复录像设置, 恢复 agent 监听, 显示结果.

布局: 竖直排的行都直接作为 R 型兄弟展开, 不用 W.col 包. 布局引擎里 C 型节点会把横向游标推走,
它后面的 R 兄弟就整体右移, 跑出面板外面.
]]

local json = require("json")

---@type table agent/ui/widgets.lua, init 时注入
local W

local LOGGER = "BB.AGENT.REPLAY.MENU"
local PER_PAGE = 6
-- 面板内容宽度 (UI 单位). 行文字按它减去按钮内边距裁断, 这样每行宽度固定, 布局与内容无关.
local PANEL_W = 9
local ROW_TEXT_W = PANEL_W - 0.9

-- 游戏内回放只会以这三种结果结束 (3 "文件无法回放" 只出现在命令行回放).
local FINISH_TEXT = {
  [0] = "回放完成",
  [1] = "回放跑偏, 已停止",
  [2] = "回放已中止",
}

local M = {}

---@class BBReplayMenuDeps
---@field agent_menu table agent/ui/agent_menu.lua
---@field runner table agent/runner.lua
---@field mode table agent/mode.lua 的实例
---@field recorder table agent/record/recorder.lua
---@field replay table agent/replay/player.lua
---@field session table agent/replay/session.lua
---@field library table agent/replay/library.lua
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
  entries = {}, -- 当前页对应的列表项
}

local confirm = {
  entry = nil,
  pacing = "tight",
  record = false,
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
  local entries
  local ok, err = pcall(function()
    entries, cache = deps.library.list(make_fs(), {
      supported_version = deps.format.VERSION,
      is_tutorial = deps.format.is_tutorial,
      decode = json.decode,
      cache = cache,
      log = function(text)
        sendDebugMessage(text, LOGGER)
      end,
    })
  end)
  view.lines, view.entries = {}, {}
  if not ok then
    view.notice = "扫描录像目录失败: " .. tostring(err)
    view.header = "回放"
    view.pages = 1
    return
  end
  local items, page, pages = deps.library.paginate(entries, view.page, PER_PAGE)
  view.page, view.pages = page, pages
  for i, entry in ipairs(items) do
    view.lines[i] = deps.library.line_text(entry)
    view.entries[i] = entry
  end
  view.header = string.format("回放 (%d 个文件, 第 %d / %d 页)", #entries, page, pages)
  view.notice = #entries == 0 and "录像目录里没有 *.replay.json: 打开录像后每局都会写一个" or ""
end

--- 翻页: 只换 view 里的内容, 菜单不重建. 行文字由 label_fn 每帧读出, 宽度已固定, 布局不受影响.
---@param delta integer
local function page_by(delta)
  view.page = math.max(1, view.page + delta)
  refresh()
end

--- 页面外框: 标题与内容竖排在一个固定宽度的面板里.
---@param back_func string
---@param nodes table[]
local function panel(back_func, nodes)
  return create_UIBox_generic_options({
    back_func = back_func,
    contents = {
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.1, minw = PANEL_W },
        nodes = { W.col(nodes, { align = "cm", padding = 0.05 }) },
      },
    },
  })
end

--- 一排横向的按钮.
local function button_bar(buttons)
  return W.row({ W.col(buttons, { align = "cm" }) }, { align = "cm", padding = 0.1 })
end

local open_confirm

--- 一行按钮: 点了进确认页.
---
--- 文字先裁到 ROW_TEXT_W (小于按钮的 minw) 再交给 label_fn: 按钮宽度因此恒等于 minw, 翻页换文字
--- 也不改变布局. 不裁的话文本节点量出的宽度会撑开面板, 后面的行跟着错位
--- (game/engine/ui.lua 的 update_text 在文本长度变化时会 recalculate 整个 overlay).
---@param index integer
---@return table
local function entry_row(index)
  local function fitted()
    return W.fit_text(view.lines[index] or "", ROW_TEXT_W, 0.3)
  end
  return W.button({
    label = fitted(),
    label_fn = fitted,
    minw = PANEL_W,
    minh = 0.5,
    scale = 0.3,
    enabled = function()
      local entry = view.entries[index]
      return entry ~= nil and entry.ok
    end,
    on_click = function()
      -- 按钮的可点状态每帧刷新一次, 翻页后的第一帧还可能点到空行.
      if view.entries[index] then
        open_confirm(view.entries[index])
      end
    end,
  })
end

local function list_definition()
  refresh()
  local nodes = {
    W.row({ W.text("回放", 0.5, G.C.FILTER) }, { align = "cm", padding = 0.05 }),
    W.row({ W.live(view, "header", 0.32) }, { align = "cm" }),
    W.row({ W.live(view, "notice", 0.3, G.C.UI.TEXT_INACTIVE) }, { align = "cm" }),
  }
  for i = 1, PER_PAGE do
    if view.lines[i] then
      nodes[#nodes + 1] = entry_row(i)
    end
  end
  nodes[#nodes + 1] = button_bar({
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
        page_by(-1)
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
        page_by(1)
      end,
    }),
  })
  return panel("options", nodes)
end

G.FUNCS.bb_replay_list = function(_e)
  G.SETTINGS.paused = true
  view.page = 1
  G.FUNCS.overlay_menu({ definition = list_definition() })
end

---@param previous {enabled: boolean, prefix: string}
---@param reason string
local function restore_recording(previous, reason)
  deps.recorder.set_enabled(previous.enabled, reason)
  deps.recorder.set_prefix(previous.prefix)
end

--- 回放结束后的收尾: 恢复录像设置, 让 agent 按当前模式重新生效, 显示结果.
---@param previous {enabled: boolean, prefix: string}
---@param code integer
---@param warnings string[]
local function on_finish(previous, code, warnings)
  restore_recording(previous, "replay end")
  deps.mode.apply()
  local text = FINISH_TEXT[code]
  if #warnings > 0 then
    text = text .. "; " .. table.concat(warnings, ", ")
  end
  deps.toast.push("回放", text, 6)
  deps.stream.show_status(text, 6)
  -- 回放结束时多半已经回到主菜单; 还在局内就自己回主菜单.
  if G.STATE ~= G.STATES.MENU then
    local ok, err = pcall(G.FUNCS.go_to_menu, {})
    if not ok then
      sendWarnMessage("回主菜单失败: " .. tostring(err), LOGGER)
    end
  end
end

--- 确认页上点 "开始回放".
local function start_selected()
  local entry = confirm.entry
  -- 按钮的可点状态每帧才刷新, 内置 agent 可能刚好在这一帧启动.
  if deps.runner.is_busy() then
    deps.toast.push("回放", "内置 agent 正在运行, 先停止再回放", 4)
    return
  end
  local profile = tostring(G.SETTINGS.profile or 1)
  local ok, reason = deps.session.begin({
    "settings.jkr",
    profile .. "/profile.jkr",
    profile .. "/meta.jkr",
    profile .. "/save.jkr",
  })
  if not ok then
    deps.toast.push("回放", "无法开始: " .. tostring(reason), 5)
    return
  end
  local previous = { enabled = deps.recorder.enabled == true, prefix = deps.recorder.get_prefix() }
  deps.recorder.set_prefix("replay-")
  deps.recorder.set_enabled(confirm.record, "in-game replay")
  -- 回放要开局, 不能停在菜单上.
  G.FUNCS.exit_overlay_menu()
  local started, err = deps.replay.start({
    path = recordings_dir() .. "/" .. entry.name,
    pacing = confirm.pacing,
    on_finish = function(code, warnings)
      on_finish(previous, code, warnings)
    end,
  })
  if not started then
    restore_recording(previous, "replay rollback")
    deps.session.finish()
    deps.toast.push("回放", "无法开始: " .. tostring(err), 5)
    G.FUNCS.bb_replay_list()
    return
  end
  -- 回放期间不开端口: 外部模式下暂停监听 (mode.apply 里据此判断), 结束后由 on_finish 恢复.
  deps.mode.apply()
end

local function confirm_definition()
  local entry = confirm.entry
  local lines = {
    "文件: " .. entry.name,
    string.format("原局: %s | %s | %s | 种子 %s", entry.deck, entry.stake, entry.result, entry.seed),
    string.format("步数 %d, 原局时长 %s", entry.steps, deps.library.duration_text(entry.duration)),
  }
  if entry.manual_inputs > 0 then
    lines[#lines + 1] = string.format("原局里有 %d 次手动操作, 结果可能与原局不同", entry.manual_inputs)
  end
  if entry.resumed then
    lines[#lines + 1] = "这是读档开局的局, 回放会从原局的存档接着走"
  end

  local nodes = {
    W.row({ W.text("回放这一局", 0.5, G.C.FILTER) }, { align = "cm", padding = 0.05 }),
  }
  -- 建立后不再变, 用静态文本节点即可.
  for _, line in ipairs(lines) do
    nodes[#nodes + 1] = W.row({ W.text(W.fit_text(line, ROW_TEXT_W, 0.3), 0.3) }, { align = "cm" })
  end
  nodes[#nodes + 1] = W.row({
    W.text("节奏", 0.32),
    W.radio({
      { "tight", "紧凑" },
      { "original", "原速" },
    }, function()
      return confirm.pacing
    end, function(value)
      confirm.pacing = value
    end),
  }, { align = "cm", padding = 0.06 })
  nodes[#nodes + 1] = W.row({
    W.text("录像", 0.32),
    W.radio({
      { false, "不录" },
      { true, "录" },
    }, function()
      return confirm.record
    end, function(value)
      confirm.record = value
    end),
  }, { align = "cm", padding = 0.06 })
  nodes[#nodes + 1] = button_bar({
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
      on_click = start_selected,
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
  })
  return panel("bb_replay_list", nodes)
end

---@param entry BBReplayEntry
function open_confirm(entry)
  confirm.entry = entry
  G.SETTINGS.paused = true
  G.FUNCS.overlay_menu({ definition = confirm_definition() })
end

--- 回放入口只在主菜单显示: 回放要从开局开始, 局内进来没有意义.
--- 常量名容易写错 (G.STAGES 只有 MAIN_MENU / RUN / SANDBOX, 没有 MENU), 拿错时 compare 恒为假,
--- 按钮会静默消失, 所以单独成函数并有单测.
---@param stage integer? G.STAGE
---@param stages table? G.STAGES
---@return boolean
function M.menu_visible(stage, stages)
  if not stage or not stages then
    return false
  end
  return stage == stages.MAIN_MENU
end

--- ESC 菜单的 "回放" 按钮: 只在主菜单显示, 内置 loop 运行中不可用.
---@return table?
local function replay_entry()
  if not M.menu_visible(G.STAGE, G.STAGES) or deps.replay.active then
    return nil
  end
  return W.button({
    label = "回放",
    minw = 5,
    minh = 0.9,
    scale = 0.5,
    padding = 0,
    outer_padding = 0,
    colour = G.C.RED,
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
