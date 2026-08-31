#!/bin/bash
#
# 本地一键打包（需要 macOS + Xcode 15+）。
# 产物为「未签名 IPA」，可用 Sideloadly / AltStore / 3uTools 等工具
# 用你的 Apple ID 自签后安装到 iOS 15+ 设备。
#
set -e

cd "$(dirname "$0")"

echo "[1/4] 生成 Xcode 工程"
python3 gen_project.py

echo "[2/4] 编译并归档（无签名）"
xcodebuild archive \
  -project TeslaDash.xcodeproj \
  -target TeslaDash \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/TeslaDash.xcarchive \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=NO

echo "[3/4] 打包为 IPA"
APP_PATH=$(find build -name "TeslaDash.app" -type d | head -1)
rm -rf Payload
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -r TeslaDash.ipa Payload
rm -rf Payload

echo "[4/4] 完成"
ls -la TeslaDash.ipa
echo "用 Sideloadly / AltStore 自签安装即可。"
