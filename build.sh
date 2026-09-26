#!/bin/bash
# EdgeShelf.app（macOS 13 以降、Apple シリコンと Intel の両対応）をビルドし、~/Applications に入れる。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

# 署名：この Mac に Apple Development の証明書があれば、それで署名する（ビルドし直しても、システム設定で許可した内容が外れない）。
# なければ仮の署名（ad-hoc）にする。証明書には本名が入るので、配る zip は dist.sh で ad-hoc に署名し直す
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/ && !f {print $2; f=1}' || true)
sign() { if [ -n "$SIGN_ID" ]; then codesign --force --timestamp=none --sign "$SIGN_ID" "$@"; else codesign --force --sign - "$@"; fi; }

APP=build/EdgeShelf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/"
cp -R app/ja.lproj app/en.lproj "$APP/Contents/Resources/"   # 日本語・英語の文字列（Mac の言語設定で自動で切り替わる）
# macOS 13 以降で動く、Apple シリコンと Intel の両方に対応したユニバーサル形式にする
MIN_OS=13.0
for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos$MIN_OS" -o "build/EdgeShelf-$ARCH" app/Model.swift app/Shelf.swift app/main.swift
done
lipo -create -output "$APP/Contents/MacOS/EdgeShelf" build/EdgeShelf-arm64 build/EdgeShelf-x86_64
sign "$APP"

mkdir -p ~/Applications
pkill -x EdgeShelf 2>/dev/null && sleep 1 || true
rm -rf ~/Applications/EdgeShelf.app
cp -R "$APP" ~/Applications/
echo "built: ~/Applications/EdgeShelf.app"
