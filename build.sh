#!/bin/bash
# 构建 Status.app（Apple 芯片 + Intel 通用二进制）到 build/ 目录。
# 用法：./build.sh            只构建
#       ./build.sh --install  构建并安装到 /Applications
#       ./build.sh --dmg      构建并打包成 build/Status-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Status"

APP="build/Status.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Status"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "已构建: $APP ($(lipo -archs "$APP/Contents/MacOS/Status"))"

case "${1:-}" in
--install)
    pkill -x Status 2>/dev/null || true
    rm -rf /Applications/Status.app
    cp -R "$APP" /Applications/
    open /Applications/Status.app
    echo "已安装到 /Applications 并启动"
    ;;
--dmg)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
    DMG="build/Status-$VERSION.dmg"
    STAGE="build/dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Status" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "已打包: $DMG"
    ;;
esac
