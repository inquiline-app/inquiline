#!/bin/bash
# Builds Android's GPS, .build/guest-gnss/android.hardware.gnss-service.inquiline (Vendor/gnss):
# AOSP's frozen GNSS interface, version 3 (Vendor/gnss/aidl), made into NDK code by the Android
# SDK's AIDL compiler, and the service that reports the Mac's location through it.
# build-disk.sh takes it with the other guest files.
#   NDK: Research/linux-gpu/android-aarch64.ini names it, or NDK=<its folder>
#   AIDL: the SDK build-tools 34 (Android 14), whose NDK code these headers take; or AIDL=<tool>
# Vendor/gnss/include holds the header-only parts of libbinder_ndk that the NDK leaves out
# (AOSP frameworks/native/libs/binder/ndk, Apache 2.0). The service calls the few platform
# functions it needs (service manager, thread pool, VINTF stability) from Android's own
# libbinder_ndk.so, which has them; the NDK's copy, linked against, lists only the public ones,
# so a small stand-in that names them is linked instead and Android's is loaded at run time.
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT=.build/guest-gnss
rm -rf "$OUT"
mkdir -p "$OUT/gen/src" "$OUT/gen/include" "$OUT/link"
CXX=${NDK:+$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang++}
CXX=${CXX:-$(sed -n "s/^cpp = '\(.*\)'/\1/p" Research/linux-gpu/android-aarch64.ini)}
BIN=$(dirname "$CXX")
AIDL=${AIDL:-${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/build-tools/34.0.0/aidl}

API=Vendor/gnss/aidl
"$AIDL" --lang=ndk --structured --stability=vintf --version=3 --hash="$(tail -1 "$API/.hash")" \
    -I "$API" -o "$OUT/gen/src" -h "$OUT/gen/include" $(find "$API" -name '*.aidl')

# The stand-in for Android's libbinder_ndk.so, linked against in its place: every function the
# NDK's copy names, and the platform ones above.
SYSROOT="$BIN/../sysroot/usr/lib/aarch64-linux-android/35"
{
    "$BIN/llvm-nm" -D --defined-only "$SYSROOT/libbinder_ndk.so" | awk '$2 == "T" { print $3 }' | sed 's/@.*//'
    printf '%s\n' AServiceManager_addService ABinderProcess_setThreadPoolMaxThreadCount \
        ABinderProcess_startThreadPool ABinderProcess_joinThreadPool AIBinder_markVintfStability
} | sort -u | sed 's/.*/void &(void) {}/' > "$OUT/link/stand-in.c"
"$BIN/aarch64-linux-android35-clang" -shared -fPIC -o "$OUT/link/libbinder_ndk.so" \
    -Wl,-soname,libbinder_ndk.so "$OUT/link/stand-in.c"

"$CXX" -std=c++20 -O2 -Wall -Wno-unused-parameter -DBINDER_STABILITY_SUPPORT \
    -IVendor/gnss/include -I"$OUT/gen/include" \
    -o "$OUT/android.hardware.gnss-service.inquiline" Vendor/gnss/gnss.cpp $(find "$OUT/gen/src" -name '*.cpp') \
    -static-libstdc++ -L"$OUT/link" -lbinder_ndk -llog
"$BIN/llvm-strip" "$OUT/android.hardware.gnss-service.inquiline"
ls -la "$OUT/android.hardware.gnss-service.inquiline"
