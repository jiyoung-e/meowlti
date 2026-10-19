#!/bin/zsh
# Build MeowltiBar.app into ~/meowlti/menubar/build and ad-hoc sign it.
set -euo pipefail
cd "${0:A:h}"

APP=build/MeowltiBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/MeowltiBar" MeowltiBar.swift -framework AppKit -framework SwiftUI

# App icon, rendered by the app itself so it matches the in-app icon.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$APP/Contents/MacOS/MeowltiBar" --write-icon "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MeowltiBar</string>
  <key>CFBundleIdentifier</key><string>local.meowlti.bar</string>
  <key>CFBundleExecutable</key><string>MeowltiBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally; not notarized.
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
