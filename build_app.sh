#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Voice Studio.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

# Parse args
RELEASE=false
CLEAN=false
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=true ;;
    --clean) CLEAN=true ;;
    --version=*) VERSION="${arg#*=}" ;;
  esac
done

if $CLEAN; then
  rm -rf "$APP" "$ROOT/.build_cache" "$ROOT/Voice_Studio-v"*.zip
  echo "Cleaned build artifacts"
fi

mkdir -p "$ROOT/.build_cache/clang" "$ROOT/.build_cache/swift"
mkdir -p "$MACOS" "$RESOURCES"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>VoiceStudio</string>
  <key>CFBundleIdentifier</key>
  <string>com.voicestudio.local</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Voice Studio</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

CLANG_MODULE_CACHE_PATH="$ROOT/.build_cache/clang" \
SWIFT_MODULE_CACHE_PATH="$ROOT/.build_cache/swift" \
swiftc -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  "$ROOT/native_app/Sources/VoiceStudioApp.swift" \
  -o "$MACOS/VoiceStudio"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built: $APP"

if $RELEASE; then
  ZIP="$ROOT/Voice_Studio-v${VERSION}.zip"
  rm -f "$ZIP"
  # Create zip: app bundle plus setup files
  (cd "$ROOT" && zip -r "$ZIP" \
    "Voice Studio.app" \
    configs/engine_config.example.json \
    -x "*.build_cache*" \
    -x "*.git*" \
    -x "*__pycache__*" \
    -x "*.DS_Store" \
  )
  echo "Release: $ZIP"
  # Generate SHA-256 for the release
  shasum -a 256 "$ZIP" | cut -d' ' -f1 > "$ZIP.sha256"
  echo "Checksum: $(cat "$ZIP.sha256")"
fi
