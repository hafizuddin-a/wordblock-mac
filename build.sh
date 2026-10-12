#!/bin/bash
# Builds WordBlock.app (universal: Apple Silicon + Intel, macOS 12+) and signs it.
# Signs with the local "WordBlock Local Signing" certificate if you have one (keeps the Accessibility
# permission across rebuilds), otherwise ad-hoc.
set -e
cd "$(dirname "$0")"
APP=WordBlock.app
VERSION=1.0.0
rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build
cp WordBlock.icns "$APP/Contents/Resources/"
swiftc -O -target arm64-apple-macos12.0 wordblock.swift -o .build/arm64
swiftc -O -target x86_64-apple-macos12.0 wordblock.swift -o .build/x86_64
lipo -create .build/arm64 .build/x86_64 -output "$APP/Contents/MacOS/WordBlock"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.hafiz.wordblock</string>
  <key>CFBundleName</key><string>WordBlock</string>
  <key>CFBundleIconFile</key><string>WordBlock</string>
  <key>CFBundleExecutable</key><string>WordBlock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
ID=$(security find-identity -p codesigning | awk '/WordBlock Local Signing/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
rm -rf .build
if [ -n "$ID" ]; then HOW="local certificate"; else HOW="ad-hoc"; fi
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/WordBlock")), signed with $HOW"
