#!/bin/bash
# 試してもらう人に渡す zip を作る。
#   ./dist.sh → dist/EdgeShelf-<版>.zip
# 中身は EdgeShelf.app と「はじめにお読みください.txt」。
# 署名は仮のもの（ad-hoc）なので、受け取った人は初回だけ macOS の警告を許可する必要がある（説明書に手順あり）。
set -euo pipefail
cd "$(dirname "$0")"

./build.sh   # 最新の状態でビルドする（~/Applications にも入る）

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)
STAGE=build/dist/EdgeShelf
ZIP=dist/EdgeShelf-$VERSION.zip

rm -rf build/dist
mkdir -p "$STAGE"
ditto build/EdgeShelf.app "$STAGE/EdgeShelf.app"
cp "dist/はじめにお読みください.txt" "$STAGE/"

# zip コマンドは署名を壊すことがあるので ditto で固める
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE" "$ZIP"

open ~/Applications/EdgeShelf.app   # build.sh で止めたアプリを起動し直す
echo "作成: $ZIP"
