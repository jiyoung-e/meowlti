#!/bin/zsh
# Build MeowltiBar.app.
#   ./build.sh            local build for this Mac, ad-hoc signed, no auto-update (not for distribution)
#   ./build.sh --release  universal build, Developer ID signed, notarized and stapled, Sparkle-enabled,
#                         plus build/updates/MeowltiBar-<version>.zip and a signed appcast.xml
# Release settings come from ~/.config/meowlti/signing.env (outside the repo):
#   MEOWLTI_SIGN_IDENTITY="Developer ID Application: ... (TEAMID)"
#   MEOWLTI_NOTARY_PROFILE="<profile saved with: xcrun notarytool store-credentials>"
# Release builds also need the Sparkle update key: public half in sparkle-public-key.txt (committed),
# private half in the login keychain of the release Mac (account "meowlti", see scripts/setup-dev.sh).
set -euo pipefail
cd "${0:A:h}"

RELEASE=0
[[ "${1:-}" == --release ]] && RELEASE=1

REPO="jiyoung-e/meowlti"
SPARKLE_ACCOUNT=meowlti
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
VERSION="$(sed -n -E 's/^MEOWLTI_VERSION=([0-9.]+)$/\1/p' ../meowlti)"
SPARKLE="$(./fetch-sparkle.sh)"
APP=build/MeowltiBar.app
FW="$APP/Contents/Frameworks/Sparkle.framework"

if (( RELEASE )); then
  [[ -s sparkle-public-key.txt ]] || { echo "sparkle-public-key.txt is missing — run scripts/setup-dev.sh on the release Mac" >&2; exit 1; }
  CONF="$HOME/.config/meowlti/signing.env"
  [[ -f "$CONF" ]] && source "$CONF"
  [[ -n "${MEOWLTI_SIGN_IDENTITY:-}" ]] || { echo "set MEOWLTI_SIGN_IDENTITY in $CONF" >&2; exit 1; }
  [[ -n "${MEOWLTI_NOTARY_PROFILE:-}" ]] || { echo "set MEOWLTI_NOTARY_PROFILE in $CONF" >&2; exit 1; }
  [[ "$MEOWLTI_SIGN_IDENTITY" == "Developer ID Application:"* ]] \
    || { echo "MEOWLTI_SIGN_IDENTITY must be a 'Developer ID Application' certificate" >&2; exit 1; }
  "$SPARKLE/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null 2>&1 \
    || { echo "no Sparkle signing key (account $SPARKLE_ACCOUNT) in this Mac's keychain — run scripts/setup-dev.sh" >&2; exit 1; }
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

swift_build() {   # swift_build <output> [target]
  local -a target=()   # zsh keeps ${2:+-target "$2"} as one word, so pass the flag as an array
  [[ -n "${2:-}" ]] && target=(-target "$2")
  swiftc -O "${target[@]}" -o "$1" MeowltiBar.swift -framework AppKit -framework SwiftUI \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
}
if (( RELEASE )); then
  # Universal binary: Apple silicon + Intel (Sparkle.framework is universal too).
  for arch in arm64 x86_64; do swift_build "build/MeowltiBar-$arch" "$arch-apple-macos14"; done
  lipo -create -output "$APP/Contents/MacOS/MeowltiBar" build/MeowltiBar-arm64 build/MeowltiBar-x86_64
  rm -f build/MeowltiBar-arm64 build/MeowltiBar-x86_64
else
  swift_build "$APP/Contents/MacOS/MeowltiBar"
fi

# Embed Sparkle (ditto keeps the framework's symlinks). The XPC services are only for sandboxed apps.
ditto "$SPARKLE/Sparkle.framework" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"

# App icon, rendered by the app itself so it matches the in-app icon.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$APP/Contents/MacOS/MeowltiBar" --write-icon "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

SPARKLE_KEYS=""
if (( RELEASE )); then
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$(tr -d '[:space:]' < sparkle-public-key.txt)</string>"
fi
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
$SPARKLE_KEYS
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

if (( ! RELEASE )); then
  # Ad-hoc signatures: enough to run on this Mac (no hardened runtime, so the framework loads).
  codesign --force --sign - "$FW"
  codesign --force --sign - "$APP"
  echo "Built $PWD/$APP"
  exit 0
fi

# Sign inside-out with the hardened runtime (Sparkle's documented order), then the app.
sign() { codesign --force --timestamp --options runtime --sign "$MEOWLTI_SIGN_IDENTITY" "$@"; }
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
# Apple Events are how meowlti talks to app windows.
cat > build/entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
PLIST
sign --entitlements build/entitlements.plist "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

UPD=build/updates
ZIP="$UPD/MeowltiBar-$VERSION.zip"
rm -rf "$UPD"; mkdir -p "$UPD"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Submitting to Apple for notarization (the first ones can take a while)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$MEOWLTI_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# Re-zip so the download carries the stapled ticket (works offline on first launch).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"

# Signed update feed: generate_appcast signs the zip with the Sparkle key from this Mac's keychain.
"$SPARKLE/bin/generate_appcast" --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" -o "$UPD/appcast.xml" "$UPD"
grep -q 'sparkle:edSignature' "$UPD/appcast.xml" || { echo "appcast.xml has no EdDSA signature" >&2; exit 1; }

shasum -a 256 "$ZIP"
cat <<EOF
Release ready in $PWD/$UPD:
  $(basename "$ZIP")   (signed, notarized, stapled)
  appcast.xml          (Sparkle feed; must be attached to every release, since the app reads
                        $FEED_URL)
Upload both to the v$VERSION GitHub release, e.g.:
  gh release upload v$VERSION $PWD/$ZIP $PWD/$UPD/appcast.xml --repo $REPO
EOF
