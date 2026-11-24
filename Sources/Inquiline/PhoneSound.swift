import AudioToolbox
import Foundation

/// Android's sound for a phone showing a window (PhoneRemote's screen): Inquiline takes it from
/// the engine and silences it on the Mac meanwhile (EngineAudio), and here it's made Opus, as
/// WebRTC carries sound, by the Mac's own encoder (AudioToolbox), in 20 ms packets.
final class PhoneSound {
    /// How the window's socket is named, so Inquiline silences the Mac while it listens.
    static let socketSuffix = "-phone.sock"

    /// An Opus packet of 20 ms (960 samples at 48 kHz) and the Mac's time at its start, in
    /// seconds (CACurrentMediaTime's clock). On the sound's thread.
    var onPacket: ((Data, Double) -> Void)?

    private var listener: Int32 = -1
    private var connection: Int32 = -1
    private var stopped = false
    private var path: String {
        AndroidRuntime.shared.home.appendingPathComponent("rec-\(ProcessInfo.processInfo.processIdentifier)\(Self.socketSuffix)").path
    }

    // The encoder and the sound waiting for it, on the sound's thread.
    private var converter: AudioConverterRef?
    private var pending: [Float] = []
    private var pendingStart = 0.0
    private var rate = 48_000.0
    private var maxPacket = 1500

    func start() {
        let path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listener = fd
        let thread = Thread { [weak self] in
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            guard let self, !self.stopped else { close(connection); return }
            self.connection = connection
            self.receive(from: connection)
        }
        thread.name = "inquiline.phone-sound"
        thread.start()
        DistributedNotificationCenter.default().postNotificationName(ScreenCapture.audioRequest, object: path,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    /// Ends listening: Inquiline sees the socket close, and the Mac plays the sound again.
    func stop() {
        stopped = true
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            close(listener)
            listener = -1
        }
        unlink(path)
    }

    // MARK: - On the sound's thread

    private func receive(from fd: Int32) {
        defer {
            close(fd)
            if let converter { AudioConverterDispose(converter) }
            converter = nil
        }
        func read(_ count: Int) -> Data? { try? ScrcpyServer.readExactly(count, from: fd) }
        guard let header = read(8) else { return }
        rate = header.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        guard rate > 0, makeConverter() else { return }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        while !stopped, let head = read(12) {
            let (hostTime, frames) = head.withUnsafeBytes {
                (UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)),
                 Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))))
            }
            // The Mac's output changed: its rate, where a time would be (EngineAudio.outputChanged).
            if frames == 0 {
                rate = Double(bitPattern: hostTime)
                pending.removeAll()
                if let converter { AudioConverterDispose(converter) }
                converter = nil
                guard rate > 0, makeConverter() else { return }
                continue
            }
            guard frames < 1 << 16, let samples = read(frames * 8) else { return }
            let time = Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
            // The waiting sound's time follows this piece's unless it drifted, as after a gap.
            let expected = pendingStart + Double(pending.count / 2) / rate
            if pending.isEmpty || abs(expected - time) > 0.1 { pendingStart = time - Double(pending.count / 2) / rate }
            samples.withUnsafeBytes { pending.append(contentsOf: $0.bindMemory(to: Float.self)) }
            encode()
        }
    }

    private func makeConverter() -> Bool {
        var input = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                 mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else {
            AppLog.write("The phone's sound: the Mac's Opus encoder didn't start")
            return false
        }
        var bitRate: UInt32 = 128_000
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var largest: UInt32 = 0
        if AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &largest) == noErr, largest > 0 {
            maxPacket = Int(largest)
        }
        return true
    }

    /// Encodes every whole packet the waiting sound makes.
    private func encode() {
        guard let converter else { return }
        // Samples of the input a 20 ms packet takes.
        let needed = Int((rate * 0.02).rounded(.up)) * 2
        while pending.count >= needed {
            var out = [UInt8](repeating: 0, count: maxPacket)
            var description = AudioStreamPacketDescription()
            var packets: UInt32 = 1
            let start = pendingStart
            let status = out.withUnsafeMutableBytes { bytes -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count),
                                                                                       mData: bytes.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, count, data, _, user in
                    let sound = Unmanaged<PhoneSound>.fromOpaque(user!).takeUnretainedValue()
                    return sound.supply(count, data)
                }, Unmanaged.passUnretained(self).toOpaque(), &packets, &list, &description)
            }
            guard packets > 0, description.mDataByteSize > 0 else {
                if status != noErr && status != Self.waiting { return }
                if pending.count < needed { return }
                continue
            }
            onPacket?(Data(out[Int(description.mStartOffset)..<Int(description.mStartOffset) + Int(description.mDataByteSize)]), start)
        }
    }

    /// The encoder's request for more sound, answered from what waits, or "wait" when nothing does.
    private static let waiting: OSStatus = 1
    private var supplied: [Float] = []

    private func supply(_ count: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = min(Int(count.pointee), pending.count / 2)
        guard frames > 0 else {
            count.pointee = 0
            return Self.waiting
        }
        supplied = Array(pending[0..<frames * 2])
        pending.removeFirst(frames * 2)
        pendingStart += Double(frames) / rate
        count.pointee = UInt32(frames)
        supplied.withUnsafeMutableBytes { bytes in
            data.pointee.mNumberBuffers = 1
            data.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
        }
        return noErr
    }
}
