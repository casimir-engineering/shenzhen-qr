#!/bin/bash
# Builds ShenzhenQR.app into build/. With --release: Developer ID signature, notarization, staple.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ShenzhenQR.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -target arm64-apple-macos14 -o "$APP/Contents/MacOS/ShenzhenQR" ShenzhenQR.swift
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ "${1:-}" == "--release" ]]; then
  codesign --force --options runtime --timestamp --entitlements entitlements.plist \
    --sign "Developer ID Application: INTUITION Robotique & Technologies (66LJ4BV7Q3)" "$APP"
  ditto -c -k --keepParent "$APP" build/ShenzhenQR.zip
  xcrun notarytool submit build/ShenzhenQR.zip --keychain-profile shenzhenpdf-notary --wait
  xcrun stapler staple "$APP"
  spctl -a -vv "$APP"
else
  codesign --force --sign - --entitlements entitlements.plist "$APP"
fi
