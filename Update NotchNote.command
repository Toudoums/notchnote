#!/bin/bash
# Double-click to update NotchNote to the newest release. Your notes are kept.
URL="https://github.com/Toudoums/notchnote/releases/latest/download/NotchNote-app.zip"
APP="/Applications/NotchNote.app"
TMP="$(mktemp -d)"
echo "Downloading the newest NotchNote..."
if ! curl -fL --progress-bar -o "$TMP/NotchNote-app.zip" "$URL"; then
  echo; echo "Download failed. Check your internet connection and try again."; read -n 1 -s -r -p "Press any key to close."; exit 1
fi
echo "Closing the running copy..."
osascript -e 'tell application "NotchNote" to quit' >/dev/null 2>&1
sleep 1; pkill -x NotchNote >/dev/null 2>&1
echo "Installing..."
ditto -x -k "$TMP/NotchNote-app.zip" "$TMP/out" || { echo "Could not unzip."; exit 1; }
rm -rf "$APP"
ditto "$TMP/out/NotchNote.app" "$APP"
xattr -cr "$APP"
rm -rf "$TMP"
open "$APP"
echo; echo "Done. NotchNote is updated and running. You can close this window."
