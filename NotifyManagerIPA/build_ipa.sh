#!/bin/bash
# 通知管理 IPA 本地构建脚本
# 用法: ./build_ipa.sh
# 要求: macOS + Xcode 15+ + iOS SDK 14.0+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/NotifyManager.app"
IPA_PATH="$BUILD_DIR/NotifyManagerIPA.ipa"

echo "=== 通知管理 IPA 构建 ==="

# 清理
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "iOS SDK: $SDK"

SRC="$SCRIPT_DIR/Source"
RES="$SCRIPT_DIR/Resources"
ENT="$SCRIPT_DIR/Entitlements"

# 编译
echo ">>> 编译..."
for f in main.m AppDelegate.m StorageManager.m AppCardView.m ViewController.m; do
  clang -x objective-c -arch arm64 -isysroot "$SDK" \
        -miphoneos-version-min=14.0 -fobjc-arc -fblocks -O2 -fobjc-exceptions \
        -c "$SRC/$f" -o "$BUILD_DIR/${f%.m}.o"
done

clang -arch arm64 -isysroot "$SDK" -fobjc-arc -fobjc-exceptions \
      -framework UIKit -framework Foundation -framework CoreGraphics \
      -framework MobileCoreServices \
      -o "$APP_DIR/NotifyManagerIPA" \
      "$BUILD_DIR"/main.o "$BUILD_DIR"/AppDelegate.o \
      "$BUILD_DIR"/StorageManager.o "$BUILD_DIR"/AppCardView.o \
      "$BUILD_DIR"/ViewController.o

echo ">>> 验证可执行文件..."
file "$APP_DIR/NotifyManagerIPA"
otool -L "$APP_DIR/NotifyManagerIPA" | head -20

echo ">>> 编译完成"

# 资源
cp "$RES/Info.plist" "$APP_DIR/"
cp "$PROJECT_DIR/NotifyManager/NotifyManager@2x.png" "$APP_DIR/AppIcon.png" 2>/dev/null || \
  echo "Warning: No icon found, app will use default icon"

# LaunchScreen
ibtool --compile "$APP_DIR/LaunchScreen.nib" "$RES/LaunchScreen.storyboard" \
       --sdk "$SDK" --target-device ios

# 签名
echo ">>> 签名..."
export CODESIGN_ALLOCATE=$(xcrun -f codesign_allocate)
ldid -S"$ENT/NotifyManagerIPA.entitlements" "$APP_DIR/NotifyManagerIPA"

# 打包 IPA
echo ">>> 打包 IPA..."
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_DIR" "$BUILD_DIR/Payload/"
cd "$BUILD_DIR"
zip -r "NotifyManagerIPA.ipa" Payload/
cd "$SCRIPT_DIR"

echo "=== 构建成功 ==="
echo "IPA: $IPA_PATH"
ls -lh "$IPA_PATH"