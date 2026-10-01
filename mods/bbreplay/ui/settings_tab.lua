--[[
bbreplay 的设置页 (模组 -> BB Replay -> 配置), 即 MOD.config_tab.

录像的开关与保留方式, 录像与回放的状态行. 回放本身从 选项 -> 回放 进入, 节奏与是否录像每次在确认页选.
状态行每帧由根节点的 func 刷新.
]]

---@type table bbcore 的 ui/widgets.lua, init 时注入
local W

local M = {}

local SCALE = 0.3
local LABEL_W = 1.3

---@class BBReplaySettingsDeps
---@field mod table SMODS mod 对象
---@field recorder table record/recorder.lua
---@field replay table replay/player.lua
---@field record_env string? 启动时的 BALATROBOT_RECORD
---@field widgets table bbcore 的 ui/widgets.lua (已 init)
local deps

local view = {
  record_line = "",
  replay_line = "",
}

---@param options BBReplaySettingsDeps
function M.init(options)
  deps = options
  W = options.widgets
end

local function config()
  return deps.mod.config
end

local function save()
  SMODS.save_mod_config(deps.mod)
end

local function refresh_status()
  view.record_line = "录像: " .. tostring(deps.recorder.status)
  view.replay_line = "回放: " .. tostring(deps.replay.status)
end

G.FUNCS.bbr_settings_refresh = function(_e)
  if deps then
    refresh_status()
  end
end

local function record_nodes()
  local nodes = { W.title("录像") }
  if deps.record_env and deps.record_env ~= "" then
    nodes[#nodes + 1] = W.row({
      W.text("以环境变量 BALATROBOT_RECORD=" .. deps.record_env .. " 为准", SCALE, G.C.UI.TEXT_INACTIVE),
    })
  else
    nodes[#nodes + 1] = W.localize_tree(create_toggle({
      label = "录制对局",
      ref_table = config(),
      ref_value = "record",
      w = 3.2,
      label_scale = SCALE,
      callback = function(value)
        save()
        deps.recorder.set_enabled(value, "settings")
      end,
    }))
    nodes[#nodes + 1] = W.row({
      W.text("分辨率与帧率用默认值, 桌面可用环境变量改", 0.26, G.C.UI.TEXT_INACTIVE),
    })
  end
  nodes[#nodes + 1] = W.row({
    W.col({ W.text("保留方式", SCALE) }, { minw = LABEL_W }),
    W.radio({ { "skip", "skip" }, { "keep", "keep" } }, function()
      return config().record_keep
    end, function(value)
      config().record_keep = value
      deps.recorder.set_keep(value)
      save()
    end, { minw = 1.1, scale = SCALE }),
  })
  return nodes
end

--- MOD.config_tab
---@return table
function M.build()
  refresh_status()
  local nodes = record_nodes()
  nodes[#nodes + 1] = W.title("状态")
  nodes[#nodes + 1] = W.row({ W.live(view, "record_line", 0.28) })
  nodes[#nodes + 1] = W.row({ W.live(view, "replay_line", 0.28) })
  nodes[#nodes + 1] = W.row({ W.text("回放: 主菜单 选项 -> 回放", 0.26, G.C.UI.TEXT_INACTIVE) })
  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.15, r = 0.1, colour = G.C.BLACK, func = "bbr_settings_refresh" },
    nodes = { W.col(nodes, { minw = 6.2, padding = 0.05 }) },
  }
end

return M
