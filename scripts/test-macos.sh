#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select --print-path)}"

cd "$PROJECT_DIR"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
if command -v node >/dev/null 2>&1; then
    node "$PROJECT_DIR/scripts/test-nju-parser.js"
else
    printf '未检测到 Node.js，跳过本科课表解析器测试（可单独运行 node scripts/test-nju-parser.js）。\n'
fi
TEST_ARGS=(
    --disable-sandbox --disable-xctest
    --cache-path "$PROJECT_DIR/.build/cache"
    --config-path "$PROJECT_DIR/.build/config"
    --security-path "$PROJECT_DIR/.build/security"
)

# Command Line Tools ships Swift Testing outside the platform SDK search path.
if [[ "$SELECTED_DEVELOPER_DIR" == */CommandLineTools ]]; then
    TEST_ARGS+=(--build-system native)
    TEST_FRAMEWORKS="$SELECTED_DEVELOPER_DIR/Library/Developer/Frameworks"
    TEST_ARGS+=(
        -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS"
        -Xlinker -F -Xlinker "$TEST_FRAMEWORKS"
        -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS"
    )
    TEST_PLUGIN="$SELECTED_DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [[ -f "$TEST_PLUGIN" ]]; then
        TEST_ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN")
    fi
fi

exec swift test "${TEST_ARGS[@]}" "$@"
