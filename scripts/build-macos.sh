#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/Teachshelf.app"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

cd "$PROJECT_DIR"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
# Bash 3.2 treats an empty array as unset under `set -u` (the Xcode path).
BUILD_ARGS=(--configuration release)
if [[ "${DEVELOPER_DIR:-$(/usr/bin/xcode-select --print-path)}" == */CommandLineTools ]]; then
    # CLT's SwiftBuild backend attempts a restricted dSYM generation step.
    BUILD_ARGS+=(--build-system native -Xswiftc -gnone)
fi
swift build --disable-sandbox \
    --cache-path "$PROJECT_DIR/.build/cache" \
    --config-path "$PROJECT_DIR/.build/config" \
    --security-path "$PROJECT_DIR/.build/security" \
    --product Teachshelf "${BUILD_ARGS[@]}"

swift build --disable-sandbox \
    --cache-path "$PROJECT_DIR/.build/cache" \
    --config-path "$PROJECT_DIR/.build/config" \
    --security-path "$PROJECT_DIR/.build/security" \
    --product TeachshelfMCP "${BUILD_ARGS[@]}"

mkdir -p "$PROJECT_DIR/build"
BUNDLE_STAGE="$(mktemp -d "$PROJECT_DIR/build/.app-bundle.XXXXXX")"
STAGED_APP="$BUNDLE_STAGE/Teachshelf.app"
cleanup() {
    if [[ ! -e "$APP_DIR" && -d "$BUNDLE_STAGE/Previous.app" ]]; then
        mv "$BUNDLE_STAGE/Previous.app" "$APP_DIR"
    fi
    rm -rf "$BUNDLE_STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$PROJECT_DIR/.build/release/Teachshelf" "$STAGED_APP/Contents/MacOS/Teachshelf"
cp "$PROJECT_DIR/.build/release/TeachshelfMCP" "$STAGED_APP/Contents/MacOS/TeachshelfMCP"
cp "$PROJECT_DIR/docs/MCP.md" "$STAGED_APP/Contents/Resources/MCP.md"
cp "$PROJECT_DIR/docs/AI.md" "$STAGED_APP/Contents/Resources/AI.md"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
if [[ -d "$PROJECT_DIR/Resources/Timetable" ]]; then
    cp -R "$PROJECT_DIR/Resources/Timetable" "$STAGED_APP/Contents/Resources/Timetable"
fi
cp "$PROJECT_DIR/README.md" "$STAGED_APP/Contents/Resources/README.md"
cp "$PROJECT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
cp -R "$PROJECT_DIR/Resources/TeachingWebsite" "$STAGED_APP/Contents/Resources/TeachingWebsite"
chmod +x "$STAGED_APP/Contents/MacOS/Teachshelf"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGED_APP/Contents/MacOS/TeachshelfMCP"
/usr/bin/codesign --force --deep --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
if [[ -e "$APP_DIR" ]]; then mv "$APP_DIR" "$BUNDLE_STAGE/Previous.app"; fi
mv "$STAGED_APP" "$APP_DIR"

printf '\n已生成 macOS 应用：%s\n' "$APP_DIR"
printf '启动：./scripts/run-macos.sh\n'
