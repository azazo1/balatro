#!/usr/bin/env bash
#
# 把 game/ 中的游戏资源装进官方 LÖVE 11.5 Android 运行时, 用本地密钥签名, 产出可安装的 APK.
#
# 这条流程不编译任何原生代码: 运行时 (liblove.so) 直接用官方发行包里的, 只替换游戏负载,
# 改写 AndroidManifest 并重新签名. 因此不需要 NDK, 也不需要 gradle.
#
# 产物: dist/Balatro-<版本>.apk
#
# 用法:
#   scripts/package-android.sh                          自动生成/复用本地密钥
#   scripts/package-android.sh --keystore 我的.jks     指定密钥
#   scripts/package-android.sh --package com.foo.bar   覆盖包名
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_DIR="$ROOT_DIR/game"
ICON_SRC="$ROOT_DIR/assets/icon.png"
VENDOR_APK="$ROOT_DIR/vendor/love-11.5-android-embed.apk"
VENDOR_SHA256="dcf71c1b54c5b5a09598ef1e6cf4852ced5e5e612de3d0f30cfdd39b5014e889"
LOVE_VERSION="11.5"
GAME_VERSION="$(head -1 "$ROOT_DIR/game/version.jkr" 2>/dev/null | sed 's/-FULL$//' || echo "unknown")"
BUNDLE_VERSION="1.0.1n"
VERSION_CODE="101"
APP_NAME="Balatro"
PACKAGE_NAME="com.azazo1.balatro"
OUT_DIR="$ROOT_DIR/dist"
ASSET_NAME="game.love"

KEYSTORE=""
KEYSTORE_PASS="${BALATRO_KEYSTORE_PASS:-balatro}"

log() { printf '[package-android] %s\n' "$*" >&2; }
die() { printf '[package-android] 错误: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --keystore) [ $# -ge 2 ] || die "--keystore 后面需要路径"; KEYSTORE="$2"; shift 2 ;;
        --package)  [ $# -ge 2 ] || die "--package 后面需要包名";  PACKAGE_NAME="$2"; shift 2 ;;
        -h|--help)  sed -n '2,16p' "${BASH_SOURCE[0]}" >&2; exit 0 ;;
        *) die "无法识别的参数: $1" ;;
    esac
done

# 包名在 AndroidManifest 里以 UTF-16 存储, 字符串池重建不受长度限制, 但仍建议保持简短.
case "$PACKAGE_NAME" in
    *[!a-zA-Z0-9._]*) die "包名只能含字母, 数字, 点与下划线: $PACKAGE_NAME" ;;
esac
[ -f "$GAME_DIR/main.lua" ] || die "缺少 game/main.lua"
[ -f "$VENDOR_APK" ] || die "缺少官方运行时: $VENDOR_APK"
[ -f "$ICON_SRC" ] || die "缺少图标源图: $ICON_SRC"

# 定位 Android SDK 的 build-tools.
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[ -d "$SDK_ROOT" ] || die "找不到 Android SDK: $SDK_ROOT (可用 ANDROID_HOME 指定)"
BUILD_TOOLS="$(find "$SDK_ROOT/build-tools" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)"
[ -n "$BUILD_TOOLS" ] || die "SDK 里没有 build-tools, 可用 sdkmanager 安装"
command -v zipalign >/dev/null 2>&1 && ZIPALIGN="$(command -v zipalign)" || ZIPALIGN="$BUILD_TOOLS/zipalign"
[ -x "$ZIPALIGN" ] || ZIPALIGN="$BUILD_TOOLS/zipalign"
[ -x "$ZIPALIGN" ] || die "找不到 zipalign"
[ -x "$BUILD_TOOLS/apksigner" ] || die "找不到 apksigner (在 $BUILD_TOOLS)"
log "使用 build-tools: $(basename "$BUILD_TOOLS")"

log "校验 LÖVE $LOVE_VERSION Android 运行时"
actual_sha="$(shasum -a 256 "$VENDOR_APK" | awk '{print $1}')"
[ "$actual_sha" = "$VENDOR_SHA256" ] || die "运行时哈希不符: 期望 $VENDOR_SHA256, 实际 $actual_sha"

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d "$OUT_DIR/.android.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

log "打包游戏资源为 $ASSET_NAME"
( cd "$GAME_DIR" && zip -q -X -9 -r "$WORK_DIR/$ASSET_NAME" . )
unzip -l "$WORK_DIR/$ASSET_NAME" > "$WORK_DIR/listing.txt"
for required in main.lua conf.lua; do
    grep -q " $required\$" "$WORK_DIR/listing.txt" || die "归档根部缺少 $required"
