#!/bin/bash
# Builds build/Inquiline.app and, with --zip and --dmg, the release archive and disk image. It needs the
# VM's parts in .build/vm, from Scripts/vm/collect-parts.sh, then Scripts/vm/build-qemu.sh
# and Scripts/vm/build-moltenvk.sh, in that order (build-qemu.sh leaves no MoltenVK). The server
# in Vendor is scrcpy with Vendor/scrcpy-server.patch applied; its version must
# match ScrcpyServer.swift.
set -euo pipefail

cd "$(dirname "$0")/.."
SCRCPY_VERSION=5.0.1
CACHE=.build/scrcpy-$SCRCPY_VERSION
APP="build/Inquiline.app"
VM=.build/vm
[ -f "$VM/android-disk.xz" ] || { echo "Missing $VM: run Scripts/vm/collect-parts.sh first." >&2; exit 1; }
[ -f "$VM/qemu/qemu" ] || { echo "Missing $VM/qemu: run Scripts/vm/build-qemu.sh first." >&2; exit 1; }
# Without it the engine waits forever for a GPU while starting.
[ -f "$VM/qemu/vulkan/MoltenVK_icd.json" ] || { echo "Missing MoltenVK: run Scripts/vm/build-moltenvk.sh." >&2; exit 1; }

mkdir -p "$CACHE"
[ -f "$CACHE/LICENSE" ] || curl -fsSL -o "$CACHE/LICENSE" \
    "https://raw.githubusercontent.com/Genymobile/scrcpy/v$SCRCPY_VERSION/LICENSE"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Inquiline "$APP/Contents/MacOS/Inquiline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Vendor/scrcpy-server "$APP/Contents/Resources/scrcpy-server"
cp Vendor/libinquiline-frames.so "$APP/Contents/Resources/libinquiline-frames.so"
cp "$CACHE/LICENSE" "$APP/Contents/Resources/scrcpy-LICENSE.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$VM/vmlinux" "$VM/android-disk.json" "$VM/android-disk.xz" "$VM/disk-update.tar" "$APP/Contents/Resources/"
cp -R "$VM/licenses" "$APP/Contents/Resources/licenses"
# The VM's engine, from Scripts/vm/build-qemu.sh.
cp "$VM/qemu/qemu" "$APP/Contents/MacOS/Inquiline Engine"
ditto "$VM/qemu/Frameworks" "$APP/Contents/Frameworks"
ditto "$VM/qemu/vulkan" "$APP/Contents/Resources/vulkan"
cp "$VM/qemu/licenses/"* "$APP/Contents/Resources/licenses/"
# What runs inside Android, and the list of everything with its source (THIRD-PARTY-NOTICES.md).
cp Resources/Licenses/* THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/licenses/"

# The app isn't signed with a paid Apple certificate, so every part is signed ad hoc.
find "$APP/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -exec codesign --force --sign - {} \;
# Sparkle, for updates, keeps its own signature: its helpers are signed by its makers.
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements Resources/qemu.entitlements "$APP/Contents/MacOS/Inquiline Engine"
codesign --force --sign - "$APP"
echo "Built $APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
for option in "$@"; do
    case "$option" in
    --zip)
        ditto -c -k --keepParent "$APP" "build/Inquiline-$VERSION-arm64.zip"
        echo "Packaged build/Inquiline-$VERSION-arm64.zip"
        ;;
    --dmg)
        # The disk image Mac apps come in: Inquiline beside a link to the Applications
        # folder, to drag it onto.
        DMG="build/Inquiline-$VERSION-arm64.dmg"
        STAGE=build/dmg
        rm -rf "$STAGE" "$DMG" build/dmg-rw.dmg
        mkdir -p "$STAGE"
        ditto "$APP" "$STAGE/Inquiline.app"
        ln -s /Applications "$STAGE/Applications"
        hdiutil create -quiet -volname Inquiline -srcfolder "$STAGE" -fs HFS+ -format UDRW build/dmg-rw.dmg
        MOUNT=$(hdiutil attach -nobrowse -noautoopen build/dmg-rw.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')
        # Finder's window for it: the two icons side by side, nothing else.
        osascript >/dev/null <<APPLESCRIPT || echo "Finder layout skipped" >&2
tell application "Finder"
    tell disk "$(basename "$MOUNT")"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, 740, 520}
        set arrangement of icon view options of container window to not arranged
        set icon size of icon view options of container window to 128
        set position of item "Inquiline.app" of container window to {140, 150}
        set position of item "Applications" of container window to {400, 150}
        close
    end tell
end tell
APPLESCRIPT
        sync
        hdiutil detach -quiet "$MOUNT"
        hdiutil convert -quiet build/dmg-rw.dmg -format ULFO -o "$DMG"
        rm -rf "$STAGE" build/dmg-rw.dmg
        echo "Packaged $DMG"
        ;;
    esac
done
