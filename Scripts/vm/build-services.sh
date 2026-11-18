#!/bin/bash
# Builds Android's system services with Inquiline's changes (Vendor/services/<dex>.patch) and
# their precompiled code, into .build/vm/services: services.jar and oat-arm64, which the disk
# binds over /system/framework/services.jar and /system/framework/oat/arm64 (build-disk.sh).
#
# What changes, in Android's window manager, so that Android's assistant (Gemini) works over an
# app in its own window as on a phone, where the app is on the one screen:
#   - the assistant's screens open on the screen in focus, the app's window, not the main screen
#     (TaskLaunchParamsModifier.getPreferredLaunchTaskDisplayArea);
#   - its screenshot is of the screen in focus (WindowManagerService.takeAssistScreenshot);
#   - that screen's own power counts, not the main screen's, which nothing shows, and its
#     screenshot is taken though Inquiline's screens are marked secure, unless an app's secure
#     screen shows, as such screens come out black on a phone (DisplayContent.getLayerCaptureArgs);
#   - recording the whole screen (Gemini Live's screen sharing) records the app's screen
#     (ContentRecorder), and a recording stays on though the main screen is off
#     (DisplayManagerService.createVirtualDisplayLocked);
#   - the assistant's own window (Gemini Live's bar) shows on the screen of the app in use, moved
#     there each time it shows (VoiceInteractionSessionConnection.showLocked), and outlives that
#     screen when its window closes (DisplayContent.removeImmediately).
#
# Changing services.jar invalidates the image's precompiled code for it and for the system
# server jars compiled against it, so all of them are compiled again with Android's own dex2oat,
# with the filters, profile and class loader contexts the image used (Vendor/services/compile.sh).
# That runs inside a running Android: start Inquiline, run Scripts' debug adb bridge on
# 127.0.0.1:5556, then this. Needs Java 17 and the smali tools (TOOLS: a folder with
# smali-baksmali, smali, smali-dexlib2, smali-util 3.0.10 and their libraries from Maven).
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT=.build/vm/services
TOOLS=${TOOLS:?a folder with the smali tools}
ADB=${ADB:-adb}
DEVICE=${DEVICE:-127.0.0.1:5556}
BUILD_TOOLS=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/build-tools/36.0.0
CP=$(ls "$TOOLS"/*.jar | tr '\n' ':')
adb() { "$ADB" -s "$DEVICE" "$@"; }
"$ADB" disconnect >/dev/null 2>&1 || true
"$ADB" connect "$DEVICE" >/dev/null

rm -rf "$OUT" && mkdir -p "$OUT/work"
W=$OUT/work
# The image's own services.jar: the one Android runs, unless an earlier build is bound over it.
adb shell "su 0 sh -c 'umount -l /system/framework/services.jar /system/framework/oat/arm64 2>/dev/null; true'"
adb pull /system/framework/services.jar "$W/original.jar" >/dev/null

mkdir -p "$W/jar" && (cd "$W/jar" && unzip -q ../original.jar)
for patch in Vendor/services/*.patch; do
    dex=$(basename "$patch" .patch)
    java -cp "$CP" com.android.tools.smali.baksmali.Main d "$W/original.jar/$dex.dex" -o "$W/$dex"
    # -p1 into the folder: given both paths, patch would change the first, the original's files.
    patch -s -p1 -d "$W/$dex" < "$patch"
    # Dex 039, as the image's: Android 15 reads its other dex files as that version.
    java -cp "$CP" com.android.tools.smali.smali.Main a "$W/$dex" -o "$W/jar/$dex.dex" --api 29
done
(cd "$W/jar" && zip -q -0 -X ../patched.jar classes*.dex && zip -q -X -r ../patched.jar . -x 'classes*.dex')
"$BUILD_TOOLS/zipalign" -f -p 4 "$W/patched.jar" "$OUT/services.jar"

# Precompiled inside Android, against the patched jar.
adb push "$OUT/services.jar" /data/local/tmp/inquiline-services.jar >/dev/null
adb push Vendor/services/compile.sh /data/local/tmp/inquiline-compile.sh >/dev/null
# The image's profile names the original's dex files by checksum: it goes over to the patched
# jar through its text form, the methods it lists.
adb shell "su 0 sh -c 'cd /data/local/tmp && P=/apex/com.android.art/bin/profman \
    && \$P --dump-classes-and-methods --profile-file=/system/framework/services.jar.prof \
        --apk=/system/framework/services.jar --dex-location=/system/framework/services.jar > inquiline-profile.txt \
    && \$P --create-profile-from=inquiline-profile.txt --apk=inquiline-services.jar \
        --dex-location=/system/framework/services.jar --reference-profile-file=inquiline-services.prof \
    && chmod 644 inquiline-services.prof'"
adb shell "su 0 sh -c 'chmod 644 /data/local/tmp/inquiline-services.jar; \
    mount --bind /data/local/tmp/inquiline-services.jar /system/framework/services.jar && \
    sh /data/local/tmp/inquiline-compile.sh && umount -l /system/framework/services.jar; \
    cd /data/local/tmp && tar -cf inquiline-oat.tar oat-arm64'"
adb pull /data/local/tmp/inquiline-oat.tar "$W/oat.tar" >/dev/null
tar -xf "$W/oat.tar" -C "$OUT"
adb shell "su 0 rm -rf /data/local/tmp/inquiline-profile.txt /data/local/tmp/inquiline-services.prof /data/local/tmp/inquiline-services.jar /data/local/tmp/inquiline-compile.sh /data/local/tmp/inquiline-oat.tar /data/local/tmp/oat-arm64"
rm -rf "$W"
du -sh "$OUT"/*
