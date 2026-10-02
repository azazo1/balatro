--[[
流式条: 画面顶部居中的一行, 显示内置 agent 最新输出的尾部, 让观众知道模型在工作.

- 外观与 runtime/toast.lua 一致 (仿原版成就通知): 黑底灰描边, 外圈 TRANSPARENT_DARK. 从上方滑入, 空闲时滑回屏幕外.
- 内容是分段缓冲 {kind, text}, 截取与拆段在 ui/stream_text.lua (纯逻辑, 有单测).
  reasoning 灰色, content 白色, error 红色, status 金色; 同一行里可以有几种颜色.
- 渲染用固定数量的 ref_table 文本节点, 文字长度变化时引擎自动重算布局; 刷新限制在约 18 Hz.
- 首个增量到达时滑入; 请求结束后停留 LINGER 秒再收起, 期间下一个请求开始输出就直接换内容.
- 报错立即滑入显示红字; show_error 的文字可以是函数, 每次刷新重新求值, 倒计时因此实时更新.
- begin_request 可以带一个固定在行首的金色前缀 (压缩上下文时为 "压缩中: "), 带前缀时立刻滑入, 输出接在后面滚动.
- UIBox 挂在 G.ROOM_ATTACH 上 (POPUP 层, 在覆盖菜单之上), 阶段切换重建 ROOM_ATTACH 时自己重建.
]]

local Text = assert(SMODS.load_file("ui/stream_text.lua", "bbcore"))()

local M = {}

local LINE_WIDTH = 10 -- 游戏单位, 文字区宽度
local FIT = 0.96 -- 截取时留一点余量, 逐字累加的宽度与整串测宽有细微差别
local TEXT_SCALE = 0.36
local MAX_PIECES = 4
local REFRESH = 1 / 18
local ENTER_DELAY = 0.1 -- 等 UIBox 算出尺寸再滑入, 与 toast 一致
local LEAVE_TIME = 0.6 -- 滑出后再移除
local LINGER = 1.5 -- 请求结束后停留的秒数
local STATUS_HOLD = 1.5
-- 对齐方式 "tmi": 水平居中, offset.y 为顶边相对 ROOM 顶边的位置.
local SHOWN_Y = 0.05
local HIDDEN_Y = -3 -- 收起时移到屏幕外, 宽屏时 ROOM 上方还有留白, 要多移一些

---@type table? toast 模块, 提供 text_width 与 pick_lang
local toast

local buffer = Text.new_buffer(400)

-- 显示状态
local state = {
  showing = false,
  mode = "stream", ---@type "stream"|"error"|"status"
  message = nil, ---@type string|fun(): string|nil
  hold = nil, ---@type number? 剩余停留秒数, nil 表示一直显示到下一次变化
  request = false, -- 请求进行中
  fresh = false, -- 下一个增量到达时先清空旧内容
  label = nil, ---@type string? 固定在行首的金色前缀 (例如 "压缩中: "), 后面才是滚动的输出
  dirty = true,
}

-- UIBox 与文本节点
local view = {
  box = nil,
  attach = nil,
  age = 0,
  since_refresh = 0,
  hidden_for = 0,
  lang = nil,
  measure = nil, ---@type (fun(ch: string): number)?
  -- 每段一个 ref 表与颜色表, 颜色表是本模块自己的副本, 改它不会影响 G.C.
  slots = {},
}

for i = 1, MAX_PIECES do
  view.slots[i] = { ref = { text = "" }, colour = { 1, 1, 1, 1 } }
end

---@param kind string
---@return table
local function colour_of(kind)
  if kind == "reasoning" then
    return G.C.UI.TEXT_INACTIVE
  elseif kind == "error" then
    return G.C.RED
  elseif kind == "status" then
    return G.C.FILTER
  end
  return G.C.UI.TEXT_LIGHT
end

---@param options {toast: table}
function M.init(options)
  toast = options.toast
end

-- 模型输出可能是任何语言, 固定选带中日韩字形的字体.
local function ensure_lang()
  local lang = toast.pick_lang("中")
  if view.lang ~= lang then
    view.lang = lang
    view.measure = Text.cached(function(ch)
      return toast.text_width(lang, ch, TEXT_SCALE)
    end)
  end
end

