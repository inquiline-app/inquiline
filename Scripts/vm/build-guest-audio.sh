#!/bin/bash
# Builds Android's audio HAL, .build/guest-audio/audio.primary.redroid.so: AOSP's stub HAL
# playing and recording through the VM's virtio-sound card (Vendor/audio). build-disk.sh
# takes it with the other guest libraries. Research/linux-gpu/android-aarch64.ini names the NDK.
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT=.build/guest-audio
mkdir -p "$OUT"
# The NDK the other guest parts build with (build-guest-c2.sh), else the one Research's ini names.
NDK=.build/tools/ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin
if [ -x "$NDK/aarch64-linux-android35-clang" ]; then
    CC=$NDK/aarch64-linux-android35-clang STRIP=$NDK/llvm-strip
else
    CC=$(sed -n "s/^c = '\(.*\)'/\1/p" Research/linux-gpu/android-aarch64.ini)
    STRIP=$(sed -n "s/^strip = '\(.*\)'/\1/p" Research/linux-gpu/android-aarch64.ini)
fi
"$CC" -shared -fPIC -O2 -Wno-unused-parameter -IVendor/audio/include -IVendor/audio/tinyalsa/include \
    -o "$OUT/audio.primary.redroid.so" Vendor/audio/audio_hw.c Vendor/audio/tinyalsa/pcm.c Vendor/audio/tinyalsa/limits.c -llog
"$STRIP" "$OUT/audio.primary.redroid.so"
ls -la "$OUT/audio.primary.redroid.so"
