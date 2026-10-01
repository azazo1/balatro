_RELEASE_MODE = true
_DEMO = false

function love.conf(t)
	t.console = not _RELEASE_MODE
	t.title = 'Balatro'
	--|Android 上把存档放到外置存储, 便于备份. 存档名取自 assets/game.love, 即 game:
	--|  开启 -> /storage/emulated/0/Android/data/com.azazo1.balatro/files/save/game
	--|  关闭 -> /data/user/0/com.azazo1.balatro/files/save/game (无 root 不可访问)
	--|该开关只对 Android 生效, 其它平台会忽略.
	t.externalstorage = true
	t.window.width = 0
    t.window.height = 0
	t.window.minwidth = 100
	t.window.minheight = 100
end 

--|Android: PhysicsFS 建的存档目录与文件只有属主权限, 文件管理器看不到内容, 见 android_storage.lua.
do
	local ok, err = pcall(function() require("android_storage").install() end)
	if not ok then print("[android_storage] install failed: " .. tostring(err)) end
end
