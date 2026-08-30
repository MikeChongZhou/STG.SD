#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOTNET=${DOTNET:-dotnet}
export NUGET_PACKAGES="$ROOT/.build/nuget"
"$DOTNET" publish "$ROOT/windows/ScreenTimeGuardian/ScreenTimeGuardian.csproj" -c Release -r win-x64 --self-contained false -p:EnableWindowsTargeting=true -o "$ROOT/dist/windows"
