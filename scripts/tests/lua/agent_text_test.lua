-- UTF-8 安全截断 (mods/balatrobot/agent/text.lua) 的单元测试, 用 luajit 在仓库根目录运行: just test-agent
local Text = dofile("mods/balatrobot/agent/text.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

-- 每个字符的字节数: 中(3) ascii(1) 中(3) 文(3) 😀(4) 结(3) 尾(3)
local SAMPLE = "中a文😀结尾"

---@param text string
---@return string
local function escaped(text)
  return (text:gsub("[^\128-\191]", function(c)
    return string.format("[%02x]", c:byte())
  end))
end

do -- 截断: 任何字节上限都要落在字符边界上, 且不超过上限
  local bad = {}
  for limit = 0, #SAMPLE + 4 do
    local cut = Text.cut(SAMPLE, limit)
    local ok, at = Text.valid_utf8(cut)
    if not ok then
      bad[#bad + 1] = string.format("limit=%d 非法(第 %d 字节) %s", limit, at, escaped(cut))
    elseif #cut > limit then
      bad[#bad + 1] = string.format("limit=%d 切出 %d 字节", limit, #cut)
    elseif #cut > 0 and cut ~= SAMPLE:sub(1, #cut) then
      bad[#bad + 1] = string.format("limit=%d 不是前缀 %s", limit, escaped(cut))
    end
  end
  check("所有字节上限都切在字符边界上", #bad == 0, table.concat(bad, "; "))
end

do -- 截断: 具体到几个位置
  check("够长时原样返回", Text.cut(SAMPLE, #SAMPLE) == SAMPLE)
  check("上限超过长度也原样返回", Text.cut(SAMPLE, 999) == SAMPLE)
  check("上限 0 给空串", Text.cut(SAMPLE, 0) == "")
  check("负数上限给空串", Text.cut(SAMPLE, -5) == "")
  check("切到汉字中间时整个汉字不要", Text.cut("中文", 4) == "中", escaped(Text.cut("中文", 4)))
  check("切到 emoji 中间时整个 emoji 不要", Text.cut(SAMPLE, 8) == "中a文", escaped(Text.cut(SAMPLE, 8)))
  check("纯 ASCII 按字节切", Text.cut("abcdef", 3) == "abc")
  check("nil 与数字也接受", Text.cut(nil, 3) == "" and Text.cut(12345, 2) == "12")
end

do -- 校验: 换行与各种长度都不误判
  check("空串合法", Text.valid_utf8("") == true)
  check("ASCII 合法", Text.valid_utf8("hello\n") == true)
  check("中文合法", Text.valid_utf8("中文\n多行") == true)
  check("emoji 合法", Text.valid_utf8("😀") == true)
  local ok, at = Text.valid_utf8("中a" .. string.char(0xE6))
  check("截断的汉字被认出", not ok and at == 5, tostring(at))
  check("孤立续字节被认出", not Text.valid_utf8(string.char(0x80)))
  check("0xC0/0xC1 这类过长编码被认出", not Text.valid_utf8(string.char(0xC0, 0x80)) and not Text.valid_utf8(string.char(0xC1, 0x80)))
  check("超过 U+10FFFF 的首字节被认出", not Text.valid_utf8(string.char(0xF5, 0x80, 0x80, 0x80)))
end

do -- 修复: 非法字节换成 U+FFFD, 合法文本原样返回
  local valid = "中文abc"
  check("合法的原样返回", Text.sanitize_utf8(valid) == valid)
  local lonely = string.char(0x80) .. "a"
  local fixed = Text.sanitize_utf8(lonely)
  check("孤立字节换成替换字符", fixed == "\239\191\189a", escaped(fixed))
  check("修完是合法的", Text.valid_utf8(fixed) == true)
  -- "中" 后面接了半个汉字的首字节
  local broken = "中" .. string.char(0xE6) .. "文"
  local fixed2 = Text.sanitize_utf8(broken)
  check("半个汉字换成替换字符, 其余保留", fixed2 == "中\239\191\189文", escaped(fixed2))
  check("修完仍是合法的", Text.valid_utf8(fixed2) == true)
end

do -- 真实事故的形状: 手册结果按 6000 字节裸切时切断汉字, 修复后排出去的内容仍合法
  -- 每 7 字节一个循环 (中=3, 文=3, a=1), 6000 落在 857 个循环之后的第一字节, 正好切进汉字中间
  local big = string.rep("中文a", 1000)
  local raw = big:sub(1, 6000)
  check("裸截断确实会切断汉字", not Text.valid_utf8(raw))
  local cut = Text.cut(big, 6000)
  check("截断后合法且不超上限", Text.valid_utf8(cut) == true and #cut <= 6000, tostring(#cut))
  check("截断结果是被切掉一个汉字的完整前缀", cut == big:sub(1, 5999), tostring(#cut))
end

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("all passed")
