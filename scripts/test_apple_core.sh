#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/module-cache"
swift test --disable-sandbox --package-path "$ROOT/apple/STGCore" --scratch-path "$ROOT/.build/apple-core"
