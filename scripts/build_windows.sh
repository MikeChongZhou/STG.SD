#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOTNET=${DOTNET:-dotnet}
export NUGET_PACKAGES="$ROOT/.build/nuget"
if [ -z "${STG_GOOGLE_CLIENT_SECRET:-}" ] && [ -f "$ROOT/android/local.properties" ]; then
    STG_GOOGLE_CLIENT_SECRET=$(awk -F= '$1 == "STG_GOOGLE_CLIENT_SECRET" { sub(/^[^=]*=/, ""); print; exit }' "$ROOT/android/local.properties")
    export STG_GOOGLE_CLIENT_SECRET
fi
if [ -z "${STG_GOOGLE_CLIENT_SECRET:-}" ]; then
    echo "Windows release build requires STG_GOOGLE_CLIENT_SECRET in the environment or Git-ignored android/local.properties." >&2
    exit 1
fi
"$DOTNET" publish "$ROOT/windows/ScreenTimeGuardian/ScreenTimeGuardian.csproj" -c Release -r win-x64 --self-contained false -p:EnableWindowsTargeting=true -p:UseSharedCompilation=false --disable-build-servers -o "$ROOT/dist/windows"
cp "$ROOT/windows/Uninstall Screen Time Guardian.cmd" "$ROOT/dist/windows/Uninstall Screen Time Guardian.cmd"
