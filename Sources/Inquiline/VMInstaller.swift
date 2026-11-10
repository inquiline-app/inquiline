import Compression
import Foundation

/// Unpacks Android's disk from the app bundle on first launch. Apps and their
/// data live on it, so it can't stay inside the read-only bundle. Blocks, so call
/// it off the main thread.
enum VMInstaller {
    /// Written by Scripts/vm/pack-disk.py.
    private struct Index: Decodable {
        let size: Int
        let chunks: [Chunk]
    }

    private struct Chunk: Decodable {
        let packed: Int
        let length: Int
        /// Where the chunk's bytes go on the disk, as offset and length pairs.
        /// Everything between them stays a hole, so the disk takes little real space.
        let extents: [[Int]]
    }

    static func installIfNeeded(at disk: URL) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: disk.path) else { return }
        guard let indexURL = Bundle.main.url(forResource: "android-disk", withExtension: "json"),
              let payloadURL = Bundle.main.url(forResource: "android-disk", withExtension: "xz")
        else {
            throw RuntimeError("Android is missing from the app bundle.")
        }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        let payload = try Data(contentsOf: payloadURL, options: .alwaysMapped)
        var starts = [0]
        for chunk in index.chunks { starts.append(starts.last! + chunk.packed) }

        let work = disk.deletingLastPathComponent().appendingPathComponent(".unpacking")
        try? files.removeItem(at: work)
        guard files.createFile(atPath: work.path, contents: nil) else {
            throw RuntimeError("Could not unpack Android. Check that the Mac has free disk space.")
        }
        let output = try FileHandle(forWritingTo: work)
        defer { try? output.close() }
        try output.truncate(atOffset: UInt64(index.size))

        let lock = NSLock()
        var failed = false
        DispatchQueue.concurrentPerform(iterations: index.chunks.count) { number in
            let done = unpack(index.chunks[number], from: payload[starts[number]..<starts[number + 1]], to: output.fileDescriptor)
            lock.lock()
            failed = failed || !done
            lock.unlock()
        }
        guard !failed else {
            try? files.removeItem(at: work)
            throw RuntimeError("Could not unpack Android. Check that the Mac has free disk space.")
        }
        // Moved last, so an interrupted unpack starts over on the next launch.
        try files.moveItem(at: work, to: disk)
    }

    private static func unpack(_ chunk: Chunk, from packed: Data, to descriptor: Int32) -> Bool {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk.length)
        defer { buffer.deallocate() }
        let size = packed.withUnsafeBytes { source in
            compression_decode_buffer(
                buffer, chunk.length,
                source.bindMemory(to: UInt8.self).baseAddress!, packed.count,
                nil, COMPRESSION_LZMA)
        }
        guard size == chunk.length else { return false }
        var position = 0
        for extent in chunk.extents {
            var offset = extent[0]
            var left = extent[1]
            while left > 0 {
                let count = pwrite(descriptor, buffer + position, left, off_t(offset))
                guard count > 0 else { return false }
                offset += count
                position += count
                left -= count
            }
        }
        return true
    }
}
