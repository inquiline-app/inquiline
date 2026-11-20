import CoreMedia
import Foundation
import Security
import VideoToolbox

/// Android's video decoders, as a phone maker's are its own chip's: Inquiline's decoders in
/// Android (Vendor/c2) hand each video they are given to the Mac, which decodes it with its own
/// hardware, VideoToolbox, and writes each picture straight into the GPU buffer Android shows
/// it from, through the VM's frame server. So videos play at the sizes a phone plays them, 4K
/// too, without Android's processors decoding them.
///
/// Android reaches it at 10.0.2.2, the Mac as the VM's network sees it, with the port and a
/// token Inquiline leaves where only the decoders' service reads them.
final class VideoDecoders {
    static let shared = VideoDecoders()

    private let token: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes
    }()
    private var listener: Int32 = -1
    private(set) var port: UInt16 = 0

    /// What Android's decoders read: the port and the token, in hex.
    var key: String { "\(port) " + token.map { String(format: "%02x", $0) }.joined() }

    /// Listens on the Mac's own loopback only, where the VM's network reaches it.
    func start() {
        guard listener < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound, listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [listener] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                var on: Int32 = 1
                setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { DecodeSession(socket: client, token: self.token).run() }
            }
        }
    }
}

/// One of Android's decoders, for as long as it lives: its video's pictures decoded in turn,
/// held until Android gives a buffer for each, in the order they are shown.
private final class DecodeSession {
    private let socket: Int32
    private let token: [UInt8]
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    /// Pictures decoded but not yet shown, which a later one may still come before.
    private var waiting: [(index: UInt64, time: Int64, image: CVPixelBuffer?)] = []
    /// Pictures Android was told of, waiting for its buffers.
    private var held: [UInt64: CVPixelBuffer] = [:]
    /// How many pictures may come before one decoded earlier.
    private var reorderDepth = 4
    private var frames: Int32 = -1
    private var memory: UnsafeMutableRawPointer?
    private var memorySize = 0

    init(socket: Int32, token: [UInt8]) {
        self.socket = socket
        self.token = token
    }

    func run() {
        defer {
            if let session { VTDecompressionSessionInvalidate(session) }
            if let memory { munmap(memory, memorySize) }
            if frames >= 0 { close(frames) }
            close(socket)
        }
        guard let hello = receive(37), hello.prefix(4) == Data("IQC1".utf8),
              same(Array(hello[4..<36]), token), hello[36] == 1
        else { return }
        guard send(Data([0])) else { return }
        while let request = receive(1)?.first {
            switch request {
            case UInt8(ascii: "D"):
                guard let head = receive(24) else { return }
                let index = head.load(at: 0, as: UInt64.self)
                let time = head.load(at: 8, as: Int64.self)
                let flags = head.load(at: 16, as: UInt32.self)
                let size = Int(head.load(at: 20, as: UInt32.self))
                guard size <= 64 << 20, let data = size > 0 ? receive(size) : Data() else { return }
                decode(data, index: index, time: time, configOnly: flags & 1 != 0)
                guard answer(ready(all: false)) else { return }
            case UInt8(ascii: "E"):
                if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
                guard answer(ready(all: true)) else { return }
            case UInt8(ascii: "F"):
                waiting = []
                held = [:]
                guard answer([]) else { return }
            case UInt8(ascii: "P"):
                guard let request = receive(20) else { return }
                let index = request.load(at: 0, as: UInt64.self)
                let resource = request.load(at: 8, as: UInt32.self)
                let width = Int(request.load(at: 12, as: UInt32.self))
                let height = Int(request.load(at: 16, as: UInt32.self))
                let image = held.removeValue(forKey: index)
                let written = image.map { write($0, into: resource, width: width, height: height) } ?? false
                guard send(Data([written ? 0 : 1])) else { return }
            default:
                return
            }
        }
    }

    // MARK: - Decoding (H.264)

