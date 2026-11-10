#!/bin/bash
# Builds the VM's engine into .build/vm/qemu: QEMU with rutabaga_gfx and gfxstream, which
# runs Android's Vulkan on the Mac's GPU through MoltenVK (Android's GLES is ANGLE on that
# Vulkan), which build-moltenvk.sh adds. Patches come from Scripts/vm/patches; the qemu,
# rutabaga_gfx and gfxstream ones not named 01xx are from mini-android-emulator-mac.
# Needs: brew install meson ninja rust pkgconf cmake
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$PWD
SRC=.build/qemu-src
OUT=.build/vm/qemu
PREFIX=$ROOT/$SRC/install
# Only what's built here: a library from Homebrew would be built for this Mac's own macOS.
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
mkdir -p "$SRC"

# Everything the engine ships runs on macOS 14 and later, as Inquiline does. Homebrew builds its
# libraries for the build machine's macOS, so the ones the engine needs are built here.
export MACOSX_DEPLOYMENT_TARGET=14.0
DEPS=$SRC/deps
mkdir -p "$DEPS"
# source_of <name> <url>: unpacks a release's source and applies Scripts/vm/patches/<name>,
# again from the start when those patches change.
source_of() {
    local stamp
    # Most have no patches, which cat then reports.
    stamp=$({ cat "$ROOT/Scripts/vm/patches/$1"/*.patch 2>/dev/null || true; } | shasum | cut -c1-40)
    [ "$(cat "$DEPS/$1/.inquiline-source" 2>/dev/null)" = "$stamp" ] && return
    rm -rf "${DEPS:?}/$1"
    mkdir -p "$DEPS/$1"
    curl -fsSL "$2" | tar -xf - --strip-components=1 -C "$DEPS/$1"
    for patch in "$ROOT/Scripts/vm/patches/$1"/*.patch; do
        [ -f "$patch" ] && patch -d "$DEPS/$1" -p1 -s < "$patch"
    done
    echo "$stamp" > "$DEPS/$1/.inquiline-source"
}
# Each is built again when the deployment target or its source changes.
fresh() { [ "$(cat "$DEPS/$1/.inquiline-target" 2>/dev/null)" != "$MACOSX_DEPLOYMENT_TARGET" ]; }
built() { echo "$MACOSX_DEPLOYMENT_TARGET" > "$DEPS/$1/.inquiline-target"; }
meson_dep() {
    local name=$1; shift
    fresh "$name" || return 0
    rm -rf "$DEPS/$name/build"
    (cd "$DEPS/$name" && meson setup build --buildtype=release --prefix="$PREFIX" --libdir=lib "$@" && meson install -C build --quiet)
    built "$name"
}
source_of glib https://download.gnome.org/sources/glib/2.90/glib-2.90.1.tar.xz
source_of pixman https://cairographics.org/releases/pixman-0.46.4.tar.gz
source_of libslirp https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.7/libslirp-v4.9.7.tar.gz
source_of vulkan-headers https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.363.tar.gz
source_of vulkan-loader https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/v1.4.363.tar.gz
# GLib takes PCRE2, libffi, zlib and a small libintl (proxy-libintl) into itself, so they
# aren't separate libraries.
meson_dep glib -Dforce_fallback_for=libpcre2-8,intl,libffi,zlib -Dpcre2:default_library=static \
    -Dproxy-libintl:default_library=static -Dlibffi:default_library=static -Dzlib:default_library=static \
    -Dintrospection=disabled -Dtests=false -Dnls=disabled
meson_dep pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled
meson_dep libslirp
if fresh vulkan-loader; then
    cmake -S "$DEPS/vulkan-headers" -B "$DEPS/vulkan-headers/build" -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null
    cmake --install "$DEPS/vulkan-headers/build" >/dev/null
    cmake -S "$DEPS/vulkan-loader" -B "$DEPS/vulkan-loader/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DVULKAN_HEADERS_INSTALL_DIR="$PREFIX" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DBUILD_TESTS=OFF >/dev/null
    cmake --build "$DEPS/vulkan-loader/build" -j >/dev/null
    cmake --install "$DEPS/vulkan-loader/build" >/dev/null
    built vulkan-loader
fi

# fetch <tree> <url> <commit>: clones at the pin and applies Scripts/vm/patches/<tree> in order.
# When the patches change, the tree goes back to the pin first, as later patches may build on
# earlier ones.
fetch() {
    [ -d "$SRC/$1/.git" ] || git clone -q --filter=blob:none "$2" "$SRC/$1"
    local stamp
    stamp=$(cat "$ROOT/Scripts/vm/patches/$1"/*.patch 2>/dev/null | shasum | cut -c1-40)
    [ "$(cat "$SRC/$1/.inquiline-patches" 2>/dev/null)" = "$stamp" ] && return
    git -C "$SRC/$1" reset -q --hard "$3"
    git -C "$SRC/$1" clean -qfd -e build -e build-inquiline
    for patch in "$ROOT/Scripts/vm/patches/$1"/*.patch; do
        [ -f "$patch" ] && git -C "$SRC/$1" apply "$patch"
    done
    echo "$stamp" > "$SRC/$1/.inquiline-patches"
}
fetch gfxstream https://github.com/utzcoz/gfxstream.git e9eed53d
fetch rutabaga_gfx https://github.com/magma-gpu/rutabaga_gfx.git 60603af
fetch qemu https://gitlab.com/qemu-project/qemu.git v11.1.2
# Built from scratch when the deployment target changes.
for tree in gfxstream rutabaga_gfx qemu; do
    [ "$(cat "$SRC/$tree/.inquiline-target" 2>/dev/null)" = "$MACOSX_DEPLOYMENT_TARGET" ] && continue
    rm -rf "$SRC/$tree/build" "$SRC/$tree/build-inquiline"
    echo "$MACOSX_DEPLOYMENT_TARGET" > "$SRC/$tree/.inquiline-target"
done

# QEMU_NEXT: gfxstream posts frames from its own worker; macOS would want a UI thread.
(cd "$SRC/gfxstream"
 [ -d build ] || meson setup build --buildtype=release --prefix="$PREFIX" -Dgfxstream-build=host \
     -Ddecoders=gles,vulkan,composer -Dcpp_args=-DQEMU_NEXT
 meson install -C build --quiet)
(cd "$SRC/rutabaga_gfx"
 [ -f build/build.ninja ] || meson setup build --buildtype=release --prefix="$PREFIX" -Dffi=true -Dfeatures=gfxstream
 meson install -C build --quiet)

# Only what Inquiline uses. CoreAudio plays Android's sound card (virtio-sound) on the Mac.
CONFIGURE="--target-list=aarch64-softmmu --without-default-features --enable-hvf --enable-rutabaga-gfx --enable-slirp
 --enable-fdt=internal --enable-pixman --enable-coreaudio --audio-drv-list=coreaudio --disable-pvg --disable-docs
 --disable-werror --disable-debug-info"
(cd "$SRC/qemu"
 [ "$(cat build-inquiline/.inquiline-configure 2>/dev/null)" = "$CONFIGURE" ] || {
     rm -rf build-inquiline && mkdir build-inquiline && (cd build-inquiline && ../configure $CONFIGURE)
     echo "$CONFIGURE" > build-inquiline/.inquiline-configure
 }
 ninja -C build-inquiline qemu-system-aarch64)
# QEMU gives guest memory back through memory-release.c, which Inquiline inserts when it starts QEMU.
mkdir -p "$SRC/release"
clang -dynamiclib -O2 -o "$SRC/release/libmemory-release.dylib" Scripts/vm/memory-release.c -framework Hypervisor \
    -install_name @rpath/libmemory-release.dylib

# The engine and every library it needs that macOS doesn't have, found by @rpath.
rm -rf "$OUT"
mkdir -p "$OUT/Frameworks" "$OUT/licenses"
cp "$SRC/qemu/build-inquiline/qemu-system-aarch64" "$OUT/qemu"
strip -x "$OUT/qemu"
bundle() {
    local file=$1
    otool -L "$file" | tail -n +2 | awk '{print $1}' | { grep -vE '^(/usr/lib|/System|@)' || true; } | while read -r library; do
        local name
        name=$(basename "$library")
        install_name_tool -change "$library" "@rpath/$name" "$file" 2>/dev/null
        [ -f "$OUT/Frameworks/$name" ] && continue
        cp "$library" "$OUT/Frameworks/$name"
        chmod u+w "$OUT/Frameworks/$name"
        install_name_tool -id "@rpath/$name" "$OUT/Frameworks/$name" 2>/dev/null
        bundle "$OUT/Frameworks/$name"
    done
}
cp "$SRC/release/libmemory-release.dylib" "$OUT/Frameworks/"
bundle "$OUT/qemu"
# Only the bundle: the build machine's own library folders would win over it.
otool -l "$OUT/qemu" | awk '/LC_RPATH/ {getline; getline; print $2}' | while read -r path; do
    install_name_tool -delete_rpath "$path" "$OUT/qemu"
done
install_name_tool -add_rpath @executable_path/../Frameworks "$OUT/qemu"
# gfxstream opens the Vulkan loader by name; Inquiline points it at Frameworks.
cp "$PREFIX/lib/libvulkan.1.dylib" "$OUT/Frameworks/libvulkan.dylib"
chmod u+w "$OUT/Frameworks/libvulkan.dylib"
install_name_tool -id @rpath/libvulkan.dylib "$OUT/Frameworks/libvulkan.dylib"
mkdir -p "$OUT/vulkan"

cp "$SRC/qemu/COPYING" "$OUT/licenses/qemu-COPYING.txt"
cp "$SRC/gfxstream/LICENSE" "$OUT/licenses/gfxstream-LICENSE.txt"
cp "$SRC/rutabaga_gfx/LICENSE" "$OUT/licenses/rutabaga_gfx-LICENSE.txt"
cp "$DEPS/glib/COPYING" "$OUT/licenses/glib-COPYING.txt"
cp "$DEPS/pixman/COPYING" "$OUT/licenses/pixman-COPYING.txt"
cp "$DEPS/libslirp/COPYRIGHT" "$OUT/licenses/libslirp-COPYRIGHT.txt"
cp "$DEPS/vulkan-loader/LICENSE.txt" "$OUT/licenses/vulkan-loader-LICENSE.txt"
# What GLib takes into itself.
for sub in pcre2 proxy-libintl libffi zlib; do
    for file in "$DEPS"/glib/subprojects/$sub*/{LICENCE,LICENCE.md,LICENSE,LICENSE.md,COPYING,COPYING.LIB}; do
        [ -f "$file" ] && cp "$file" "$OUT/licenses/glib-$sub-$(basename "$file" .md).txt" || true
    done
done
# Nothing shipped may call a system function newer than the deployment target. macOS links those
# weakly, and calling one on an older macOS crashes, as GLib's pipe2 did on macOS 26. Uses
# guarded by an availability check go through __availability_version_check, which is fine.
newer=$(for file in "$OUT/qemu" "$OUT"/Frameworks/*.dylib; do
    nm -m "$file" | awk -v f="$(basename "$file")" '/\(undefined\)/ && / weak / && /\(from libSystem\)/ && !/_availability_version_check / {print f": "$(NF-2)}'
done)
[ -z "$newer" ] || { echo "Calls system functions newer than macOS $MACOSX_DEPLOYMENT_TARGET:" >&2; echo "$newer" >&2; exit 1; }
du -sh "$OUT"
