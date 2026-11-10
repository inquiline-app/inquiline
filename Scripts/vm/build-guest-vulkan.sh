#!/bin/bash
# Builds Android's Vulkan driver, .build/guest-vulkan/vulkan.gfxstream.so: Mesa's gfxstream guest
# driver, which sends Vulkan to the Mac (see build-qemu.sh). Android's GLES is ANGLE on it.
# Takes Mesa 26.2.5's source; Research/linux-gpu/android-aarch64.ini names the NDK.
# Upstream builds this driver for Android only inside AOSP, so guest-headers holds the few
# Android headers it needs that the NDK lacks, and patches/mesa trims it to minigbm on virtio-gpu.
set -euo pipefail

MESA=$1
cd "$(dirname "$0")/../.."
ROOT=$PWD
BUILD=$ROOT/.build/guest-vulkan
HEADERS=$ROOT/Scripts/vm/guest-headers
rm -rf "$BUILD"
mkdir -p "$BUILD/pkgconfig"

patch=$ROOT/Scripts/vm/patches/mesa/0100-gfxstream-Vulkan-for-Redroid.patch
patch -d "$MESA" -p1 -R --dry-run -s -f < "$patch" >/dev/null 2>&1 || patch -d "$MESA" -p1 -s < "$patch"

# The driver asks for AOSP's libraries by pkg-config name; all it uses of them is in guest-headers.
for name in android-base android-arect android-aemu-base android-aemu-gl-codec android-aemu-qemupipe \
    android-aemu-ringbuffer android-aemu-rc-encoder android-utils android-minigbm-headers \
    android-nativebase-headers android-aemu-gralloc-headers; do
    printf 'Name: %s\nDescription: stub\nVersion: 1\nCflags: -I%s\nLibs:\n' "$name" "$HEADERS" > "$BUILD/pkgconfig/$name.pc"
done
printf '#!/bin/sh\nPKG_CONFIG_LIBDIR=%s exec /opt/homebrew/bin/pkg-config "$@"\n' "$BUILD/pkgconfig" > "$BUILD/pkg-config"
chmod +x "$BUILD/pkg-config"
# AOSP defines ANDROID; the NDK only __ANDROID__.
sed -e "s#pkg-config = .*#pkg-config = '$BUILD/pkg-config'#" \
    -e "s#^cpp_link_args = .*#&\nc_args = ['-DANDROID']\ncpp_args = ['-DANDROID']#" \
    Research/linux-gpu/android-aarch64.ini > "$BUILD/cross.ini"

(cd "$MESA" && meson setup "$BUILD/mesa" --cross-file "$BUILD/cross.ini" -Dplatforms=android -Dplatform-sdk-version=35 \
    -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=gfxstream -Dallow-fallback-for=libdrm -Dllvm=disabled \
    -Dgbm=disabled -Dopengl=false -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dglx=disabled \
    -Dbuildtype=release -Db_ndebug=true)
ninja -C "$BUILD/mesa" src/gfxstream/guest/vulkan/libvulkan_gfxstream.so
STRIP=$(sed -n "s/^strip = '\(.*\)'/\1/p" Research/linux-gpu/android-aarch64.ini)
# build-disk.sh takes it with the other guest libraries.
"$STRIP" -o "$BUILD/vulkan.gfxstream.so" "$BUILD/mesa/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so"
ls -la "$BUILD/vulkan.gfxstream.so"
