#!/bin/bash
# Makes this Mac look as if it had never run Inquiline, with the latest build waiting
# in Downloads as a fresh download. This deletes the apps installed in Inquiline and
# their data. Run Scripts/build-app.sh --zip first.
set -euo pipefail

cd "$(dirname "$0")/.."
ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)
ZIP=$(ls build/Inquiline-*-arm64.zip)

# A running copy must stop its VM, which is writing to the disk being deleted.
pkill -TERM -x 'Inquiline' || true
for _ in $(seq 1 60); do
    pgrep -x 'Inquiline' >/dev/null || pgrep -x 'Inquiline Engine' >/dev/null || break
    sleep 0.5
done
pkill -KILL -x 'Inquiline' || true
pkill -KILL -x 'Inquiline Engine' || true

rm -rf "$HOME/Library/Application Support/Inquiline" \
    "$HOME/Library/Caches/$ID" \
    "$HOME/Library/HTTPStorages/$ID" \
    "$HOME/Library/HTTPStorages/$ID.binarycookies" \
    "$HOME/Library/Saved Application State/$ID.savedState" \
    "$HOME/Library/WebKit/$ID" \
    "$HOME/Applications/Inquiline Apps" \
    "$HOME/Downloads/Inquiline.app" \
    "$HOME/Downloads/Inquiline-test.zip"
setopt nullglob 2>/dev/null || shopt -s nullglob
# The apps Inquiline made, wherever the user put them in the Applications folders: only those
# whose Info.plist names an Android package.
for app in /Applications/*.app /Applications/*/*.app "$HOME/Applications/"*.app "$HOME/Applications/"*/*.app; do
    /usr/libexec/PlistBuddy -c "Print :InquilinePackage" "$app/Contents/Info.plist" >/dev/null 2>&1 && rm -rf "$app"
done
defaults delete "$ID" 2>/dev/null || true
# The apps' own Mac settings, such as their window places, as each app is its own Mac app.
APPS=io.github.inquiline-app.app.
for prefs in "$HOME/Library/Preferences/$APPS"*.plist; do
    [ -e "$prefs" ] && defaults delete "$(basename "$prefs" .plist)" 2>/dev/null || true
done
rm -rf "$HOME/Library/Saved Application State/$APPS"*.savedState

# The mark a browser leaves on downloads, which makes macOS ask before the first launch.
cp "$ZIP" "$HOME/Downloads/Inquiline-test.zip"
xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$HOME/Downloads/Inquiline-test.zip"
echo "Ready: ~/Downloads/Inquiline-test.zip"
