#!/bin/bash
# Brings the packed disk in .build/vm up to the current disk-update.tar, before a release,
# as Waydroid and Cuttlefish ship images that are already current: a new install then
# starts Android right away, without updating its disk first (AndroidRuntime.updateDiskIfNeeded).
# Usage: refresh-disk.sh revision   (AndroidRuntime.diskRevision)
set -euo pipefail
REVISION=$1
cd "$(dirname "$0")/../.."
VM=.build/vm
ENGINE="build/Inquiline.app/Contents/MacOS/Inquiline Engine"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 -I - "$VM/android-disk.json" "$VM/android-disk.xz" "$WORK/disk.img" <<'PY'
import json, lzma, os, sys
index, payload, disk = sys.argv[1:]
index = json.load(open(index))
with open(payload, "rb") as source, open(disk, "wb") as out:
    out.truncate(index["size"])
    for chunk in index["chunks"]:
        data, position = lzma.decompress(source.read(chunk["packed"])), 0
        for offset, length in chunk["extents"]:
            out.seek(offset)
            out.write(data[position:position + length])
            position += length
PY

# The same offline update the app runs, then fstrim, so the blocks the replaced files
# held go back to holes and don't grow the package.
"$ENGINE" -M virt,highmem=on,highmem-mmio-size=16G -accel hvf -cpu host -smp 2 -m 512 \
  -kernel "$VM/vmlinux" \
  -append 'root=/dev/vda rw quiet console=ttyAMA0 init=/bin/sh -- -c "mount -t devtmpfs dev /dev 2>/dev/null; tar -xf /dev/vdb -C / && sh /disk-update.sh && echo INQUILINE-UPDATED; rm -f /disk-update.sh; sync; fstrim -v /; sync; poweroff -f"' \
  -drive "if=virtio,format=raw,file=$WORK/disk.img,discard=unmap" \
  -drive "if=virtio,format=raw,file=$VM/disk-update.tar,readonly=on" \
  -nic none -display none -serial stdio -monitor none | tee "$WORK/console" | grep -E "UPDATED|trimmed" || true
grep -q INQUILINE-UPDATED "$WORK/console" || { echo "The update failed." >&2; exit 1; }

python3 -I Scripts/vm/pack-disk.py "$WORK/disk.img" "$WORK/android-disk.json" "$WORK/android-disk.xz" 64 "$REVISION"
mv "$WORK/android-disk.json" "$WORK/android-disk.xz" "$VM/"
