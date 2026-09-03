#!/bin/bash
# Builds GroqVoice.app (release) into the repo root.
#   ./build-app.sh              native arch, ad-hoc signed (fast, local dev)
#   ./build-app.sh --universal  arm64 + x86_64, ad-hoc signed
#   ./build-app.sh --dist       universal, Developer ID signed + notarized,
#                               produces GroqVoice-mac.zip + GroqVoice-mac.dmg
#
# --dist expects:
#   * a "Developer ID Application" identity in the login keychain
#   * notarytool credentials stored once via:
#     xcrun notarytool store-credentials groqvoice --apple-id <email> --team-id <TEAMID> --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0
MAKE_DIST=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --dist|--zip) UNIVERSAL=1; MAKE_DIST=1 ;;
  esac
done

if [ "$UNIVERSAL" = 1 ]; then
  # Per-arch builds + lipo: works with Command Line Tools alone
  # (swift build --arch … needs full Xcode).
  swift build -c release --triple arm64-apple-macosx14.0
  swift build -c release --triple x86_64-apple-macosx14.0
  BIN=.build/GroqVoice-universal
  lipo -create -output "$BIN" \
    .build/arm64-apple-macosx/release/GroqVoice \
    .build/x86_64-apple-macosx/release/GroqVoice
else
  swift build -c release
  BIN=.build/release/GroqVoice
fi

APP=GroqVoice.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GroqVoice"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
[ -f Resources/AppIcon.icns ] || ./Resources/make-icns.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ "$MAKE_DIST" = 1 ]; then
  IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
  if [ -z "$IDENTITY" ]; then
    echo "ERROR: no 'Developer ID Application' identity in keychain." >&2
    exit 1
  fi
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements GroqVoice.entitlements \
    --sign "$IDENTITY" "$APP"
else
  # Ad-hoc, but with a designated requirement that names the bundle identifier
  # instead of the binary's cdhash — so TCC grants (Accessibility, Microphone)
  # survive rebuilds instead of silently detaching from the app.
  codesign --force --sign - \
    -r='designated => identifier "com.abirzgals.groqvoice"' "$APP"
fi

echo
echo "Built: $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/GroqVoice" 2>/dev/null || echo native))"

if [ "$MAKE_DIST" = 1 ]; then
  rm -f GroqVoice-mac.zip GroqVoice-mac.dmg

  # Notarize the app via a temporary zip, then staple the ticket to the .app.
  ditto -c -k --keepParent "$APP" notarize-tmp.zip
  echo "Submitting to Apple notary service (usually 1-5 min)…"
  xcrun notarytool submit notarize-tmp.zip --keychain-profile groqvoice --wait
  rm -f notarize-tmp.zip
  xcrun stapler staple "$APP"

  # Final artifacts from the stapled app.
  ditto -c -k --keepParent "$APP" GroqVoice-mac.zip
  echo "Release artifact: $(pwd)/GroqVoice-mac.zip ($(du -h GroqVoice-mac.zip | cut -f1))"

  # Drag-to-install DMG: the app + an /Applications symlink.
  DMGROOT=$(mktemp -d)
  ditto "$APP" "$DMGROOT/GroqVoice.app"
  ln -s /Applications "$DMGROOT/Applications"
  hdiutil create -volname "GroqVoice" -srcfolder "$DMGROOT" -ov -quiet -format UDZO GroqVoice-mac.dmg
  rm -rf "$DMGROOT"
  codesign --force --timestamp --sign "$IDENTITY" GroqVoice-mac.dmg
  echo "Notarizing DMG…"
  xcrun notarytool submit GroqVoice-mac.dmg --keychain-profile groqvoice --wait
  xcrun stapler staple GroqVoice-mac.dmg
  echo "Release artifact: $(pwd)/GroqVoice-mac.dmg ($(du -h GroqVoice-mac.dmg | cut -f1))"
fi
