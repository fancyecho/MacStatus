#!/bin/bash
# 构建 Status.app 到 build/ 目录。用法：./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Status.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Status "$APP/Contents/MacOS/Status"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "已构建: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Status 2>/dev/null || true
    rm -rf /Applications/Status.app
    cp -R "$APP" /Applications/
    open /Applications/Status.app
    echo "已安装到 /Applications 并启动"
fi
