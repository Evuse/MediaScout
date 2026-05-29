#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/MediaScout.app"
EXEC_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
CACHE_DIR="$ROOT/.build/module-cache"
SWIFT_CACHE_DIR="$ROOT/.build/swift-module-cache"

mkdir -p "$EXEC_DIR" "$RES_DIR" "$CACHE_DIR" "$SWIFT_CACHE_DIR"

swiftc \
  -module-cache-path "$SWIFT_CACHE_DIR" \
  -Xcc "-fmodules-cache-path=$CACHE_DIR" \
  "$ROOT/Sources/MediaScout/main.swift" \
  -o "$EXEC_DIR/MediaScout" \
  -framework AppKit \
  -framework AVFoundation \
  -framework SwiftUI \
  -framework WebKit \
  -framework Combine

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/scripts/chrome-analyzer.js" "$RES_DIR/chrome-analyzer.js"
chmod +x "$EXEC_DIR/MediaScout"
chmod +x "$RES_DIR/chrome-analyzer.js"

echo "Built $APP_DIR"
