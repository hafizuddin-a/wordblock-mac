#!/bin/bash
# Builds a release zip for GitHub Releases: dist/WordBlock-<version>.zip plus an identical dist/WordBlock.zip
# Must be signed with the local certificate, so updates keep users' Accessibility permission.
set -e
cd "$(dirname "$0")"
security find-identity -p codesigning | grep -q "WordBlock Local Signing" \
  || { echo "No 'WordBlock Local Signing' certificate found. Releases must not be ad-hoc signed."; exit 1; }
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" WordBlock.app/Contents/Info.plist)
codesign --verify --deep --strict WordBlock.app
mkdir -p dist
ZIP="dist/WordBlock-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent WordBlock.app "$ZIP"
cp "$ZIP" dist/WordBlock.zip  # fixed name, so the README can link releases/latest/download/WordBlock.zip
echo "Created $ZIP (and dist/WordBlock.zip)"
shasum -a 256 "$ZIP"
