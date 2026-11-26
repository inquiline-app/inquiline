#!/bin/bash
# Builds Android's sensors, .build/guest-sensors/inquiline-sensors (Vendor/sensors): AOSP's
# example sensors HAL (hardware/interfaces/sensors/aidl/default, Apache 2.0), version 2 of its
# frozen interface, with an accelerometer and a gyroscope the Mac moves (Motion.h): a game
# controller's motion, or a phone's, so games steer and aim by tilting as on a phone.
#   NDK, AOSP headers and Android's own libraries: as build-guest-c2.sh (.build/tools)
#   AIDL: the SDK build-tools 34 (Android 14), as build-guest-gnss.sh
# libfmq's queues take C++ types across their interface, so this is built for Android's own
# libc++ (std::__1) and linked against Android's libraries, as the video decoders are.
set -euo pipefail
cd "$(dirname "$0")/../.."
T=.build/tools
NDK=${NDK:-$T/ndk}
BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
AO=$T/aosp
AIDL=${AIDL:-${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/build-tools/34.0.0/aidl}
OUT=.build/guest-sensors
API=Vendor/sensors/aidl
rm -rf "$OUT"
mkdir -p "$OUT/gen/src" "$OUT/gen/include" "$T/platform-cxx"
sed 's/#define _LIBCPP_ABI_NAMESPACE __ndk1/#define _LIBCPP_ABI_NAMESPACE __1/' \
    "$BIN/../sysroot/usr/include/c++/v1/__config_site" > "$T/platform-cxx/__config_site"
gen() { # package folder, version, hash file
    "$AIDL" --lang=ndk --structured --stability=vintf --version="$2" --hash="$(tail -1 "Vendor/sensors/hashes/$3")" \
        -I "$API" -o "$OUT/gen/src" -h "$OUT/gen/include" $(find "$API/$1" -maxdepth 1 -name '*.aidl')
}
gen android/hardware/sensors 2 sensors
gen android/hardware/common/fmq 1 fmq
gen android/hardware/common 2 common
INCLUDES=(
    -isystem "$T/platform-cxx" -IVendor/sensors -IVendor/sensors/include -I"$OUT/gen/include"
    -I"$AO/frameworks/native/libs/binder/ndk/include_cpp" -I"$AO/frameworks/native/libs/binder/ndk/include_platform"
    -I"$AO/frameworks/native/libs/binder/ndk/include_ndk"
    -I"$AO/system/libbase/include" -I"$AO/system/core/libutils/include" -I"$AO/system/core/libcutils/include"
    -I"$AO/system/core/libsystem/include" -I"$AO/system/logging/liblog/include" -I"$AO/system/libfmq/include"
    -I"$AO/hardware/libhardware_legacy/include" -I"$AO/system/libhidl/base/include"
)
LIBS=(libfmq.so libbase.so libbinder_ndk.so liblog.so libutils.so libcutils.so libpower.so libc++.so)
"$BIN/aarch64-linux-android35-clang++" -std=c++20 -O2 -Wall -Wno-unused-parameter -DBINDER_STABILITY_SUPPORT \
    -nostdlib++ "${INCLUDES[@]}" Vendor/sensors/*.cpp $(find "$OUT/gen/src" -name '*.cpp') -o "$OUT/inquiline-sensors" \
    $(printf "$T/sysroot/%s " "${LIBS[@]}") -Wl,--allow-shlib-undefined
"$BIN/llvm-strip" "$OUT/inquiline-sensors"
ls -la "$OUT/inquiline-sensors"
