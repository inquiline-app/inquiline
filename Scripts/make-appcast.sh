#!/bin/bash
# Adds the version in Resources/Info.plist to appcast.xml, the list Sparkle reads to find
# updates, after Scripts/build-app.sh --dmg. The disk image is signed with the key that
# Sparkle's generate_keys keeps in this Mac's Keychain (account "inquiline"); its public half
# is SUPublicEDKey in Info.plist. Then commit appcast.xml, and upload the disk image and the
# delta to the GitHub release v<version>.
#
# The delta, build/Inquiline<build>-<previous build>.delta, takes an app of the previous release
# to this one with only what changed, so updating downloads tens of megabytes rather than the
# whole app; Sparkle falls back to the disk image if it can't apply it. The previous release's
# disk image comes from build/, or from its GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $PLIST)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' $PLIST)
DMG="build/Inquiline-$VERSION-arm64.dmg"
[ -f "$DMG" ] || { echo "Missing $DMG: run Scripts/build-app.sh --dmg first." >&2; exit 1; }
grep -q "<sparkle:version>$BUILD</sparkle:version>" appcast.xml 2>/dev/null &&
    { echo "appcast.xml already has build $BUILD: raise CFBundleVersion." >&2; exit 1; }
SIGNATURE=$(.build/sparkle/bin/sign_update --account inquiline "$DMG")

# The newest release so far, which the delta updates from.
PREV_VERSION=$(sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p' appcast.xml 2>/dev/null | head -1)
PREV_BUILD=$(sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' appcast.xml 2>/dev/null | head -1)
DELTAS=""
if [ -n "$PREV_VERSION" ]; then
    PREV_DMG="build/Inquiline-$PREV_VERSION-arm64.dmg"
    [ -f "$PREV_DMG" ] || gh release download "v$PREV_VERSION" --repo inquiline-app/inquiline \
        --pattern "$(basename "$PREV_DMG")" --dir build
    WORK=$(mktemp -d)
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/old" "$PREV_DMG"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/new" "$DMG"
    DELTA="build/Inquiline$BUILD-$PREV_BUILD.delta"
    rm -f "$DELTA"
    .build/sparkle/bin/BinaryDelta create "$WORK/old/Inquiline.app" "$WORK/new/Inquiline.app" "$DELTA"
    # Applied to the previous app, it must make exactly this one.
    .build/sparkle/bin/BinaryDelta apply "$WORK/old/Inquiline.app" "$WORK/check.app" "$DELTA" >/dev/null
    hdiutil detach -quiet "$WORK/old"
    hdiutil detach -quiet "$WORK/new"
    rm -rf "$WORK"
    DELTA_SIGNATURE=$(.build/sparkle/bin/sign_update --account inquiline "$DELTA")
    DELTAS="
            <sparkle:deltas>
                <enclosure url=\"https://github.com/inquiline-app/inquiline/releases/download/v$VERSION/$(basename "$DELTA")\" sparkle:deltaFrom=\"$PREV_BUILD\" $DELTA_SIGNATURE type=\"application/octet-stream\"/>
            </sparkle:deltas>"
    echo "Delta from $PREV_VERSION: $(du -h "$DELTA" | cut -f1)"
fi
ITEM="        <item>
            <title>Inquiline $VERSION</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>https://github.com/inquiline-app/inquiline/releases/tag/v$VERSION</sparkle:releaseNotesLink>
            <enclosure url=\"https://github.com/inquiline-app/inquiline/releases/download/v$VERSION/$(basename "$DMG")\" $SIGNATURE type=\"application/octet-stream\"/>$DELTAS
        </item>"
[ -f appcast.xml ] || cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Inquiline</title>
    </channel>
</rss>
XML
# Newest first.
ITEM="$ITEM" python3 -c '
import os; p="appcast.xml"; s=open(p).read()
s=s.replace("        <title>Inquiline</title>\n","        <title>Inquiline</title>\n"+os.environ["ITEM"]+"\n",1)
open(p,"w").write(s)'
echo "Added Inquiline $VERSION (build $BUILD) to appcast.xml"
echo "After uploading the disk image to the release, run Scripts/update-cask.sh for Homebrew."
