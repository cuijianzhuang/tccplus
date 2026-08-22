#!/bin/bash
# 构建 TCC 权限助手.app
#   ./build.sh              默认构建（本机架构，快）
#   ./build.sh --universal  构建 arm64 + x86_64 通用二进制
set -euo pipefail
cd "$(dirname "$0")"

APP="TCC 权限助手.app"
BUILD="build"
MIN_MACOS="13.0"
UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

rm -rf "$BUILD/$APP"
mkdir -p "$BUILD/$APP/Contents/MacOS" "$BUILD/$APP/Contents/Resources"

cat > "$BUILD/$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TCCHelper</string>
    <key>CFBundleDisplayName</key><string>TCC 权限助手</string>
    <key>CFBundleExecutable</key><string>TCCHelper</string>
    <key>CFBundleIdentifier</key><string>local.tccplus.helper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>需要以管理员权限运行 tccplus 来修改隐私数据库。</string>
</dict>
</plist>
PLIST

# 版本号来自 git tag（CI 打 tag 时自动写入）
VERSION="${APP_VERSION:-}"
if [ -z "$VERSION" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
fi
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        "$BUILD/$APP/Contents/Info.plist"
    echo "版本号: $VERSION"
fi

# 编译：单架构或 lipo 合并
compile() {  # compile <输出路径> <源文件…>
    local out="$1"; shift
    local common=(-O "$@")
    if [ "$UNIVERSAL" = "1" ]; then
        local slices=()
        for arch in x86_64 arm64; do
            local slice="$BUILD/.$arch-$(basename "$out")"
            swiftc "${common[@]}" -target "$arch-apple-macos$MIN_MACOS" -o "$slice"
            slices+=("$slice")
        done
        lipo -create "${slices[@]}" -output "$out"
        rm -f "${slices[@]}"
    else
        swiftc "${common[@]}" -o "$out"
    fi
}

echo "生成图标…"
rm -rf "$BUILD/AppIcon.iconset"
swift Tools/MakeIcon.swift "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
cp "$BUILD/AppIcon.icns" "$BUILD/$APP/Contents/Resources/AppIcon.icns"

echo "编译界面…"
compile "$BUILD/$APP/Contents/MacOS/TCCHelper" \
    -parse-as-library Sources/App.swift -framework SwiftUI -framework AppKit

echo "编译内置 tccplus…"
if [ -x "./tccplus" ]; then
    cp ./tccplus "$BUILD/$APP/Contents/Resources/tccplus"
    echo "  → 使用项目根目录的 tccplus"
else
    compile "$BUILD/$APP/Contents/Resources/tccplus" Sources/tccplus.swift
    echo "  → 使用内置实现"
fi
cp "$BUILD/$APP/Contents/Resources/tccplus" "$BUILD/tccplus"

codesign --force --deep --sign - "$BUILD/$APP" 2>/dev/null || true

echo "完成：$BUILD/$APP"
lipo -archs "$BUILD/$APP/Contents/MacOS/TCCHelper" | sed 's/^/  架构: /'
