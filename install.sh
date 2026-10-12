#!/bin/bash
# Developer install: builds, copies the app to ~/Applications, and lets the app register its own
# login item and the `wordblock` command. (End users just open WordBlock.app and follow the guide.)
set -e
cd "$(dirname "$0")"
DEST="$HOME/Applications/WordBlock.app"

./build.sh
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R WordBlock.app "$DEST"
"$DEST/Contents/MacOS/WordBlock" --install-agent
echo "Installed. Log: ~/Library/Logs/wordblock.log. Try: wordblock status"
