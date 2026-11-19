#!/usr/bin/env bash
# 在 macOS 上构建未签名 IPA。
# 需要：Xcode 15+、XcodeGen（brew install xcodegen）。
# 产物：dist/LivePhotoMaker-unsigned.ipa
#
# 未签名 IPA 不能直接安装，需要用 Sideloadly / AltStore 等工具
# 使用你自己的 Apple ID 重新签名后再安装。

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未找到 xcodegen，请先运行：brew install xcodegen"
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "未找到 xcodebuild，请在 macOS + Xcode 环境中运行。"
  exit 1
fi

xcodegen generate

rm -rf build dist Payload
xcodebuild \
  -project LivePhotoMaker.xcodeproj \
  -scheme LivePhotoMaker \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="build/Build/Products/Release-iphoneos/LivePhotoMaker.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "构建产物不存在：$APP_PATH"
  exit 1
fi

mkdir -p Payload dist
cp -R "$APP_PATH" Payload/
ditto -c -k --sequesterRsrc --keepParent Payload dist/LivePhotoMaker-unsigned.ipa

echo
echo "未签名 IPA 已生成：$(pwd)/dist/LivePhotoMaker-unsigned.ipa"
