#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/FlowVision.app" >&2
  exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$1"
SOURCE_PATH="$PROJECT_ROOT/Updater/FlowVisionUpdater.swift"
OUTPUT_PATH="$APP_PATH/Contents/MacOS/FlowVisionUpdater"

if [[ ! -d "$APP_PATH" || "$(basename "$APP_PATH")" != "FlowVision.app" ]]; then
  echo "Expected a packaged FlowVision.app: $APP_PATH" >&2
  exit 1
fi

xcrun swiftc \
  -O \
  -target arm64-apple-macos11.0 \
  "$SOURCE_PATH" \
  -o "$OUTPUT_PATH"

chmod 755 "$OUTPUT_PATH"
