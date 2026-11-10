#!/bin/bash
# Adds the version in Resources/Info.plist to appcast.xml, the list Sparkle reads to find
# updates, after Scripts/build-app.sh --dmg. The disk image is signed with the key that
# Sparkle's generate_keys keeps in this Mac's Keychain (account "inquiline"); its public half
# is SUPublicEDKey in Info.plist. Then commit appcast.xml, and upload the disk image to the
# GitHub release v<version>.
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
ITEM="        <item>
            <title>Inquiline $VERSION</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>https://github.com/inquiline-app/inquiline/releases/tag/v$VERSION</sparkle:releaseNotesLink>
            <enclosure url=\"https://github.com/inquiline-app/inquiline/releases/download/v$VERSION/$(basename "$DMG")\" $SIGNATURE type=\"application/octet-stream\"/>
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
