--[[
游戏内回放的入口与界面: 主菜单的 选项 -> 回放.

- 按钮登记在 bbcore 的选项菜单入口 (BB_MENU.entries) 里, 与 agent 模式无关, 只在主菜单显示
  (回放要从开局开始). 别的东西在操作游戏 (BB_CONTROL, 例如内置 agent 运行中) 时不可用.
- 列表: 扫描录像目录, 按时间倒序分页, 每行是开始时间, 牌组, 赌注, 种子, 结果, 步数, 原局时长.
  不能回放的文件不可点, 行的文字里带上原因.
- 确认页: 回放前的提示, 节奏 (tight / original), 是否录像, 然后开始.

开始时的动作: 检查互斥 -> 存档隔离 (replay/session.lua) -> 按选择设定录像 -> 关掉菜单 ->
交给 replay/player.lua (它在 BB_CONTROL 上申请独占). 结束时 player 释放独占并回调到这里: 恢复录像设置, 显示结果.

布局: 竖直排的行都直接作为 R 型兄弟展开, 不用 W.col 包. 布局引擎里 C 型节点会把横向游标推走,
它后面的 R 兄弟就整体右移, 跑出面板外面.
]]

local json = require("json")

---@type table bbcore 的 ui/widgets.lua, init 时注入
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
---@field menu table bbcore 的 ui/menu.lua (BB_MENU)
---@field control table bbcore 的 runtime/control.lua (BB_CONTROL)
---@field recorder table record/recorder.lua
---@field replay table replay/player.lua
---@field session table replay/session.lua
---@field library table replay/library.lua
---@field format table replay/format.lua
---@field toast table bbcore 的 runtime/toast.lua
---@field stream table bbcore 的 ui/stream_bar.lua
---@field widgets table bbcore 的 ui/widgets.lua (已 init)
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

-- 回放文件的相对路径: 每局一个文件夹时是 "<stem>/<stem>.replay.json".
local REPLAY_SUFFIX = ".replay.json"