---@return {kind: string, text: string}[]
local function compute_pieces()
  local max_width = LINE_WIDTH * FIT
  if state.mode == "stream" then
    local label = state.label
    if not label then
      return Text.tail(buffer.segments, max_width, view.measure, MAX_PIECES)
    end
    -- 前缀固定在行首, 占掉一段宽度和一个文本节点, 剩下的给滚动的输出.
    local label_width = 0
    for _, ch in ipairs(Text.utf8_chars(label)) do
      label_width = label_width + view.measure(ch)
    end
    local pieces = { { kind = "status", text = label } }
    for _, piece in ipairs(Text.tail(buffer.segments, math.max(0, max_width - label_width), view.measure, MAX_PIECES - 1)) do
      pieces[#pieces + 1] = piece
    end
    return pieces
  end
  local message = state.message
  if type(message) == "function" then
    local ok, value = pcall(message)
    message = ok and tostring(value) or ""
  end
  local kind = state.mode == "error" and "error" or "status"
  return { { kind = kind, text = Text.head(message or "", max_width, view.measure) } }
end

local function refresh()
  ensure_lang()
  local pieces = compute_pieces()
  for i, slot in ipairs(view.slots) do
    local piece = pieces[i]
    slot.ref.text = piece and piece.text or ""
    local c = colour_of(piece and piece.kind or "content")
    slot.colour[1], slot.colour[2], slot.colour[3], slot.colour[4] = c[1], c[2], c[3], c[4]
  end
  state.dirty = false
  view.since_refresh = 0
end

local function build_definition()
  local nodes = {}
  for i, slot in ipairs(view.slots) do
    nodes[i] = {
      n = G.UIT.T,
      config = { ref_table = slot.ref, ref_value = "text", scale = TEXT_SCALE, colour = slot.colour, shadow = true, lang = view.lang },
    }
  end
  -- 结构与 toast 相同: 外圈 TRANSPARENT_DARK, 内层黑底灰描边. 文字区宽度固定, 居中位置不随字数跳动.
  return {
    n = G.UIT.ROOT,
    config = { align = "cm", r = 0.1, padding = 0.06, colour = G.C.UI.TRANSPARENT_DARK },
    nodes = {
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.12, r = 0.1, colour = G.C.BLACK, outline = 1.5, outline_colour = G.C.GREY },
        nodes = {
          { n = G.UIT.R, config = { align = "cl", padding = 0, minw = LINE_WIDTH }, nodes = nodes },
        },
      },
    },
  }
end

local function remove_box()
  if view.box and not view.box.REMOVED then
    view.box:remove()
  end
  view.box, view.attach = nil, nil
end

local function create_box()
  refresh()
  view.box = UIBox({
    definition = build_definition(),
    config = {
      align = "tmi",
      offset = { x = 0, y = HIDDEN_Y },
      major = G.ROOM_ATTACH,
      bond = "Weak",
      instance_type = "POPUP",
      can_collide = false,
    },
  })
  view.box.bb_stream_bar = true
  view.attach = G.ROOM_ATTACH
  view.age = 0
  view.hidden_for = 0
end

local function show()
  state.showing = true
  state.dirty = true
end

--- 一次请求开始. 首个增量到达前不滑入; 上一段内容还在停留时保持显示, 等新内容到了再替换.
--- label 是固定在行首的前缀 (例如 "压缩中: "): 带 label 时立刻清空并滑入显示前缀, 输出接在后面滚动.
---@param label string?
function M.begin_request(label)
  state.request = true
  state.label = label
  if label then
    buffer:clear()
    state.fresh = false
    state.mode = "stream"
    state.message = nil
    state.hold = nil
    show()
  else
    state.fresh = true
  end
end

--- 推一段增量. kind: reasoning / content (error / status 也接受, 按对应颜色显示).
---@param kind string
---@param text string
function M.push(kind, text)
  if not Text.KINDS[kind] or type(text) ~= "string" or text == "" then
    return
  end
  if state.fresh then
    -- 不带前缀的新请求: 上一次 (例如压缩) 的前缀不再显示.
    state.label = nil
  end
  if state.fresh or state.mode ~= "stream" then
    -- 新请求的第一个增量, 或重试成功后恢复流式显示: 清掉旧内容与红字.
    if state.fresh then
      buffer:clear()
    end
    state.fresh = false
    state.mode = "stream"
    state.message = nil
  end
  state.request = true
  if buffer:append(kind, text) then
    state.hold = nil
    show()
  end
