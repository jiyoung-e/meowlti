#!/bin/zsh
# Build MeowltiBar.app.
#   ./build.sh            local build for this Mac, ad-hoc signed (not for distribution)
#   ./build.sh --release  universal build, Developer ID signed, notarized and stapled,
#                         plus build/MeowltiBar-<version>.zip for downloads
# Release signing settings come from ~/.config/meowlti/signing.env (outside the repo):
#   MEOWLTI_SIGN_IDENTITY="Developer ID Application: ... (TEAMID)"
#   MEOWLTI_NOTARY_PROFILE="<profile saved with: xcrun notarytool store-credentials>"
set -euo pipefail
cd "${0:A:h}"

RELEASE=0
[[ "${1:-}" == --release ]] && RELEASE=1

VERSION="$(sed -n -E 's/^MEOWLTI_VERSION=([0-9.]+)$/\1/p' ../meowlti)"
APP=build/MeowltiBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if (( RELEASE )); then
  # Universal binary: Apple silicon + Intel.
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos14" -o "build/MeowltiBar-$arch" MeowltiBar.swift -framework AppKit -framework SwiftUI
  done
  lipo -create -output "$APP/Contents/MacOS/MeowltiBar" build/MeowltiBar-arm64 build/MeowltiBar-x86_64
  rm -f build/MeowltiBar-arm64 build/MeowltiBar-x86_64
else
  swiftc -O -o "$APP/Contents/MacOS/MeowltiBar" MeowltiBar.swift -framework AppKit -framework SwiftUI
fi

# App icon, rendered by the app itself so it matches the in-app icon.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$APP/Contents/MacOS/MeowltiBar" --write-icon "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MeowltiBar</string>
  <key>CFBundleIdentifier</key><string>io.github.jiyoung-e.meowltibar</string>
  <key>CFBundleExecutable</key><string>MeowltiBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>meowlti brings a profile's Claude or Codex window to the front, quits only that window, and hands it its login link.</string>
</dict>
</plist>
PLIST

if (( ! RELEASE )); then
  # Ad-hoc signature: enough to run on this Mac.
  codesign --force --sign - "$APP"
  echo "Built $PWD/$APP"
  exit 0
fi

CONF="$HOME/.config/meowlti/signing.env"
[[ -f "$CONF" ]] && source "$CONF"
[[ -n "${MEOWLTI_SIGN_IDENTITY:-}" ]] || { echo "set MEOWLTI_SIGN_IDENTITY in $CONF" >&2; exit 1; }
[[ -n "${MEOWLTI_NOTARY_PROFILE:-}" ]] || { echo "set MEOWLTI_NOTARY_PROFILE in $CONF" >&2; exit 1; }
[[ "$MEOWLTI_SIGN_IDENTITY" == "Developer ID Application:"* ]] \
  || { echo "MEOWLTI_SIGN_IDENTITY must be a 'Developer ID Application' certificate" >&2; exit 1; }

# Hardened runtime is required for notarization; Apple Events are how meowlti talks to app windows.
cat > build/entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
PLIST
codesign --force --timestamp --options runtime --entitlements build/entitlements.plist \
  --sign "$MEOWLTI_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="build/MeowltiBar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Submitting to Apple for notarization (usually a few minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$MEOWLTI_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# Re-zip so the download carries the stapled ticket (works offline on first launch).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
shasum -a 256 "$ZIP"
echo "Release ready: $PWD/$ZIP"
