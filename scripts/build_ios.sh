#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT/ios"
xcodegen generate
mkdir -p "$ROOT/.build/module-cache" "$ROOT/.build/ios-derived"
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" xcodebuild -project STG.xcodeproj -scheme STG -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/.build/ios-derived" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build
mkdir -p "$ROOT/dist/ios"
ditto "$ROOT/.build/ios-derived/Build/Products/Debug-iphoneos/STG.app" "$ROOT/dist/ios/Screen Time Guardian.app"
echo "Built unsigned device bundle at $ROOT/dist/ios/Screen Time Guardian.app"
