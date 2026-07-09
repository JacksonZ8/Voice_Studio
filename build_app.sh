#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$ROOT/.build_cache/clang" "$ROOT/.build_cache/swift"
mkdir -p "$ROOT/Voice Studio.app/Contents/MacOS"

CLANG_MODULE_CACHE_PATH="$ROOT/.build_cache/clang" \
SWIFT_MODULE_CACHE_PATH="$ROOT/.build_cache/swift" \
swiftc -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  "$ROOT/native_app/Sources/VoiceStudioApp.swift" \
  -o "$ROOT/Voice Studio.app/Contents/MacOS/VoiceStudio"

echo "Built: $ROOT/Voice Studio.app"
