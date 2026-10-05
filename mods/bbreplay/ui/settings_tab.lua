--[[
bbreplay 的设置页 (模组 -> BB Replay -> 配置), 即 MOD.config_tab.

视频与回放文件的独立开关, 视频保留方式, 清晰度, 帧率与码率, 录制与回放的状态行. 回放本身从 选项 -> 回放 进入,
节奏与是否录像每次在确认页选. 状态行每帧由根节点的 func 刷新.
]]

---@type table bbcore 的 ui/widgets.lua, init 时注入
local W
-- 纯逻辑模块, 与录像器各加载一份也没关系.
local Quality = assert(SMODS.load_file("record/quality.lua", "bbreplay"))()

local M = {}

local SCALE = 0.3
local LABEL_W = 1.3

-- 清晰度, 帧率, 码率三行: 设置项, 配置字段, 标题, 选项 ({值, 文字}, 0 为默认).
local QUALITY_ROWS = {
  { key = "height", field = "record_height", label = "清晰度", default = "默认", unit = "p", choices = Quality.HEIGHTS },
  { key = "fps", field = "record_fps", label = "帧率", default = "默认", unit = "", choices = Quality.FPS },
  { key = "bitrate", field = "record_bitrate", label = "码率", default = "自动", unit = "M", choices = Quality.BITRATES },
}

---@class BBReplaySettingsDeps
---@field mod table SMODS mod 对象
---@field recorder table record/recorder.lua
---@field replay table replay/player.lua
---@field replay_log table? replay/log.lua, 命令行回放时不加载
---@field record_replay_env string? 启动时的 BALATROBOT_RECORD_REPLAY
---@field record_video_env string? 启动时的 BALATROBOT_RECORD_VIDEO
---@field widgets table bbcore 的 ui/widgets.lua (已 init)
local deps

local view = {
  record_line = "",
  record_replay_line = "",
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
  view.record_line = "视频录制: " .. tostring(deps.recorder.status)
  view.record_replay_line = "回放文件录制: " .. (deps.replay_log and tostring(deps.replay_log.status) or "回放中不录制")
  view.replay_line = "回放: " .. tostring(deps.replay.status)
end

G.FUNCS.bbr_settings_refresh = function(_e)
  if deps then
    refresh_status()
  end
end

--- 清晰度, 帧率或码率的一行. 设了对应环境变量时只显示环境变量的值, 不能在这里改.
---@param row table QUALITY_ROWS 的一项
---@return table
local function quality_row(row)
  local label = W.col({ W.text(row.label, SCALE) }, { minw = LABEL_W })
  local env_name = Quality.ENV[row.key]
  local env_value = os.getenv(env_name)
  if env_value and env_value ~= "" then
    return W.row({
      label,
      W.text("以环境变量 " .. env_name .. "=" .. env_value .. " 为准", 0.26, G.C.UI.TEXT_INACTIVE),
    })
  end
  local options = {}
  for i, value in ipairs(row.choices) do
    options[i] = { value, value == 0 and row.default or (value .. row.unit) }
  end
  if row.key ~= "bitrate" then
    table.insert(options, 1, { 0, row.default })
  end
  return W.row({
    label,
    W.radio(options, function()
      -- 手改过配置文件, 值不在可选范围内时显示为默认 (录像器也按默认处理).
      local value = config()[row.field]
      return Quality.pick(row.key, value, false) == value and value or 0
    end, function(value)
      config()[row.field] = value
      deps.recorder.set_quality(row.key, value)
      save()
    end, { minw = 0.85, scale = SCALE }),
  })
end

local function record_nodes()
  local nodes = { W.title("录制") }
  if deps.record_replay_env and deps.record_replay_env ~= "" then
    nodes[#nodes + 1] = W.row({
      W.text("以环境变量 BALATROBOT_RECORD_REPLAY=" .. deps.record_replay_env .. " 为准", SCALE, G.C.UI.TEXT_INACTIVE),
    })
  else
    nodes[#nodes + 1] = W.localize_tree(create_toggle({
      label = "录制回放文件",
      ref_table = config(),
      ref_value = "record_replay",
      w = 3.2,
      label_scale = SCALE,
      callback = function(value)
        save()
        if deps.replay_log then
          deps.replay_log.set_enabled(value, "settings")
        end
      end,
    }))
  end
  nodes[#nodes + 1] = W.row({
    W.text("回放文件从下一局起录制; 关闭时保存当前记录", 0.26, G.C.UI.TEXT_INACTIVE),
  })
  if deps.record_video_env and deps.record_video_env ~= "" then
    nodes[#nodes + 1] = W.row({
      W.text("以环境变量 BALATROBOT_RECORD_VIDEO=" .. deps.record_video_env .. " 为准", SCALE, G.C.UI.TEXT_INACTIVE),
    })
  else
    nodes[#nodes + 1] = W.localize_tree(create_toggle({
      label = "录制视频",
      ref_table = config(),
      ref_value = "record_video",
      w = 3.2,
      label_scale = SCALE,
      callback = function(value)
        save()
        deps.recorder.set_enabled(value, "settings")
      end,
    }))
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
  for _, row in ipairs(QUALITY_ROWS) do
    nodes[#nodes + 1] = quality_row(row)
  end
  local defaults = Quality.defaults(love._os == "Android")
  nodes[#nodes + 1] = W.row({
    W.text(
      string.format("默认 %dp %dfps; 改动从下一段录像起生效", defaults.height, defaults.fps),
      0.26,
      G.C.UI.TEXT_INACTIVE
    ),
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
  nodes[#nodes + 1] = W.row({ W.live(view, "record_replay_line", 0.28) })
  nodes[#nodes + 1] = W.row({ W.live(view, "replay_line", 0.28) })
  nodes[#nodes + 1] = W.row({ W.text("回放: 主菜单 选项 -> 回放", 0.26, G.C.UI.TEXT_INACTIVE) })
  return {
    n = G.UIT.ROOT,
    config = { align = "cm", padding = 0.15, r = 0.1, colour = G.C.BLACK, func = "bbr_settings_refresh" },
    nodes = { W.col(nodes, { minw = 6.2, padding = 0.05 }) },
  }
end

return M
