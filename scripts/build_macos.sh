#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/.build/module-cache" "$ROOT/dist"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/module-cache"
swift build --disable-sandbox --package-path "$ROOT/macos" --scratch-path "$ROOT/.build/macos-current" -c release
APP="$ROOT/dist/Screen Time Guardian.app"
if [ -d "$APP" ]; then
    rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/macos-current/release/STGMac" "$APP/Contents/MacOS/STGMac"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${STG_GOOGLE_CLIENT_SECRET:-}" ]; then
    plutil -replace STGGoogleClientSecret -string "$STG_GOOGLE_CLIENT_SECRET" "$APP/Contents/Info.plist"
fi
cp "$ROOT/macos/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/apple/STGCore/Sources/STGCore/Resources/openrouter-weekly-seed-v1.json" "$APP/Contents/Resources/openrouter-weekly-seed-v1.json"
STG_SIGN_IDENTITY_VALUE=${STG_SIGN_IDENTITY:-"-"}
if [ -n "${STG_ENABLE_ICLOUD_ENTITLEMENTS+x}" ]; then
    STG_ENABLE_ICLOUD_ENTITLEMENTS_VALUE=$STG_ENABLE_ICLOUD_ENTITLEMENTS
elif [ "$STG_SIGN_IDENTITY_VALUE" = "-" ]; then
    # Restricted iCloud entitlements on an ad-hoc signature make launchd reject
    # the executable even when `codesign --verify` reports success.
    STG_ENABLE_ICLOUD_ENTITLEMENTS_VALUE=0
else
    STG_ENABLE_ICLOUD_ENTITLEMENTS_VALUE=1
fi
if [ "$STG_ENABLE_ICLOUD_ENTITLEMENTS_VALUE" = "0" ]; then
    if [ "$STG_SIGN_IDENTITY_VALUE" = "-" ]; then
        codesign --force --sign - "$APP"
    else
        codesign --force --options runtime --timestamp --sign "$STG_SIGN_IDENTITY_VALUE" "$APP"
    fi
elif [ "$STG_SIGN_IDENTITY_VALUE" = "-" ]; then
    codesign --force --sign - --entitlements "$ROOT/macos/STGMac.entitlements" "$APP"
else
    codesign --force --options runtime --timestamp --sign "$STG_SIGN_IDENTITY_VALUE" --entitlements "$ROOT/macos/STGMac.entitlements" "$APP"
fi
# Finder displays the bundle directory timestamp, not the newest file inside it.
touch "$APP"
echo "Built $APP"
