#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$root/build/KMLinkNative.app"
exe="$root/.build/release/KMLinkNative"

cd "$root"
mkdir -p "$root/.cache/clang" "$root/.cache/swiftpm" "$root/.cache/home"

env \
  HOME="$root/.cache/home" \
  XDG_CACHE_HOME="$root/.cache" \
  CLANG_MODULE_CACHE_PATH="$root/.cache/clang" \
  SWIFTPM_HOME="$root/.cache/swiftpm" \
  swift build -c release --scratch-path "$root/.build"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"

cp "$exe" "$bundle/Contents/MacOS/KMLinkNative"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>KMLinkNative</string>
  <key>CFBundleIdentifier</key>
  <string>org.kmlinknative.app</string>
  <key>CFBundleName</key>
  <string>KMLink Native</string>
  <key>CFBundleDisplayName</key>
  <string>KMLink Native</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>KMLink Native opens System Settings so you can grant Accessibility permission.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$bundle"
fi

echo "$bundle"
