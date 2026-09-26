#!/bin/bash
# 試してもらう人に渡す zip を作る。
#   ./dist.sh → dist/EdgeShelf-<版>-ja.zip（説明書：はじめにお読みください.txt）
#               dist/EdgeShelf-<版>-en.zip（説明書：ReadMe.txt）
# アプリはどちらも同じもの（日本語・英語入り。Mac の言語設定で自動で切り替わる）。
# 署名は仮のもの（ad-hoc）なので、受け取った人は初回だけ macOS の警告を許可する必要がある（説明書に手順あり）。
set -euo pipefail
cd "$(dirname "$0")"

./build.sh   # 最新の状態でビルドする（~/Applications にも入る）

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)

# 日本語版と英語版の zip を作る（アプリは同じもの。入れる説明書だけが違う）
make_zip() {   # $1 = ja / en、$2 = 説明書のファイル名
    local STAGE=build/dist/$1/EdgeShelf
    local ZIP=dist/EdgeShelf-$VERSION-$1.zip
    mkdir -p "$STAGE"
    ditto build/EdgeShelf.app "$STAGE/EdgeShelf.app"
    codesign --force --sign - "$STAGE/EdgeShelf.app"   # 配るものは ad-hoc にする（証明書の本名を外に出さない）
    cp "dist/$2" "$STAGE/"
    cp LICENSE "$STAGE/"   # MIT ライセンスは、配るときにライセンスの文章を添えることを求めている
    # zip コマンドは署名を壊すことがあるので ditto で固める
    rm -f "$ZIP"
    ditto -c -k --keepParent "$STAGE" "$ZIP"
    echo "作成: $ZIP"
}
rm -rf build/dist
make_zip ja "はじめにお読みください.txt"
make_zip en "ReadMe.txt"

open ~/Applications/EdgeShelf.app   # build.sh で止めたアプリを起動し直す
