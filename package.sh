#!/bin/bash
# 把构建好的 .app 打成 DMG 与 ZIP，并生成 SHA256 校验和
set -euo pipefail
cd "$(dirname "$0")"

APP="TCC 权限助手.app"
BUILD="build"
DIST="dist"
NAME="TCCHelper"
VERSION="${APP_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo dev)}"

[ -d "$BUILD/$APP" ] || { echo "先跑 ./build.sh --universal"; exit 1; }

rm -rf "$DIST"; mkdir -p "$DIST"

echo "打包 ZIP…"
ditto -c -k --keepParent --sequesterRsrc "$BUILD/$APP" "$DIST/$NAME-$VERSION.zip"

echo "打包 DMG…"
STAGE="$(mktemp -d)"
cp -R "$BUILD/$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TCC 权限助手" -srcfolder "$STAGE" -ov -format UDZO \
    "$DIST/$NAME-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

echo "生成校验和…"
( cd "$DIST" && shasum -a 256 * > SHA256SUMS )

ls -lh "$DIST"
cat "$DIST/SHA256SUMS"
