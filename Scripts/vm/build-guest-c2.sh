#!/bin/bash
# Builds Inquiline's video decoders for Android (Vendor/c2): a Codec2 component store, as a phone
# maker's hardware decoders are, whose components hand video to the Mac to decode.
#   NDK: .build/tools/ndk (Android NDK r28c), or NDK=<its folder>
#   AOSP: .build/tools/aosp, the headers it takes from Android 15 (android15-qpr2-release):
#         frameworks/av media/codec2 and module/foundation, frameworks/native binder and ui,
#         system/core, system/logging, system/libbase, system/libfmq
#   GEN: .build/tools/gen, NDK code for android.hardware.media.c2 V1, from its frozen AIDL
#   SYSROOT: .build/tools/sysroot, Android's own libraries to link against, pulled from it
# Android's codec libraries take C++ types across their interface, so this is built for
# Android's own libc++ (std::__1), not the NDK's (std::__ndk1), and linked against Android's.
set -euo pipefail
cd "$(dirname "$0")/../.."
T=.build/tools
NDK=${NDK:-$T/ndk}
BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
AO=$T/aosp
FAV=$AO/frameworks/av/media
OUT=.build/guest-c2
mkdir -p "$OUT" "$T/platform-cxx"
sed 's/#define _LIBCPP_ABI_NAMESPACE __ndk1/#define _LIBCPP_ABI_NAMESPACE __1/' \
    "$BIN/../sysroot/usr/include/c++/v1/__config_site" > "$T/platform-cxx/__config_site"
INCLUDES=(
    -isystem "$T/platform-cxx"
    -I"$FAV/codec2/core/include" -I"$FAV/codec2/vndk/include" -I"$FAV/codec2/components/base/include"
    -I"$FAV/codec2/hal/aidl/include" -I"$FAV/codec2/hal/common/include" -I"$FAV/module/foundation/include"
    -I"$T/gen/include"
    -I"$AO/frameworks/native/libs/binder/ndk/include_cpp" -I"$AO/frameworks/native/libs/binder/ndk/include_platform"
    -I"$AO/frameworks/native/libs/binder/ndk/include_ndk"
    -I"$AO/system/libbase/include" -I"$AO/system/core/libutils/include" -I"$AO/system/core/libcutils/include"
    -I"$AO/system/core/libsystem/include" -I"$AO/system/logging/liblog/include"
    -I"$AO/frameworks/native/libs/ui/include" -I"$AO/frameworks/native/libs/nativebase/include"
    -I"$AO/frameworks/native/libs/nativewindow/include" -I"$AO/system/libfmq/include" -I"$AO/hardware/libhardware/include" -I"$AO/system/libhidl/base/include" -I"$AO/system/libhwbinder/include" -I"$AO/system/libhidl/transport/include"
)
LIBS=(libcodec2_aidl.so libcodec2_vndk.so libcodec2_soft_common.so libstagefright_foundation.so libbase.so
      android.hardware.media.c2-V1-ndk.so libbinder_ndk.so liblog.so libutils.so libcutils.so libc++.so)
"$BIN/aarch64-linux-android35-clang++" -std=c++20 -O2 -fno-rtti -fno-exceptions -Wall -Wno-unused-parameter -DBINDER_STABILITY_SUPPORT \
    -nostdlib++ "${INCLUDES[@]}" Vendor/c2/store.cpp -o "$OUT/inquiline-c2" \
    $(printf "$T/sysroot/%s " "${LIBS[@]}") -Wl,--allow-shlib-undefined
"$BIN/llvm-strip" "$OUT/inquiline-c2"
echo "Built $OUT/inquiline-c2"
