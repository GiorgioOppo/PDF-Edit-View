#!/bin/bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
if [[ -z "${DEVELOPER_DIR+x}" ]] && [[ "$(xcode-select -p)" == */CommandLineTools ]] && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
test_root="${TMPDIR:-/tmp}/CartaPDF-native-tests-$(id -u)"
mkdir -p "$test_root/ModuleCache" "$test_root/cache"
export CLANG_MODULE_CACHE_PATH="$test_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
xcrun swift test --scratch-path "$test_root/build" --cache-path "$test_root/cache" --manifest-cache local "$@"
