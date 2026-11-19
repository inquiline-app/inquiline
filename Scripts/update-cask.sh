#!/bin/bash
# Points the Homebrew cask (github.com/inquiline-app/homebrew-tap, Casks/inquiline.rb) at the
# version in Resources/Info.plist, after its disk image is uploaded to the GitHub release
# (Scripts/make-appcast.sh says when). `brew install --cask inquiline-app/tap/inquiline` then
# installs it, and `brew upgrade` finds it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
DMG="build/Inquiline-$VERSION-arm64.dmg"
[ -f "$DMG" ] || { echo "Missing $DMG." >&2; exit 1; }
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
API=repos/inquiline-app/homebrew-tap/contents/Casks/inquiline.rb
FILE=$(gh api "$API")
NEW=$(printf '%s' "$FILE" | VERSION="$VERSION" SHA="$SHA" python3 -c '
import base64, json, os, re, sys
cask = base64.b64decode(json.load(sys.stdin)["content"]).decode()
cask = re.sub(r"version \"[^\"]*\"", "version \"%s\"" % os.environ["VERSION"], cask, count=1)
cask = re.sub(r"sha256 \"[0-9a-f]*\"", "sha256 \"%s\"" % os.environ["SHA"], cask, count=1)
print(base64.b64encode(cask.encode()).decode())')
gh api -X PUT "$API" -f message="Inquiline $VERSION" -f content="$NEW" \
    -f sha="$(printf '%s' "$FILE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')" >/dev/null
echo "The cask now installs Inquiline $VERSION"