done

log "改写 AndroidManifest"
cat > "$WORK_DIR/rules.json" <<EOF
{
  "strings": {
    "org.love2d.android": "$PACKAGE_NAME",
    "org.love2d.android.androidx-startup": "$PACKAGE_NAME.androidx-startup",
    "LÖVE for Android": "$APP_NAME",
    "11.5a": "$BUNDLE_VERSION"
  },
  "ints": {
    "screenOrientation": 5,
    "versionCode": $VERSION_CODE
  }
}
EOF
python3 "$ROOT_DIR/scripts/patch-manifest.py" \
    "$VENDOR_APK" "$WORK_DIR/base.apk" "$WORK_DIR/rules.json"

log "生成各密度图标"
STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE/assets"
cp "$WORK_DIR/$ASSET_NAME" "$STAGE/assets/$ASSET_NAME"
for pair in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    density="${pair%%:*}"
    size="${pair##*:}"
    dir="$STAGE/res/drawable-${density}-v4"
    mkdir -p "$dir"
    sips -z "$size" "$size" "$ICON_SRC" --out "$dir/love.png" >/dev/null
done

log "组装 APK"
cp "$WORK_DIR/base.apk" "$WORK_DIR/out.apk"
( cd "$STAGE" && zip -q -X -0 "$WORK_DIR/out.apk" "assets/$ASSET_NAME" )
( cd "$STAGE" && zip -q -X "$WORK_DIR/out.apk" \
    res/drawable-mdpi-v4/love.png res/drawable-hdpi-v4/love.png \
    res/drawable-xhdpi-v4/love.png res/drawable-xxhdpi-v4/love.png \
    res/drawable-xxxhdpi-v4/love.png )

log "对齐"
"$ZIPALIGN" -f -p 4 "$WORK_DIR/out.apk" "$WORK_DIR/aligned.apk"

if [ -z "$KEYSTORE" ]; then
    KEYSTORE="$OUT_DIR/balatro-local.keystore"
fi
if [ ! -f "$KEYSTORE" ]; then
    log "生成新密钥: $(basename "$KEYSTORE")"
    KEYTOOL="$(command -v keytool || true)"
    for cand in /opt/homebrew/opt/openjdk@17/bin/keytool /usr/local/opt/openjdk@17/bin/keytool; do
        [ -n "$KEYTOOL" ] && break
        [ -x "$cand" ] && KEYTOOL="$cand"
    done
    [ -n "$KEYTOOL" ] || die "找不到 keytool, 需要 JDK"
    "$KEYTOOL" -genkeypair -v -keystore "$KEYSTORE" -alias balatro \
        -keyalg RSA -keysize 2048 -validity 10000 -storetype PKCS12 \
        -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
        -dname "CN=$APP_NAME Local Build, OU=Personal, O=Personal, C=CN" 2>&1 \
        | grep -vE '^WARNING|^$' || true
    log "已生成密钥, 请妥善保存: 换密钥后无法覆盖安装, 只能卸载重装"
fi

APK_OUT="$OUT_DIR/$APP_NAME-$BUNDLE_VERSION.apk"
log "签名"
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" \
    --ks-pass "pass:$KEYSTORE_PASS" --key-pass "pass:$KEYSTORE_PASS" \
    --ks-key-alias balatro --v1-signing-enabled true --v2-signing-enabled true \
    --v4-signing-enabled false \
    --out "$APK_OUT" "$WORK_DIR/aligned.apk" 2>&1 | grep -vE '^WARNING|^$' || true

log "校验签名"
# 成功时 apksigner 不向 stdout 输出内容, 所以不能把它的输出接进 grep:
# 空输出会让 grep 返回 1, 在 pipefail 下被误判成校验失败.
if ! "$BUILD_TOOLS/apksigner" verify -v --print-certs "$APK_OUT" > "$WORK_DIR/verify.log" 2>&1; then
    sed -n '1,40p' "$WORK_DIR/verify.log" >&2
    die "签名校验失败"
fi
grep -E '^Verified using|^Signer #1 certificate DN' "$WORK_DIR/verify.log" >&2 || true
"$ZIPALIGN" -c 4 "$APK_OUT" || die "对齐校验失败"

apk_size="$(du -h "$APK_OUT" | awk '{print $1}')"
log "完成: $APK_OUT ($apk_size)"
log "安装: adb install -r \"$APK_OUT\""
