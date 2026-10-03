#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
JAVA_HOME=${JAVA_HOME:-/Applications/Android\ Studio.app/Contents/jbr/Contents/Home}
export JAVA_HOME
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
export GRADLE_USER_HOME="$ROOT/.build/gradle"
"$ROOT/android/gradlew" --project-dir "$ROOT/android" --gradle-user-home "$ROOT/.build/gradle" assembleDebug
mkdir -p "$ROOT/dist/android"
cp "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" "$ROOT/dist/android/ScreenTimeGuardian-1.1.9-debug.apk"
