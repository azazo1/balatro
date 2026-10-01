-- 本仓库的界面 mod: 让 Steamodded 在不新增内容时沿用原版的大块界面.
--
-- Steamodded 默认把 "开始游戏" 的选牌组界面换成分页式 (galdur), 把 Run Info 的 Stake 页换成
-- 自己的样式, 两者都有自带开关. 这里只在运行时打开开关, 不写入 Steamodded 的配置文件.
-- 装了新增开局页的 mod 时, Steamodded 会忽略 vanilla_run_select, 自动回到 galdur.
SMODS.config.vanilla_run_select = true
SMODS.config.vanilla_stake = true

-- Steamodded 的 lovely/mobile_patches.toml 在 Android/iOS 上把 F_QUIT_BUTTON 关掉, 主菜单因此没有
-- "退出". 原版 Android 包是有这个按钮的, 这里恢复. mod 在 start_up 里加载, 早于主菜单的建立, 所以
-- 改标志即可生效.
G.F_QUIT_BUTTON = true
