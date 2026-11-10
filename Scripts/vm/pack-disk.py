"""Packs a sparse disk for VMInstaller: its data, cut into separately compressed chunks
so they unpack on every core, and an index saying where each chunk's bytes belong.
Usage: pack-disk.py disk index payload [chunk_mib]"""
import json, lzma, os, sys
from concurrent.futures import ThreadPoolExecutor

source, index, payload = sys.argv[1:4]
CHUNK = int(sys.argv[4] if len(sys.argv) > 4 else 32) << 20
BLOCK = 1 << 20

fd = os.open(source, os.O_RDONLY)
size = os.fstat(fd).st_size


def data_blocks():
    """Yields (offset, bytes) for each block that holds data. All-zero blocks stay holes."""
    pos = 0
    while pos < size:
        try:
            start = os.lseek(fd, pos, os.SEEK_DATA)
        except OSError:
            return
        end = os.lseek(fd, start, os.SEEK_HOLE)
        os.lseek(fd, start, os.SEEK_SET)
        while start < end:
            block = os.read(fd, min(BLOCK, end - start))
            if block.count(0) != len(block):
                yield start, block
            start += len(block)
        pos = end


def chunks():
    extents, parts, length = [], [], 0
    for offset, block in data_blocks():
        if extents and extents[-1][0] + extents[-1][1] == offset:
            extents[-1][1] += len(block)
        else:
            extents.append([offset, len(block)])
        parts.append(block)
        length += len(block)
        if length >= CHUNK:
            yield extents, b"".join(parts), length
            extents, parts, length = [], [], 0
    if parts:
        yield extents, b"".join(parts), length


def compress(chunk):
    extents, data, length = chunk
    return extents, length, lzma.compress(data, preset=9 | lzma.PRESET_EXTREME)


entries = []
with open(payload, "wb") as out, ThreadPoolExecutor(os.cpu_count()) as pool:
    for extents, length, packed in pool.map(compress, chunks()):
        out.write(packed)
        entries.append({"packed": len(packed), "length": length, "extents": extents})
with open(index, "w") as out:
    json.dump({"size": size, "chunks": entries}, out)
print("chunks", len(entries), "data_MB", sum(e["length"] for e in entries) // 1000000,
      "payload_MB", sum(e["packed"] for e in entries) // 1000000)
