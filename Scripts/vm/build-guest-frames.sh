#!/bin/bash
# Builds Vendor/libinquiline-frames.so, the scrcpy server's native part (Vendor/frames): it
# tells which virtio-gpu resource holds an Android buffer. Research/linux-gpu/android-aarch64.ini
# names the NDK, whose sysroot has the virtio-gpu header.
set -euo pipefail

cd "$(dirname "$0")/../.."
CC=$(sed -n "s/^c = '\(.*\)'/\1/p" Research/linux-gpu/android-aarch64.ini)
STRIP=$(sed -n "s/^strip = '\(.*\)'/\1/p" Research/linux-gpu/android-aarch64.ini)
SYSROOT=$(dirname "$(dirname "$CC")")/sysroot
"$CC" -shared -fPIC -O2 -I"$SYSROOT/usr/include/drm" -o Vendor/libinquiline-frames.so Vendor/frames/inquiline_frames.c -landroid -ldl
"$STRIP" Vendor/libinquiline-frames.so
ls -la Vendor/libinquiline-frames.so
