#!/bin/bash
# Makes a test update for the Macs that try Inquiline before a release, served from this Mac
# on the local network, so they update to it as users do, downloading only what changed. Each
# is numbered after the release, 18.1, 18.2…, so the next release updates them as usual. Its
# feed is apart from users': a test Mac is pointed at it once with the command this prints.
# Run the server it prints while the test Macs update.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=.build/test-channel
FEED=$DIR/feed
SPARKLE=.build/sparkle/bin
mkdir -p "$FEED" "$DIR/apps"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
RELEASE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)
LAST=$(cat "$DIR/last" 2>/dev/null || echo "$RELEASE.0")
case $LAST in "$RELEASE".*) BUILD="$RELEASE.$(( ${LAST##*.} + 1 ))" ;; *) BUILD="$RELEASE.1"; LAST="" ;; esac

TEST_BUILD=$BUILD Scripts/build-app.sh >/dev/null
NEW=build/Inquiline.app

# What a test Mac has now: the release, or the last test update.
if [ ! -d "$DIR/apps/$RELEASE/Inquiline.app" ]; then
    DMG="build/Inquiline-$VERSION-arm64.dmg"
    [ -f "$DMG" ] || gh release download "v$VERSION" --repo inquiline-app/inquiline --pattern "$(basename "$DMG")" --dir build
    MOUNT=$(mktemp -d)
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
    mkdir -p "$DIR/apps/$RELEASE"
    ditto "$MOUNT/Inquiline.app" "$DIR/apps/$RELEASE/Inquiline.app"
    hdiutil detach -quiet "$MOUNT"
fi
rm -f "$FEED"/*
DELTAS=""
for FROM in "$RELEASE" $LAST; do
    [ -d "$DIR/apps/$FROM/Inquiline.app" ] || continue
    DELTA="$FEED/Inquiline$BUILD-$FROM.delta"
    "$SPARKLE/BinaryDelta" create "$DIR/apps/$FROM/Inquiline.app" "$NEW" "$DELTA"
    DELTAS="$DELTAS
                <enclosure url=\"$(basename "$DELTA")\" sparkle:deltaFrom=\"$FROM\" $("$SPARKLE/sign_update" --account inquiline "$DELTA") type=\"application/octet-stream\"/>"
    echo "Delta from $FROM: $(du -h "$DELTA" | cut -f1)"
done
# The whole app, for a Mac with neither.
ZIP="$FEED/Inquiline-$BUILD.zip"
ditto -c -k --keepParent "$NEW" "$ZIP"
cat > "$FEED/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Inquiline tests</title>
        <item>
            <title>Inquiline $VERSION test $BUILD</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description>A test build from $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD).</description>
            <enclosure url="$(basename "$ZIP")" $("$SPARKLE/sign_update" --account inquiline "$ZIP") type="application/octet-stream"/>
            <sparkle:deltas>$DELTAS
            </sparkle:deltas>
        </item>
    </channel>
</rss>
XML
# Kept: the release and this one, which the next test update starts from.
for OLD in "$DIR/apps"/*; do
    case $(basename "$OLD") in "$RELEASE"|"$BUILD") ;; *) rm -rf "$OLD" ;; esac
done
mkdir -p "$DIR/apps/$BUILD"
rm -rf "$DIR/apps/$BUILD/Inquiline.app"
ditto "$NEW" "$DIR/apps/$BUILD/Inquiline.app"
echo "$BUILD" > "$DIR/last"

HOST=$(scutil --get LocalHostName).local
echo "Test update $BUILD is ready."
echo "Serve it:  python3 -m http.server 8742 --directory $FEED"
echo "On a test Mac, once:  defaults write io.github.inquiline-app.Inquiline SUFeedURL http://$HOST:8742/appcast.xml"
echo "Back to releases:     defaults delete io.github.inquiline-app.Inquiline SUFeedURL"
