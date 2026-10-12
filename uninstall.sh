#!/bin/bash
# Stops WordBlock and removes the login item and the installed app. Refuses while the lock is on.
LABEL=com.hafiz.wordblock
BIN="$HOME/Applications/WordBlock.app/Contents/MacOS/WordBlock"
if [ -x "$BIN" ]; then
  "$BIN" stop
  [ $? -eq 2 ] && { echo "Not removed: unlock first ('wordblock unlock'), wait for the countdown, then run this again."; exit 1; }
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x WordBlock 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/wordblock"
rm -rf "$HOME/Applications/WordBlock.app"
echo "Removed. Your word list (~/.config/wordblock/words.txt) and lock state were left alone."
