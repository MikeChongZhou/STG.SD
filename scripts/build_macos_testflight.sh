#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--upload" ]; }; then
    echo "Usage: $0 [--upload]" >&2
    exit 2
fi
if [ -z "${STG_GOOGLE_CLIENT_SECRET:-}" ] && [ -f "$ROOT/android/local.properties" ]; then
    STG_GOOGLE_CLIENT_SECRET=$(awk -F= '$1 == "STG_GOOGLE_CLIENT_SECRET" { sub(/^[^=]*=/, ""); print; exit }' "$ROOT/android/local.properties")
fi
if [ -z "${STG_GOOGLE_CLIENT_SECRET:-}" ]; then
    echo "macOS TestFlight build requires STG_GOOGLE_CLIENT_SECRET or Git-ignored android/local.properties." >&2
    exit 1
fi
export STG_GOOGLE_CLIENT_SECRET

CONFIG=$(mktemp /tmp/stg-macos-google-XXXXXX.xcconfig)
trap 'rm -f "$CONFIG"' EXIT HUP INT TERM
chmod 600 "$CONFIG"
printf 'STG_GOOGLE_CLIENT_SECRET = %s\n' "$STG_GOOGLE_CLIENT_SECRET" > "$CONFIG"

cd "$ROOT/macos"
xcodegen generate
mkdir -p "$ROOT/dist/macos"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
ARCHIVE="$ROOT/dist/macos/STGMac-$VERSION-$BUILD.xcarchive"
xcodebuild -quiet -project STGMac.xcodeproj -scheme STGMac -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    -derivedDataPath "$ROOT/.build/macos-testflight-derived" -xcconfig "$CONFIG" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=DA6DVPSL36 CODE_SIGN_STYLE=Automatic archive

python3 - "$ARCHIVE/Products/Applications/STGMac.app/Contents/Info.plist" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
if info.get('STGGoogleClientSecret') != os.environ['STG_GOOGLE_CLIENT_SECRET']:
    raise SystemExit('macOS archive is missing the configured Google OAuth client secret')
print('Verified macOS archive Google OAuth configuration.')
PY

if [ "${1:-}" = "--upload" ]; then
    xcodebuild -quiet -exportArchive -archivePath "$ARCHIVE" \
        -exportPath "$ROOT/dist/macos/TestFlight-$VERSION-$BUILD" \
        -exportOptionsPlist "$ROOT/macos/TestFlightExportOptions.plist" \
        -allowProvisioningUpdates
fi
