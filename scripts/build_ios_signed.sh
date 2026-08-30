#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT/ios"
xcodegen generate
mkdir -p "$ROOT/.build/module-cache" "$ROOT/.build/ios-signed-derived" "$ROOT/dist/ios-signed"
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" xcodebuild \
  -project STG.xcodeproj \
  -scheme STG \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$ROOT/.build/ios-signed-derived" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=DA6DVPSL36 \
  CODE_SIGN_STYLE=Automatic \
  build
ditto "$ROOT/.build/ios-signed-derived/Build/Products/Release-iphoneos/STG.app" "$ROOT/dist/ios-signed/Screen Time Guardian.app"
echo "Built signed device bundle at $ROOT/dist/ios-signed/Screen Time Guardian.app"
