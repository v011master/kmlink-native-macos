#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
src="$script_dir/otimode_probe.c"
app_dir="$script_dir/OTiModeProbe.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
frameworks_dir="$contents_dir/Frameworks"
out="$macos_dir/OTiModeProbe"
legacy_app="${KMLINK_LEGACY_APP_PATH:-$HOME/Library/MacKMLinkFull/MacKMLink.app}"
legacy_framework_root="$legacy_app/Contents/PlugIns/GoBridgeDemon.app/Contents/Frameworks"

if [[ ! -d "$legacy_framework_root/OTiTransfer.framework" ]]; then
  echo "missing OTiTransfer.framework under: $legacy_framework_root" >&2
  echo "Set KMLINK_LEGACY_APP_PATH to your legally installed MacKMLink.app." >&2
  exit 66
fi

mkdir -p "$macos_dir"
mkdir -p "$frameworks_dir"

cat >"$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>English</string>
  <key>CFBundleExecutable</key>
  <string>OTiModeProbe</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.OTiModeProbe</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>OTiModeProbe</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>idProduct</key>
  <integer>8723</integer>
  <key>idVendor</key>
  <integer>3744</integer>
</dict>
</plist>
PLIST

rm -rf "$frameworks_dir/OTiTransfer.framework"
cp -R "$legacy_framework_root/OTiTransfer.framework" "$frameworks_dir/"

clang \
  -arch x86_64 \
  -O2 \
  -Wall \
  -Wextra \
  -F"$frameworks_dir" \
  -framework CoreFoundation \
  -framework OTiTransfer \
  -o "$out" \
  "$src"
echo "built $out"
