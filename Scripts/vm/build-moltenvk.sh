#!/bin/bash
# Builds MoltenVK, gfxstream's Vulkan on Metal, into .build/vm/qemu/Frameworks. Its own
# SPIRV-Cross gets Scripts/vm/patches/spirv-cross, without which Metal rejects shaders that
# Android games write to output arrays (Free Fire, Asphalt). The private Metal API build adds
# what ANGLE uses for GLES 3.x, such as VK_EXT_provoking_vertex.
# Needs Xcode, which needn't be the selected developer folder. Run after build-qemu.sh.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$PWD
SRC=.build/moltenvk-src
OUT=.build/vm/qemu
VERSION=v1.4.2
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p "$SRC"

[ -d "$SRC/MoltenVK/.git" ] || git clone -q --depth 1 --branch "$VERSION" https://github.com/KhronosGroup/MoltenVK.git "$SRC/MoltenVK"
# The SPIRV-Cross revision this MoltenVK is made for, patched.
REV=$(cat "$SRC/MoltenVK/ExternalRevisions/SPIRV-Cross_repo_revision")
if [ ! -d "$SRC/SPIRV-Cross/.git" ]; then
    git clone -q https://github.com/KhronosGroup/SPIRV-Cross.git "$SRC/SPIRV-Cross"
    git -C "$SRC/SPIRV-Cross" checkout -q "$REV"
fi
for patch in "$ROOT"/Scripts/vm/patches/spirv-cross/*.patch; do
    git -C "$SRC/SPIRV-Cross" apply --reverse --check "$patch" 2>/dev/null || git -C "$SRC/SPIRV-Cross" apply "$patch"
done

# Inquiline's changes to MoltenVK itself: shaders compile at the same time.
for patch in "$ROOT"/Scripts/vm/patches/moltenvk/*.patch; do
    git -C "$SRC/MoltenVK" apply --reverse --check "$patch" 2>/dev/null || git -C "$SRC/MoltenVK" apply "$patch"
done

(cd "$SRC/MoltenVK"
 ./fetchDependencies --macos --spirv-cross-root "$ROOT/$SRC/SPIRV-Cross"
 make macos MVK_USE_METAL_PRIVATE_API=1)

rm -rf "$OUT/Frameworks/MoltenVK.framework"
cp "$SRC/MoltenVK/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$OUT/Frameworks/"
printf '{"file_format_version": "1.0.0", "ICD": {"library_path": "../../Frameworks/libMoltenVK.dylib", "api_version": "1.4.0", "is_portability_driver": true}}\n' \
    > "$OUT/vulkan/MoltenVK_icd.json"
cp "$SRC/MoltenVK/LICENSE" "$OUT/licenses/MoltenVK-LICENSE.txt"
cp "$SRC/SPIRV-Cross/LICENSE" "$OUT/licenses/SPIRV-Cross-LICENSE.txt"
ls -la "$OUT/Frameworks/libMoltenVK.dylib"
