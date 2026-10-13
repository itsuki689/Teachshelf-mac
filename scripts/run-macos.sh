#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/Teachshelf.app"

if [[ ! -x "$APP_DIR/Contents/MacOS/Teachshelf" ]]; then
    "$PROJECT_DIR/scripts/build-macos.sh"
fi

if [[ $# -gt 0 ]]; then
    /usr/bin/open "$APP_DIR" --args "$@"
else
    /usr/bin/open "$APP_DIR"
fi
