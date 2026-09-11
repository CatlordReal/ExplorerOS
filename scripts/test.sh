#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
python_bin=${EXPLORERLINK_PYTHON:-python3}
if [ -x "$repo_dir/.venv/bin/python" ]; then python_bin="$repo_dir/.venv/bin/python"; fi
"$python_bin" -m unittest discover -s simulator/tests -v
"$python_bin" -m unittest discover -s scripts/tests -v
"$python_bin" "$repo_dir/scripts/test-shortcuts.py"
"$repo_dir/glass-bridge/scripts/test-core.sh"
cd "$repo_dir/apple"
export CLANG_MODULE_CACHE_PATH="$repo_dir/apple/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/apple/.cache/swift"
xcrun swift test --scratch-path .build --cache-path .cache --disable-sandbox
