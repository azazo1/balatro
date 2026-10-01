-- 手册查询纯逻辑的单元测试, 用仓库里的 docs/game 作为数据, 用 luajit 在仓库根目录运行: just test-agent
local Docs = dofile("mods/balatrobot/agent/knowledge/docs.lua")
local Catalog = dofile("mods/balatrobot/agent/knowledge/catalog.lua")
local json = dofile("mods/Steamodded/libs/json/json.lua")

local ROOT = "docs/game/"

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
  end
end

local function read(rel)
  local fh = io.open(ROOT .. rel, "rb")
  if not fh then
    return nil
  end
  local data = fh:read("*a")
  fh:close()
  return data
end

-- ls -p: 子目录名以 "/" 结尾, 与游戏内 list 的约定一致
local function list(rel)
  local fh = io.popen("ls -p '" .. ROOT .. rel .. "'")
  local out = {}
  for name in fh:lines() do
    out[#out + 1] = name
  end
  fh:close()
  return out
end

local docs = Docs.new({ read = read, list = list })

local function lines_of(rel)
  return Docs.split_lines(read(rel))
end

do -- 路径校验: 只接受手册根目录下的相对路径
  check("拒绝 ..", Docs.normalize("cards/../../game/game.lua") == nil and Docs.normalize("..") == nil)
  check("拒绝绝对路径", Docs.normalize("/etc/passwd") == nil and Docs.normalize("C:/x.md") == nil
    and Docs.normalize("\\cards\\jokers.md") == nil)
  check("反斜杠转斜杠, 去掉 ./", Docs.normalize(".\\cards\\jokers.md") == "cards/jokers.md")
  local result = docs:read({ path = "../README.md" })
  check("读取时拒绝 ..", result == nil)
  check("不在手册里的文件不可读", docs:read({ path = "data/catalog.json" }) == nil)
end

do -- 按锚点切章节: 从标题到下一个同级标题之前, 不含下一节的锚点
  local raw = lines_of("cards/jokers.md")
  local anchor_line
  for i, line in ipairs(raw) do
    if line:find('<a id="j-blueprint">', 1, true) then
      anchor_line = i
    end
  end
  local r = docs:read({ path = "cards/jokers.md", section = "j-blueprint" })
  check("锚点命中蓝图一节", r and r.section and r.section.title:find("Blueprint", 1, true), r and r.section and r.section.title)
  if r then
    local first = r.content:match("^[^\n]*")
    local last = r.content:match("[^\n]*$")
    check("章节从锚点后的标题开始", r.start_line > anchor_line and first:find("### ", 1, true), first)
    check("章节不含下一节", not r.content:find("j-wee", 1, true) and not r.content:find("小小丑", 1, true), last)
    check("章节含本节内容", r.content:find("`j_blueprint`", 1, true) ~= nil)
    check("章节不需要翻页", r.next_offset == nil)
  end
  local same = docs:read({ path = "cards/jokers.md#j-blueprint" })
  check("path 带 #锚点 等同 section", same and r and same.start_line == r.start_line)
  -- 文档内的链接用 GitHub 风格的标题 slug
  local slug = docs:read({ path = "rules/blinds.md#ante-1-8-基础分表" })
  check("标题 slug 命中", slug and slug.section ~= nil, slug == nil and "not found")
end

do -- 分页: 按 next_offset 连续读完, 不重不漏
  for _, rel in ipairs({ "cards/jokers.md", "cards/challenges.md", "rules/scoring.md" }) do
    local raw = lines_of(rel)
    local offset, expect, ok, calls = 1, 1, true, 0
    local detail
    while offset do
      local r = docs:read({ path = rel, offset = offset })
      calls = calls + 1
      if not r or r.start_line ~= offset or #r.content > Docs.MAX_BYTES then
        ok, detail = false, "bad page at " .. offset
        break
      end
      for n in (r.content .. "\n"):gmatch("(%d+): [^\n]*\n") do
        if tonumber(n) ~= expect then
          ok, detail = false, "expected line " .. expect .. " got " .. n
          break
        end
        expect = expect + 1
      end
      if not ok then
        break
      end
      offset = r.next_offset
    end
    check("分页读完 " .. rel, ok and expect == #raw + 1, detail or (expect - 1) .. "/" .. #raw .. " lines")
    if rel == "cards/jokers.md" then
      check("大文件分多页", calls > 1)
    end
  end
  local r = docs:read({ path = "rules/scoring.md", offset = 10, limit = 5 })
  check("limit 限制行数", r and r.start_line == 10 and r.end_line == 14 and r.next_offset == 15)
end

do -- 大文件默认只返回大纲
  local r = docs:read({ path = "cards/jokers.md" })
  check("大文件只返回大纲", r and r.outline ~= nil and r.content == nil)
  check("大纲带锚点", r and r.outline:find("{#j-blueprint}", 1, true) ~= nil)
  local small = docs:read({ path = "rules/scoring.md" })
  check("小文件直接返回内容", small and small.outline == nil and small.content ~= nil)
end

do -- 搜索: 限定 path 与截断
  local all = docs:search({ query = "BLUEPRINT" })
  check("搜索不区分大小写", all and all.total > 0)
  local scoped = docs:search({ query = "j_blueprint", path = "mechanics" })
  local only = scoped ~= nil and #scoped.matches > 0
  for _, m in ipairs(scoped and scoped.matches or {}) do
    only = only and m:sub(1, #"mechanics/") == "mechanics/"
  end
  check("限定目录", only)
  local file = docs:search({ query = "j_blueprint", path = "mechanics/joker-mechanics.md" })
  check("限定文件, 格式 路径:行号: 内容",
    file and file.matches[1] and file.matches[1]:match("^mechanics/joker%-mechanics%.md:%d+: ") ~= nil)
  local cut = docs:search({ query = "j_", limit = 3 })
  check("超出 limit 时截断", cut and #cut.matches == 3 and cut.truncated and cut.total > 3)
  check("不存在的目录报错", docs:search({ query = "x", path = "nope" }) == nil)
end

do -- 链接改写
  local files = { ["README.md"] = true, ["rules/scoring.md"] = true, ["mechanics/joker-mechanics.md"] = true }
  local line = "[a](<../rules/scoring.md#2-x>) [b](<../../../game/game.lua#L498>) [c](../mechanics/joker-mechanics.md)"
    .. " [d](<../sources.md>) [e](#j-joker) [f](<https://example.com>)"
  local out = Docs.rewrite_links(line, "cards/jokers.md", files)
  check("手册内改成相对根目录", out:find("[a](<rules/scoring.md#2-x>)", 1, true) ~= nil, out)
  check("无尖括号的链接也改写", out:find("[c](<mechanics/joker-mechanics.md>)", 1, true) ~= nil, out)
  check("手册外变纯文本", out:find("b (game/game.lua#L498)", 1, true) ~= nil and not out:find("%[b%]"), out)
  check("未打包的文档变纯文本", out:find("d (docs/game/sources.md)", 1, true) ~= nil, out)
  check("本文件锚点带上路径", out:find("[e](<cards/jokers.md#j-joker>)", 1, true) ~= nil, out)
  check("网页链接保留", out:find("[f](<https://example.com>)", 1, true) ~= nil, out)
  -- 实际文件: 读出的内容里不再有 ../ 链接
  local r = docs:read({ path = "cards/jokers.md", section = "j-blueprint" })
  check("读出的内容已改写", r and not r.content:find("](<../", 1, true)
    and r.content:find("(game/game.lua#L498)", 1, true) ~= nil, r and r.content)
end

do -- catalog lookup
  local catalog = Catalog.new({ read = read, decode = json.decode, docs = docs })
  local r = catalog:lookup({ "j_blueprint", "蓝图", "blueprint", "Blueprint", "zzz_nothing", "蓝" })
  local ok = r ~= nil
  for i = 1, 4 do
    local card = r and r.results[i].cards[1]
    ok = ok and card ~= nil and card.id == "j_blueprint" and #r.results[i].cards == 1
  end
  check("id, 中文名, 英文名都能找到 j_blueprint", ok)
  local card = r and r.results[1].cards[1]
  check("精简记录字段", card and card.rarity == "稀有" and card.base_cost == 10 and card.blueprint_compat == true
    and type(card.effect_zh) == "string" and card.doc == "cards/jokers.md#j-blueprint")
  local mech = card and card.mechanics or {}
  local mech_ok = #mech > 0 and #mech <= Catalog.MECHANICS_MAX
  for _, m in ipairs(mech) do
    mech_ok = mech_ok and m:match("^mechanics/[^:]+:%d+: ") ~= nil and m:find("j_blueprint", 1, true) ~= nil
  end
  check("带出 mechanics 行", mech_ok)
  local miss = r and r.results[5]
  check("找不到时 cards 为空", miss and #miss.cards == 0)
  local near = r and r.results[6]
  local has = false
  for _, c in ipairs(near and near.candidates or {}) do
    has = has or c:find("j_blueprint", 1, true) ~= nil
  end
  check("找不到时给出候选", near and #near.cards == 0 and has)
  -- 标识符边界: j_joker 不应命中 j_jokerxxx 之类的更长 id
  local joker = catalog:lookup({ "j_joker" })
  local bound = true
  for _, m in ipairs(joker.results[1].cards[1].mechanics) do
    local s, e = m:find("j_joker", 1, true)
    bound = bound and not m:sub(e + 1, e + 1):match("[%w_]")
  end
  check("机制行按完整 id 匹配", bound)
end

if failures > 0 then
  print(failures .. " 项失败")
  os.exit(1)
end
print("全部通过")