    /// One access unit as Android gives it, NAL units with start codes.
    private func decode(_ data: Data, index: UInt64, time: Int64, configOnly: Bool) {
        var units: [Data] = []
        var sets: [Data] = []
        for unit in Self.units(of: data) {
            switch unit.first.map({ $0 & 0x1f }) {
            case 7, 8: sets.append(unit)
            case 9, nil: break
            default: units.append(unit)
            }
        }
        if !sets.isEmpty {
            let sps = sets.filter { $0.first! & 0x1f == 7 }.first ?? parameterSets.first { $0.first! & 0x1f == 7 }
            let pps = sets.filter { $0.first! & 0x1f == 8 }.first ?? parameterSets.first { $0.first! & 0x1f == 8 }
            let new = [sps, pps].compactMap { $0 }
            if new != parameterSets {
                parameterSets = new
                makeSession()
            }
        }
        guard !configOnly, !units.isEmpty else {
            if !configOnly { waiting.append((index, time, nil)) }
            return
        }
        guard let session, let format else {
            waiting.append((index, time, nil))
            return
        }
        var sample = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            withUnsafeBytes(of: UInt32(unit.count).bigEndian) { sample.append(contentsOf: $0) }
            sample.append(unit)
        }
        var image: CVPixelBuffer?
        if let buffer = Self.sampleBuffer(sample, format: format, time: time) {
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) { status, _, decoded, _, _ in
                if status == noErr { image = decoded }
            }
        }
        waiting.append((index, time, image))
    }

    private func makeSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        guard parameterSets.count == 2 else { return }
        let sps = parameterSets[0]
        // Baseline streams show each picture as it comes; others may hold some back.
        reorderDepth = sps.count > 1 && sps[sps.startIndex + 1] == 66 ? 0 : 4
        var description: CMVideoFormatDescription?
        let pointers = parameterSets.map { ($0 as NSData).bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = parameterSets.map(\.count)
        CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        guard let description else { return }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var made: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                                     decoderSpecification: specification as CFDictionary,
                                     imageBufferAttributes: attributes as CFDictionary,
                                     outputCallback: nil, decompressionSessionOut: &made)
        if let made {
            VTSessionSetProperty(made, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        session = made
        format = description
    }

    /// Pictures whose turn has come, in the order they are shown; all of them at the end.
    private func ready(all: Bool) -> [(UInt64, Int, Int)] {
        var out: [(UInt64, Int, Int)] = []
        // An input that made no picture is done at once.
        for entry in waiting where entry.image == nil { out.append((entry.index, 0, 0)) }
        waiting.removeAll { $0.image == nil }
        waiting.sort { $0.time < $1.time }
        while !waiting.isEmpty, all || waiting.count > reorderDepth {
            let entry = waiting.removeFirst()
            guard let image = entry.image else { continue }
            held[entry.index] = image
            out.append((entry.index, CVPixelBufferGetWidth(image) & ~1, CVPixelBufferGetHeight(image) & ~1))
        }
        return out
    }

    // MARK: - Writing pictures into Android's buffers

    /// The picture as YV12 laid out as Android lays it out (its rows 32-byte aligned, Cr before
    /// Cb), written into the virtio-gpu resource by the VM's frame server.
    private func write(_ image: CVPixelBuffer, into resource: UInt32, width: Int, height: Int) -> Bool {
        let yStride = (width + 31) & ~31
        let cStride = yStride / 2
        let ySize = yStride * height
        let cSize = cStride * (height / 2)
        let size = ySize + 2 * cSize
        guard size > 0, share(size) , let memory else { return false }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard CVPixelBufferGetPlaneCount(image) == 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(image, 1)
        else { return false }
        let rows = min(height, CVPixelBufferGetHeightOfPlane(image, 0))
        let columns = min(width, CVPixelBufferGetWidthOfPlane(image, 0))
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let out = memory.assumingMemoryBound(to: UInt8.self)
        for row in 0..<rows {
            memcpy(out + row * yStride, lumaBase + row * lumaStride, columns)
        }
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        let cr = out + ySize
        let cb = out + ySize + cSize
        let chromaRows = min(height / 2, CVPixelBufferGetHeightOfPlane(image, 1))
        let chromaColumns = min(width / 2, CVPixelBufferGetWidthOfPlane(image, 1))
        for row in 0..<chromaRows {
            let line = chroma + row * chromaStride
            let crLine = cr + row * cStride
            let cbLine = cb + row * cStride
            for column in 0..<chromaColumns {
                cbLine[column] = line[2 * column]
                crLine[column] = line[2 * column + 1]
            }
        }
        var request = Data([UInt8(ascii: "U")])
        withUnsafeBytes(of: resource.littleEndian) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(0).littleEndian) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(size).littleEndian) { request.append(contentsOf: $0) }
        return ask(request)
    }

    /// Shared memory with the VM's frame server, at least `size` bytes, as the windows have.
    private func share(_ size: Int) -> Bool {
        if memory != nil, memorySize >= size { return true }
        if let memory { munmap(memory, memorySize) }
        memory = nil
        memorySize = 0
        var request = Data([UInt8(ascii: "M")])
        withUnsafeBytes(of: UInt64(size).littleEndian) { request.append(contentsOf: $0) }
        guard ask(request) else { return false }
        var length: UInt16 = 0
        guard recv(frames, &length, 2, MSG_WAITALL) == 2 else { return false }
        var name = [CChar](repeating: 0, count: Int(UInt16(littleEndian: length)) + 1)
        guard recv(frames, &name, name.count - 1, MSG_WAITALL) == name.count - 1 else { return false }
        typealias Open = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else { return false }
        let fd = unsafeBitCast(symbol, to: Open.self)(name, O_RDWR)
        shm_unlink(name)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else { return false }
        memory = mapped
        memorySize = size
        return true
    }

    private func ask(_ request: Data) -> Bool {
        if frames < 0 { frames = Self.connect(to: AndroidRuntime.shared.framesSocket.path) }
        guard frames >= 0 else { return false }
        let sent = request.withUnsafeBytes { Darwin.send(frames, $0.baseAddress!, $0.count, 0) }
        var status: UInt8 = 1
        guard sent == request.count, recv(frames, &status, 1, MSG_WAITALL) == 1 else {
            close(frames)
            frames = -1
            return false
        }
        return status == 0
    }

    private static func connect(to path: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - The connection

    private func answer(_ pictures: [(UInt64, Int, Int)]) -> Bool {
        var out = Data()
        withUnsafeBytes(of: UInt32(pictures.count).littleEndian) { out.append(contentsOf: $0) }
        for (index, width, height) in pictures {
            withUnsafeBytes(of: index.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(width).littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(height).littleEndian) { out.append(contentsOf: $0) }
        }
        return send(out)
    }

    private func receive(_ count: Int) -> Data? {
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { recv(socket, $0.baseAddress!, count, MSG_WAITALL) }
        return got == count ? data : nil
    }

    private func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { Darwin.send(socket, $0.baseAddress!, $0.count, 0) } == data.count
    }

    /// Compares in the same time whatever the bytes, so the token can't be guessed by timing.
    private func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// NAL units between Annex B start codes.
    private static func units(of data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return bytes.isEmpty ? [] : [data] }
        var units: [Data] = []
        for (n, start) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1].0 : bytes.count
            while end > start.1, bytes[end - 1] == 0 { end -= 1 }
            if end > start.1 { units.append(Data(bytes[start.1..<end])) }
        }
        return units
    }

    private static func sampleBuffer(_ sample: Data, format: CMVideoFormatDescription, time: Int64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: sample.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block
        else { return nil }
        sample.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: time, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = sample.count
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &buffer)
        return buffer
    }
}

private extension Data {
    func load<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
        let bytes = subdata(in: (startIndex + offset)..<(startIndex + offset + MemoryLayout<T>.size))
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        return T(littleEndian: value)
    }
}
