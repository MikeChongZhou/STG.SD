#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--upload" ]; }; then
    echo "Usage: $0 [--upload]" >&2
    exit 2
fi
cd "$ROOT/macos"
xcodegen generate
mkdir -p "$ROOT/dist/macos"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
ARCHIVE="$ROOT/dist/macos/STGMac-$VERSION-$BUILD.xcarchive"
xcodebuild -quiet -project STGMac.xcodeproj -scheme STGMac -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    -derivedDataPath "$ROOT/.build/macos-testflight-derived" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=DA6DVPSL36 CODE_SIGN_STYLE=Automatic archive

python3 - "$ARCHIVE/Products/Applications/STGMac.app/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
if 'STGGoogleClientSecret' in info:
    raise SystemExit('macOS archive unexpectedly contains a Google OAuth client secret')
print('Verified macOS archive contains no Google OAuth client secret.')
PY

if [ "${1:-}" = "--upload" ]; then
    xcodebuild -quiet -exportArchive -archivePath "$ARCHIVE" \
        -exportPath "$ROOT/dist/macos/TestFlight-$VERSION-$BUILD" \
        -exportOptionsPlist "$ROOT/macos/TestFlightExportOptions.plist" \
        -allowProvisioningUpdates
fi
