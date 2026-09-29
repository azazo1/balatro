#!/usr/bin/env bash
#
# 把 game/ 里的 Balatro 资源与 vendor/ 里的 LÖVE 运行时组装成 macOS 应用包.
#
# 产物: dist/Balatro.app
#
# 用法:
#   scripts/package-macos.sh                  沿用 LÖVE 自带图标
#   scripts/package-macos.sh --icon logo.png  用给定 png 生成应用图标
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="$ROOT_DIR/game"
VENDOR_ZIP="$ROOT_DIR/vendor/love-11.5-macos.zip"
VENDOR_SHA256="6795bb3a1656af6a2fdfe741e150787b481886d3a280327a261a3fdded586913"
LOVE_VERSION="11.5"
GAME_VERSION="1.0.1n"
BUNDLE_VERSION="1.0.1"
APP_NAME="Balatro"
BUNDLE_ID="local.balatro"
OUT_DIR="$ROOT_DIR/dist"

ICON_SRC=""

log() { printf '[package-macos] %s\n' "$*" >&2; }
die() { printf '[package-macos] 错误: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --icon)
            [ $# -ge 2 ] || die "--icon 后面需要一个 png 路径"
            ICON_SRC="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" >&2
            exit 0
            ;;
        *)
            die "无法识别的参数: $1"
            ;;
    esac
done

[ -f "$GAME_DIR/main.lua" ] || die "缺少 game/main.lua, game/ 不是可用的游戏资源目录"
[ -f "$VENDOR_ZIP" ] || die "缺少 LÖVE 运行时: $VENDOR_ZIP"

log "校验 LÖVE $LOVE_VERSION 运行时"
actual_sha="$(shasum -a 256 "$VENDOR_ZIP" | awk '{print $1}')"
[ "$actual_sha" = "$VENDOR_SHA256" ] || die "运行时哈希不符: 期望 $VENDOR_SHA256, 实际 $actual_sha"

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d "$OUT_DIR/.work.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

log "展开运行时"
unzip -q "$VENDOR_ZIP" -d "$WORK_DIR"
[ -d "$WORK_DIR/love.app" ] || die "运行时压缩包结构异常, 未找到 love.app"

APP_DIR="$OUT_DIR/$APP_NAME.app"
log "组装应用包 $(basename "$APP_DIR")"
rm -rf "$APP_DIR"
cp -R "$WORK_DIR/love.app" "$APP_DIR"

# 游戏资源打成一个 .love 归档, LÖVE 在 macOS 上会从 Contents/Resources 找到它并
# 以伪融合模式启动. 归档去掉扩展名后就是存档目录名, 所以这里直接用 $APP_NAME.
LOVE_FILE="$APP_DIR/Contents/Resources/$APP_NAME.love"
log "打包游戏资源为 $(basename "$LOVE_FILE")"
rm -f "$LOVE_FILE"
( cd "$GAME_DIR" && zip -q -X -9 -r "$LOVE_FILE" . )
# 归档清单先落盘再匹配: 直接把 unzip 的输出管道给 grep -q, grep 提前退出会让 unzip
# 收到 SIGPIPE, 在 pipefail 下被误判成打包失败.
unzip -l "$LOVE_FILE" > "$WORK_DIR/love-listing.txt"
for required in main.lua conf.lua; do
    grep -q " $required\$" "$WORK_DIR/love-listing.txt" \
        || die ".love 归档根部缺少 $required"
done

PLIST="$APP_DIR/Contents/Info.plist"
set_plist() {
    local key="$1" value="$2"
    if plutil -extract "$key" raw "$PLIST" >/dev/null 2>&1; then
        plutil -replace "$key" -string "$value" "$PLIST"
    else
        plutil -insert "$key" -string "$value" "$PLIST"
    fi
}

log "改写 Info.plist"
set_plist CFBundleName "$APP_NAME"
set_plist CFBundleDisplayName "$APP_NAME"
set_plist CFBundleIdentifier "$BUNDLE_ID"
set_plist CFBundleShortVersionString "$BUNDLE_VERSION"
set_plist CFBundleVersion "$BUNDLE_VERSION"
set_plist CFBundleGetInfoString "$APP_NAME $GAME_VERSION (LÖVE $LOVE_VERSION)"

if [ -n "$ICON_SRC" ]; then
    [ -f "$ICON_SRC" ] || die "找不到图标文件: $ICON_SRC"
    log "生成应用图标"
    ICONSET="$WORK_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        double=$((size * 2))
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    set_plist CFBundleIconFile "AppIcon"
    # 去掉 LÖVE 的图标资源, 否则 Info.plist 里的命名图标与 Assets.car 会优先于新的 .icns.
    plutil -remove CFBundleIconName "$PLIST" >/dev/null 2>&1 || true
    rm -f "$APP_DIR/Contents/Resources/Assets.car" \
          "$APP_DIR/Contents/Resources/OS X AppIcon.icns" \
          "$APP_DIR/Contents/Resources/GameIcon.icns"
fi

log "清除隔离属性"
xattr -cr "$APP_DIR"

log "ad-hoc 签名"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || die "签名失败"
codesign --verify --deep --strict "$APP_DIR" || die "签名校验失败"

app_size="$(du -sh "$APP_DIR" | awk '{print $1}')"
log "完成: $APP_DIR ($app_size)"
log "在资源管理器中打开: open \"$APP_DIR\""