--- 列表用的文件系统访问. 两种布局都列: 子文件夹里的回放文件 (每局一个文件夹), 与录像目录根下的
--- (旧版平铺). 名字是相对录像目录的路径, 读取与删除都按它拼.
---@return BBReplayFS
local function make_fs()
  local dir = recordings_dir()
  ---@param info table getDirectoryItemsInfo 返回的项
  ---@param rel string 相对录像目录的路径
  local function info_of(info, rel)
    return {
      name = rel,
      size = info.size or 0,
      mtime = math.floor(info.modtime or 0),
    }
  end
  local fs = {}
  function fs.list()
    local out = {}
    for _, entry in ipairs(SMODS.NFS.getDirectoryItemsInfo(dir, "directory") or {}) do
      local folder = entry.name or ""
      if folder ~= "" and folder ~= "." and folder ~= ".." then
        for _, inner in ipairs(SMODS.NFS.getDirectoryItemsInfo(dir .. "/" .. folder, "file") or {}) do
          local name = inner.name or ""
          if name:sub(-#REPLAY_SUFFIX) == REPLAY_SUFFIX then
            out[#out + 1] = info_of(inner, folder .. "/" .. name)
          end
        end
      end
    end
    for _, info in ipairs(SMODS.NFS.getDirectoryItemsInfo(dir, "file") or {}) do
      local name = info.name or ""
      if name:sub(-#REPLAY_SUFFIX) == REPLAY_SUFFIX then
        out[#out + 1] = info_of(info, name)
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

local open_confirm, delete_armed, delete_selected

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
    -- 不能回放的行显示成灰色但仍可点, 进确认页后只能删除.
    colour = function()
      local entry = view.entries[index]
      return (entry and entry.ok) and G.C.RED or G.C.UI.BACKGROUND_INACTIVE
    end,
    enabled = function()
      return view.entries[index] ~= nil
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

--- 回放结束后的收尾: 恢复录像设置, 显示结果. agent 由 player 释放独占时按当前模式恢复.
---@param previous {enabled: boolean, prefix: string}
---@param code integer
---@param warnings string[]
local function on_finish(previous, code, warnings)
  restore_recording(previous, "replay end")
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
  -- 按钮的可点状态每帧才刷新, 内置 agent 可能刚好在这一帧启动. 真正的独占在 player.start 里申请,
  -- 这里先查一次, 免得做完存档隔离与录像设置再回滚.
  local busy = deps.control.owner() or deps.control.busy()
  if busy then
    deps.toast.push("回放", busy .. " 正在运行, 先停止再回放", 4)
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
end

--- 内置 agent 等别的东西在操作游戏时, 开始按钮与入口不可点.
---@return boolean
local function can_start()
  return deps.control.owner() == nil and deps.control.busy() == nil
end

-- 删除要点两次: 第一次只是把按钮改成 "再点一次删除", DELETE_ARM 秒内再点才删.
local DELETE_ARM = 3
-- 局末的合成在后台进行, 中间文件这么多秒内还在变化时不删, 免得删到正在合成的文件.
local BUSY_WINDOW = 10

---@return boolean
function delete_armed()
  return confirm.armed_at ~= nil and love.timer.getTime() - confirm.armed_at < DELETE_ARM
end

--- 这一局还在后台合成: 中间文件或合成脚本在 BUSY_WINDOW 秒内改过. base 是这一局的目录加局名.
---@param base string
---@param names string[] 产物名 (相对这一局的目录)
---@return boolean
local function still_building(base, names)
  local now = os.time()
  for _, name in ipairs(names) do
    if name:match("%.video%.mp4$") or name:match("%.post%.%a+$") or name:match("%.pcm$") then
      local info = SMODS.NFS.getInfo(base .. "/" .. name, "file")
      if info and info.modtime and now - info.modtime < BUSY_WINDOW then
        return true
      end
    end
  end
  return false
end

--- 删掉一个文件夹里的全部文件, 再删文件夹本身. 只用于每局一个文件夹的局.
---@param path string
---@return integer removed
---@return string[] failed
local function remove_folder(path)
  local removed, failed = 0, {}
  for _, info in ipairs(SMODS.NFS.getDirectoryItemsInfo(path, "file") or {}) do
    local name = info.name or ""
    local ok, err = SMODS.NFS.remove(path .. "/" .. name)
    if ok then
      removed = removed + 1
    else
      failed[#failed + 1] = name
      sendWarnMessage("删除录像文件失败: " .. tostring(err), LOGGER)
    end
  end
  local ok, err = SMODS.NFS.remove(path)
  if ok then
    removed = removed + 1
  else
    failed[#failed + 1] = path:match("[^/]+$") or path
    sendWarnMessage("删除录像文件夹失败: " .. tostring(err), LOGGER)
  end
  return removed, failed
end

--- 确认页上点 "删除": 第一次只改按钮文字, 再点一次删掉这一局, 回到列表.
function delete_selected()
  local entry = confirm.entry
  if not delete_armed() then
    confirm.armed_at = love.timer.getTime()
    return
  end
  confirm.armed_at = nil
  local location, why = deps.library.locate(entry.name)
  if not location then
    deps.toast.push("回放", why .. ", 没有删除: " .. tostring(entry.name), 4)
    return
  end
  if not deps.library.deletable(location) then
    deps.toast.push("回放", "旧版平铺的录像不支持删除, 免得误删别的局", 4)
    return
  end
  local dir = recordings_dir()
  local base = dir .. "/" .. location.folder .. "/" .. location.stem
  if still_building(base, location.names) then
    deps.toast.push("回放", "这一局的视频还在合成, 稍后再删", 4)
    return
  end
  local removed, failed = remove_folder(dir .. "/" .. location.folder)
  sendInfoMessage(string.format("回放已删除: %s, 删掉 %d 个条目", entry.name, removed), LOGGER)
  if #failed > 0 then
    deps.toast.push("回放", string.format("删掉 %d 个, %d 个删不掉: %s", removed, #failed, failed[1]), 5)
  else
    deps.toast.push("回放", string.format("已删除这一局 (%d 个文件)", removed), 3)
  end
  local page = view.page
  G.FUNCS.bb_replay_list()
  -- 留在原来那一页 (删掉最后一页的最后一项时 refresh 会收敛到前一页).
  if page > 1 then
    page_by(page - 1)
  end
end

--- 这一局能不能删: 文件名认得出来, 而且是每局一个文件夹的布局. 旧版平铺的不给删.
---@return boolean
local function can_delete()
  local location = confirm.entry and deps.library.locate(confirm.entry.name)
  return location ~= nil and deps.library.deletable(location)
end

--- 删除按钮: 点一次变成 "再点一次删除", 再点才删. 返回列表由面板底部原版的 "返回" 负责.
---@return table
local function delete_button()
  return W.button({
    label = "删除",
    label_fn = function()
      return delete_armed() and "再点一次删除" or "删除"
    end,
    col = true,
    minw = 2.5,
    minh = 0.6,
    scale = 0.4,
    colour = G.C.RED,
    enabled = can_delete,
    on_click = delete_selected,
  })
end

--- 确认页上的说明文字. 不可回放的文件 (含损坏, 读不到的) 只有文件名与原因, 其余字段可能缺.
---@param entry BBReplayEntry
---@return string[]
local function confirm_lines(entry)
  local lines = { "文件: " .. entry.name }
  if not entry.ok then
    lines[#lines + 1] = "不能回放: " .. tostring(entry.reason)
  end
  if entry.deck then
    lines[#lines + 1] = string.format(
      "原局: %s | %s | %s | 种子 %s",
      tostring(entry.deck),
      tostring(entry.stake),
      tostring(entry.result),
      tostring(entry.seed)
    )
    lines[#lines + 1] =
      string.format("步数 %d, 原局时长 %s", entry.steps or 0, deps.library.duration_text(entry.duration))
  end
  if entry.ok and (entry.manual_inputs or 0) > 0 then
    lines[#lines + 1] = string.format("原局里有 %d 次手动操作, 结果可能与原局不同", entry.manual_inputs)
  end
  if entry.ok and entry.resumed then
    lines[#lines + 1] = "这是读档开局的局, 回放会从原局的存档接着走"
  end
  if not can_delete() then
    lines[#lines + 1] = "旧版平铺的录像 (文件直接放在录像目录里) 不支持删除, 免得误删别的局"
  end
  return lines
end

local function confirm_definition()
  local entry = confirm.entry
  local nodes = {
    W.row({ W.text(entry.ok and "回放这一局" or "不能回放", 0.5, G.C.FILTER) }, { align = "cm", padding = 0.05 }),
  }
  -- 建立后不再变, 用静态文本节点即可.
  for _, line in ipairs(confirm_lines(entry)) do
    nodes[#nodes + 1] = W.row({ W.text(W.fit_text(line, ROW_TEXT_W, 0.3), 0.3) }, { align = "cm" })
  end
  if not entry.ok then
    -- 不能回放的只留删除.
    nodes[#nodes + 1] = button_bar({ delete_button() })
    return panel("bb_replay_list", nodes)
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
      enabled = can_start,
      on_click = start_selected,
    }),
    delete_button(),
  })
  return panel("bb_replay_list", nodes)
end

---@param entry BBReplayEntry
function open_confirm(entry)
  confirm.entry = entry
  confirm.armed_at = nil
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
    enabled = can_start,
    on_click = function()
      G.FUNCS.bb_replay_list()
    end,
  })
end

---@param options BBReplayMenuDeps
function M.init(options)
  deps = options
  W = options.widgets
  options.menu.entries[#options.menu.entries + 1] = replay_entry
end

return M
