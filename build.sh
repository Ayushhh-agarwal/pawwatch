#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/PawWatch.app"
BIN="$APP/Contents/MacOS/PawWatch"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
swiftc -O "$DIR/AgentPets.swift" -o "$BIN" -framework AppKit
chmod +x "$BIN"
"$BIN" --self-test >/dev/null
rm -rf "$APP/Contents/Resources/assets"
cp -R "$DIR/assets" "$APP/Contents/Resources/assets"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>PawWatch</string>
  <key>CFBundleExecutable</key>
  <string>PawWatch</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.ayushhhagarwal.pawwatch</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>PawWatch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
touch "$APP"

printf '%s\n' "$APP"
