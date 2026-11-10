#!/bin/bash
# Gathers Android into .build/vm: the kernel the disk was built with, and a disk from
# build-disk.sh. The engine that runs it comes from build-qemu.sh.
set -euo pipefail

KERNEL=$1
DISK=$2
cd "$(dirname "$0")/../.."
OUT=.build/vm
rm -rf "$OUT/vmlinux" "$OUT/android-disk.json" "$OUT/android-disk.xz" "$OUT/licenses"
mkdir -p "$OUT/licenses"

# QEMU can't read Fedora's zstd-compressed EFI kernel, so it gets the plain one.
python3 -I - "$KERNEL" "$OUT/vmlinux.zst" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
assert data[4:8] == b"zimg" and data[24:28] == b"zstd"
offset, size = struct.unpack("<II", data[8:16])
open(sys.argv[2], "wb").write(data[offset:offset + size])
PY
zstd -dqf "$OUT/vmlinux.zst" -o "$OUT/vmlinux"
rm "$OUT/vmlinux.zst"

python3 -I Scripts/vm/pack-disk.py "$DISK" "$OUT/android-disk.json" "$OUT/android-disk.xz" 64
du -sh "$OUT/vmlinux" "$OUT/android-disk.xz"
