#!/bin/bash
# EdgeShelf.app（macOS 13 以降、Apple シリコンと Intel の両対応）をビルドし、~/Applications に入れる。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

APP=build/EdgeShelf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/"
# macOS 13 以降で動く、Apple シリコンと Intel の両方に対応したユニバーサル形式にする
MIN_OS=13.0
for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos$MIN_OS" -o "build/EdgeShelf-$ARCH" app/Model.swift app/Shelf.swift app/main.swift
done
lipo -create -output "$APP/Contents/MacOS/EdgeShelf" build/EdgeShelf-arm64 build/EdgeShelf-x86_64
codesign --force --sign - "$APP"

mkdir -p ~/Applications
pkill -x EdgeShelf 2>/dev/null && sleep 1 || true
rm -rf ~/Applications/EdgeShelf.app
cp -R "$APP" ~/Applications/
echo "built: ~/Applications/EdgeShelf.app"
