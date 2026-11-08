#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOTNET=${DOTNET:-dotnet}
export NUGET_PACKAGES="$ROOT/.build/nuget"
"$DOTNET" publish "$ROOT/windows/ScreenTimeGuardian/ScreenTimeGuardian.csproj" -c Release -r win-x64 --self-contained false -p:EnableWindowsTargeting=true -p:UseSharedCompilation=false --disable-build-servers -o "$ROOT/dist/windows"
cp "$ROOT/windows/Uninstall Screen Time Guardian.cmd" "$ROOT/dist/windows/Uninstall Screen Time Guardian.cmd"
