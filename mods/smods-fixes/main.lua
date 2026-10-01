-- 本仓库的修复 mod: 修复 Steamodded 自身的问题, 与游戏版本无关. 改游戏源码的修复在 lovely/ 下的补丁里,
-- 运行时就能修的放在这里.

-- 原版 create_toggle 与 create_option_cycle 用 ipairs(args.info) 逐行画说明文字, 要求是字符串数组.
-- Steamodded 的部分翻译把说明写成了单个字符串 (例如 zh_CN 的 b_vanilla_run_select_info), 中文下打开
-- Steamodded 的配置页会因 "bad argument #1 to 'ipairs'" 崩溃. 这里把字符串包成一行的数组再交给原函数.
for _, name in ipairs({ "create_toggle", "create_option_cycle" }) do
  local original = _G[name]
  if type(original) == "function" then
    _G[name] = function(args)
      if type(args) == "table" and type(args.info) == "string" then
        args.info = { args.info }
      end
      return original(args)
    end
  end
end
