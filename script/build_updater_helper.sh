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
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ ! -d "$APP_PATH" || "$(basename "$APP_PATH")" != "FlowVision.app" ]]; then
  echo "Expected a packaged FlowVision.app: $APP_PATH" >&2
  exit 1
fi

for arch in arm64 x86_64; do
  xcrun swiftc \
    -O \
    -target "${arch}-apple-macos11.0" \
    "$SOURCE_PATH" \
    -o "$WORK_DIR/FlowVisionUpdater-$arch"
done

lipo -create \
  "$WORK_DIR/FlowVisionUpdater-arm64" \
  "$WORK_DIR/FlowVisionUpdater-x86_64" \
  -output "$OUTPUT_PATH"

chmod 755 "$OUTPUT_PATH"
