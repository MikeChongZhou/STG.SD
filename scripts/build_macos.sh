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
cp "$ROOT/apple/STGCore/Sources/STGCore/Resources/stg.sqlite" "$APP/Contents/Resources/stg.sqlite"
# SwiftUI's implicit localized-string lookup uses Bundle.main. Mirror the app
# localizations into the conventional main-bundle Resources location as well.
for LANGUAGE_DIR in "$ROOT/macos/Sources/STGMac/Resources"/*.lproj; do
    LANGUAGE_NAME=$(basename "$LANGUAGE_DIR")
    mkdir -p "$APP/Contents/Resources/$LANGUAGE_NAME"
    cp "$LANGUAGE_DIR/Localizable.strings" "$APP/Contents/Resources/$LANGUAGE_NAME/Localizable.strings"
done
STG_SIGN_IDENTITY_VALUE=${STG_SIGN_IDENTITY:-"-"}
# Local and distribution builds must both remain sandboxed. Removing this
# entitlement gives the same bundle identifier a second Application Support
# directory, which splits the device history and lets the two copies overwrite
# the same cloud files.
if [ "$STG_SIGN_IDENTITY_VALUE" = "-" ]; then
    # Keep the sandbox so this build uses the production data container. iCloud
    # capabilities need a provisioned Apple signature, so omit only those from
    # an ad-hoc build; OneDrive and Google Drive remain available.
    codesign --force --sign - --entitlements "$ROOT/macos/STGMac.local.entitlements" "$APP"
else
    codesign --force --options runtime --timestamp --sign "$STG_SIGN_IDENTITY_VALUE" --entitlements "$ROOT/macos/STGMac.entitlements" "$APP"
fi
# Finder displays the bundle directory timestamp, not the newest file inside it.
touch "$APP"
echo "Built $APP"
