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

-- 模组配置必须写进 LÖVE 存档目录, 不能跟 nativefs 的进程 cwd.
-- Steamodded 用 NFS.write("config/<id>.jkr"), 相对路径落在 cwd 上. 打包后:
-- - macOS 从 Finder 打开时 cwd 常是 "/", mkdir config 失败被 pcall 吃掉, 看起来像没保存;
-- - 从终端打开或 LÖVE fused 时 cwd 常是 .app/Contents/Resources, 设置写进包内, 下次 dist 被覆盖;
-- - Windows cwd 是 exe 所在目录, 每次 dist 换文件夹, 设置跟着丢.
-- 保存改走 love.filesystem (一定写到 identity 对应的存档目录); 读取前把 cwd 拨回去,
-- 让 Steamodded 原有的 NFS.read("config/<id>.jkr") 仍能找到文件.
do
  local orig_load = SMODS.load_mod_config

  local function restore_save_dir()
    local dir = love.filesystem.getSaveDirectory()
    if type(dir) == "string" and dir ~= "" and NFS and NFS.setWorkingDirectory then
      NFS.setWorkingDirectory(dir)
    end
  end

  function SMODS.save_mod_config(mod)
    local success = pcall(function()
      assert(mod.config and next(mod.config))
      assert(love.filesystem.createDirectory("config"))
      local serialized = "return " .. serialize(mod.config)
      local written, err = love.filesystem.write(("config/%s.jkr"):format(mod.id), serialized)
      assert(written, err)
    end)
    return success
  end

  function SMODS.load_mod_config(mod)
    restore_save_dir()
    return orig_load(mod)
  end
end
