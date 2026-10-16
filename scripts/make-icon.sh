#!/bin/bash
# 重新生成 Resources/AppIcon.icns（修改 make-icon.swift 后运行）
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swiftc -O scripts/make-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK" dark >/dev/null

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$WORK/icon_1024.png" docs/icon.png
echo "已生成 Resources/AppIcon.icns"
