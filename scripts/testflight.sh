#!/bin/sh
# TestFlight 打包脚本
# 用法: sh scripts/testflight.sh <付费团队ID>
set -e

TEAM_ID="${1:?请传入付费团队 ID，例如 sh scripts/testflight.sh ABCDE12345}"

echo "==> 1/2 归档 (Release, 付费团队 $TEAM_ID)"
xcodebuild archive \
  -project TXTReader.xcodeproj \
  -scheme TXTReader \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/TXTReader.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID"

echo "==> 2/2 导出 IPA (app-store-connect)"
xcodebuild -exportArchive \
  -archivePath build/TXTReader.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates

echo "完成：build/export/TXTReader.ipa"
echo "上传方式二选一："
echo "  A) 打开 Xcode > Window > Organizer > Distribute App > App Store Connect > Upload"
echo "  B) xcrun altool --upload-app -f build/export/TXTReader.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
