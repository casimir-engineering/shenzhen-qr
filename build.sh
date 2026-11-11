#!/bin/bash
# Builds ShenzhenQR.app into build/. With --release: Developer ID signature, notarization, staple.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ShenzhenQR.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -target arm64-apple-macos14 -o "$APP/Contents/MacOS/ShenzhenQR" ShenzhenQR.swift
cp Info.plist "$APP/Contents/Info.plist"
ICONSET=build/AppIcon.iconset; mkdir -p "$ICONSET"
for n in 16 32 128 256 512; do
  swift make-icon.swift "$ICONSET/icon_${n}x${n}.png" $n
  swift make-icon.swift "$ICONSET/icon_${n}x${n}@2x.png" $((n * 2))
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
if [[ "${1:-}" == "--release" ]]; then
  codesign --force --options runtime --timestamp --entitlements entitlements.plist \
    --sign "Developer ID Application: INTUITION Robotique & Technologies (66LJ4BV7Q3)" "$APP"
  ditto -c -k --keepParent "$APP" build/ShenzhenQR.zip
  xcrun notarytool submit build/ShenzhenQR.zip --keychain-profile shenzhenpdf-notary --wait
  xcrun stapler staple "$APP"
  spctl -a -vv "$APP"
  # The installer disk image, signed and notarized as well.
  # dmgbuild writes the window layout without Finder; electron-builder's bundled copy (Shenzhen 3D's builds fetch it).
  DMGPYTHON="${DMGPYTHON:-$HOME/Library/Caches/electron-builder/dmg-builder@1.2.5/dmgbuild-bundle-arm64-75c8a6c-9epj3/python/bin/python3}"
  tiffutil -cathidpicheck dmg/dmg-background.png dmg/dmg-background@2x.png -out build/dmg-background.tiff >/dev/null
  "$DMGPYTHON" -I -m dmgbuild -s dmg/settings.py -D app="$APP" -D background=build/dmg-background.tiff ShenzhenQR build/ShenzhenQR.dmg
  codesign --force --timestamp --sign "Developer ID Application: INTUITION Robotique & Technologies (66LJ4BV7Q3)" build/ShenzhenQR.dmg
  xcrun notarytool submit build/ShenzhenQR.dmg --keychain-profile shenzhenpdf-notary --wait
  xcrun stapler staple build/ShenzhenQR.dmg
  spctl -a -vv -t open --context context:primary-signature build/ShenzhenQR.dmg
else
  codesign --force --sign - --entitlements entitlements.plist "$APP"
fi