end

--- 流中断, 整个请求重发: 丢掉已收到的半截输出. 之后的增量重新开始显示.
function M.reset()
  buffer:clear()
  state.fresh = false
  state.dirty = true
  -- 带前缀的请求 (压缩) 重发时前缀照常显示, 不收起.
  if state.mode == "stream" and state.request and not state.label then
    -- 重发后的首个增量到达前没有可显示的内容, 收起.
    state.showing = false
  end
end

--- 请求结束: 停留 LINGER 秒后收起.
function M.finish()
  state.request = false
  state.fresh = false
  if state.showing and state.mode == "stream" then
    state.hold = LINGER
  end
end

--- 回放用: 把缓冲换成 segments 的前 chars 个字, 立刻显示.
--- 还没有字且没有前缀时不滑入, 和直播时等首个增量一样.
---@param segments {kind: string, text: string}[]?
---@param chars integer
---@param label string?
function M.reveal(segments, chars, label)
  buffer:clear()
  state.label = label
  state.fresh = false
  state.request = true
  state.mode = "stream"
  state.message = nil
  state.hold = nil
  local prefix = Text.prefix(segments, chars)
  local added = false
  for _, seg in ipairs(prefix) do
    if buffer:append(seg.kind, seg.text) then
      added = true
    end
  end
  if added or (type(label) == "string" and label ~= "") then
    show()
  else
    state.dirty = true
  end
end

--- 显示红字. text 可以是函数, 每次刷新重新求值 (倒计时).
--- hold_seconds 为 nil 时一直显示, 直到下一个增量, 下一次 show_* 或 clear.
---@param text string|fun(): string
---@param hold_seconds number?
function M.show_error(text, hold_seconds)
  state.mode = "error"
  state.message = text
  state.hold = hold_seconds
  show()
end

--- 显示金色状态文字, 例如 "已暂停 (F9 继续)". hold_seconds 默认 1.5 秒.
---@param text string|fun(): string
---@param hold_seconds number?
function M.show_status(text, hold_seconds)
  state.mode = "status"
  state.message = text
  state.hold = hold_seconds or STATUS_HOLD
  show()
end

--- 立即收起并清空.
function M.clear()
  buffer:clear()
  state.showing = false
  state.mode = "stream"
  state.message = nil
  state.hold = nil
  state.request = false
  state.fresh = false
  state.label = nil
  state.dirty = true
  remove_box()
end

--- 是否在屏幕上 (含滑出过程), 录制据此判断活动期.
---@return boolean
function M.active()
  return view.box ~= nil
end

--- 停留到期: 报错或状态文字到期后, 请求仍在进行且有内容时回到流式显示, 否则收起.
local function expire()
  state.hold = nil
  if state.mode ~= "stream" then
    state.mode = "stream"
    state.message = nil
    state.dirty = true
    if state.request and not buffer:is_empty() and not state.fresh then
      return
    end
  end
  state.showing = false
end

--- 每帧调用, 放在游戏 update 之后. dt 为墙钟间隔.
---@param dt number
function M.update(dt)
  if state.hold then
    state.hold = state.hold - dt
    if state.hold <= 0 then
      expire()
    end
  end
  if type(state.message) == "function" then
    state.dirty = true
  end

  -- 阶段切换重建了 ROOM_ATTACH, 旧的 UIBox 随之失效.
  if view.box and (view.box.REMOVED or view.attach ~= G.ROOM_ATTACH) then
    view.box, view.attach = nil, nil
  end

  if state.showing then
    if not view.box then
      if not G.ROOM_ATTACH or not toast then
        return
      end
      create_box()
    end
    view.age = view.age + dt
    view.hidden_for = 0
    view.since_refresh = view.since_refresh + dt
    if state.dirty and view.since_refresh >= REFRESH then
      refresh()
    end
    if view.age >= ENTER_DELAY then
      view.box.alignment.offset.y = SHOWN_Y
    end
  elseif view.box then
    view.box.alignment.offset.y = HIDDEN_Y
    view.hidden_for = view.hidden_for + dt
    if view.hidden_for >= LEAVE_TIME then
      remove_box()
    end
  end
end

return M
