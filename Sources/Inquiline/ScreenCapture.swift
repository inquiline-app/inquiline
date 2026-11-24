import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Darwin
import Metal

/// Screenshots and screen recordings of an app's Android screen alone, without the window
/// around it, saved where the Mac saves its own: Android's own pictures, at Android's size, as
/// FrameRenderer has them, so the Mac's Screen Recording permission isn't needed.
enum ScreenCapture {
    /// Where the Mac's screenshots go: the folder set in its Screenshot app, or the Desktop.
    static var folder: URL {
        let files = FileManager.default
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            var isFolder: ObjCBool = false
            if files.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue { return folder }
        }
        return files.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// "Asphalt 2026-11-20 at 02.30.15.png", as the Mac names its own, with the app's name.
    static func file(app: String, kind: String) -> URL {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(app) \(date.string(from: Date()))".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appendingPathComponent("\(name).\(kind)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(number).\(kind)")
            number += 1
        }
        return url
    }

    static func save(_ picture: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, picture, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// The Mac's own screenshot sound.
    static func playShutter() {
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
                byReference: true)?.play()
    }

    /// Where a window hears Android's sound while it records (EngineAudio).
    static var audioSocket: URL {
        AndroidRuntime.shared.home.appendingPathComponent("rec-\(ProcessInfo.processInfo.processIdentifier).sock")
    }

    static let audioRequest = Notification.Name("io.github.inquiline-app.record-sound")
}

/// One recording of an app's screen and Android's sound into a movie: the pictures as Android
/// draws them, made into H.264 by the Mac's video encoder on the GPU, timed by the Mac's clock
/// as they come, so a still screen costs nothing; Android's sound from Inquiline (EngineAudio).
final class ScreenRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let sound: AVAssetWriterInput
    private let width: Int, height: Int
    private let start: CMTime
    private let queue = DispatchQueue(label: "inquiline.recorder")
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private var lastVideo = CMTime.invalid
    private var finished = false
    private var listener: Int32 = -1

    init?(url: URL, size: CGSize, device: MTLDevice) {
        // The encoder takes even sizes.
        width = max(Int(size.width) & ~1, 2)
        height = max(Int(size.height) & ~1, 2)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov),
              let library = try? device.makeLibrary(source: FrameRenderer.shaders, options: nil)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "frameVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frameFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.url = url
        self.writer = writer
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // About what the Mac's own recordings take for their size.
                AVVideoAverageBitRateKey: max(width * height * 8, 4_000_000),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        sound.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(sound)
        guard writer.startWriting() else { return nil }
        start = CMClockGetTime(CMClockGetHostTimeClock())
        writer.startSession(atSourceTime: start)
        listenForSound()
    }

    // MARK: Pictures

    /// Encodes drawing `frame` into a picture of the movie, fitted to its size, into `commands`;
    /// the picture goes into the movie once the GPU has drawn it.
    func record(_ frame: MTLTexture, in commands: MTLCommandBuffer) {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        guard !finished, let cache, let pool = adaptor.pixelBufferPool else { return }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return }
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
              let wrapped, let target = CVMetalTextureGetTexture(wrapped)
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        // A screen turned or resized while recording fits the movie's size, with bars.
        let fit = min(Double(width) / Double(frame.width), Double(height) / Double(frame.height))
        let shownWidth = Double(frame.width) * fit, shownHeight = Double(frame.height) * fit
        encoder.setViewport(MTLViewport(originX: (Double(width) - shownWidth) / 2, originY: (Double(height) - shownHeight) / 2,
                                        width: shownWidth, height: shownHeight, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.addCompletedHandler { [weak self] _ in
            self?.queue.async {
                guard let self, !self.finished, self.video.isReadyForMoreMediaData else { return }
                _ = wrapped
                let time = max(time, self.start)
                if self.lastVideo.isValid, time <= self.lastVideo { return }
                if self.adaptor.append(buffer, withPresentationTime: time) { self.lastVideo = time }
            }
        }
    }

    // MARK: Sound

    /// Inquiline plays Android's sound, so it takes it for the movie too, and asks once for the
    /// Mac's permission to: a window asking would ask for each app. It's sent here over a
    /// socket only this user can reach: the rate, then pieces of 32-bit stereo, each with the
    /// Mac's clock at its start.
    private func listenForSound() {
        let path = ScreenCapture.audioSocket.path
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
            self?.receiveSound(from: connection)
            close(connection)
        }
        thread.name = "inquiline.recorder-sound"
        thread.start()
        DistributedNotificationCenter.default().postNotificationName(ScreenCapture.audioRequest, object: path,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    private func receiveSound(from fd: Int32) {
        func read(_ count: Int) -> Data? { try? ScrcpyServer.readExactly(count, from: fd) }
        guard let header = read(8) else { return }
        let rate = header.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        var stream = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard rate > 0, CMAudioFormatDescriptionCreate(allocator: nil, asbd: &stream, layoutSize: 0, layout: nil,
                                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                       formatDescriptionOut: &format) == noErr, let format
        else { return }
        while let head = read(12) {
            let (hostTime, frames) = head.withUnsafeBytes {
                (UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)),
                 Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))))
            }
            guard frames > 0, frames < 1 << 16, let samples = read(frames * 8) else { return }
            let time = CMClockMakeHostTimeFromSystemUnits(hostTime)
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: samples.count,
                                                     blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: samples.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                     blockBufferOut: &block) == noErr, let block
            else { continue }
            _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                         offsetIntoDestination: 0, dataLength: samples.count) }
            var buffer: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                     sampleCount: frames, presentationTimeStamp: time,
                                                                     packetDescriptions: nil, sampleBufferOut: &buffer) == noErr,
                  let buffer
            else { continue }
            queue.async { [self] in
                guard !finished, time >= start, sound.isReadyForMoreMediaData else { return }
                sound.append(buffer)
            }
        }
    }

    // MARK: Ending

    /// Ends the movie and waits for it to be saved, for a window closing, which ends its app.
    func finishNow() {
        let saved = DispatchSemaphore(value: 0)
        finish(onMain: false) { _ in saved.signal() }
        _ = saved.wait(timeout: .now() + 5)
    }

    /// Ends the movie; `done` is called on the main queue with whether it was saved.
    func finish(onMain: Bool = true, _ done: @escaping (Bool) -> Void) {
        let done: (Bool) -> Void = onMain ? { saved in DispatchQueue.main.async { done(saved) } } : done
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        if listener >= 0 {
            // Inquiline stops sending once the window stops listening.
            close(listener)
            listener = -1
            unlink(ScreenCapture.audioSocket.path)
        }
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            guard lastVideo.isValid else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                done(false)
                return
            }
            writer.endSession(atSourceTime: end)
            video.markAsFinished()
            sound.markAsFinished()
            writer.finishWriting { [self] in
                let saved = writer.status == .completed
                if !saved { AppLog.write("A screen recording couldn't be saved: \(writer.error?.localizedDescription ?? "")") }
                done(saved)
            }
        }
    }
}

/// Android's sound for screen recordings, taken in Inquiline from the engine that plays it,
/// with the Mac's process tap (macOS 14.2), so the Mac asks once, for Inquiline, whether it
/// may: the windows recording ask for it (ScreenRecorder), and get it while they listen.
@available(macOS 14.2, *)
final class EngineAudio {
    static let shared = EngineAudio()

    private let queue = DispatchQueue(label: "inquiline.engine-sound", qos: .userInitiated)
    /// The tap's sound comes on a queue of its own: the tap is stopped and started on `queue`,
    /// and stopping waits for its last delivery, which on the same queue would never come.
    private let ioQueue = DispatchQueue(label: "inquiline.engine-sound-io", qos: .userInteractive)
    /// Guards the listeners, which both queues use.
    private let lock = NSLock()
    private var reconciling = false
    private var listeners: [Int32] = []
    /// Listeners that take the sound from the Mac, as a phone showing a window plays it there
    /// (PhoneSound): while one listens, the engine is silent on the Mac.
    private var silencing: Set<Int32> = []
    private var tapSilences = false
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: ScreenCapture.audioRequest, object: nil, queue: nil) { [weak self] note in
            guard let self, let path = note.object as? String else { return }
            self.queue.async { self.add(listener: path) }
        }
    }

    private func add(listener path: String) {
        // Only a window's socket in Inquiline's own folder.
        guard path.hasPrefix(AndroidRuntime.shared.home.path + "/rec-"), path.hasSuffix(".sock") else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard connected == 0 else { close(fd); return }
        lock.lock()
        if path.hasSuffix(PhoneSound.socketSuffix) { silencing.insert(fd) }
        let silence = !silencing.isEmpty
        lock.unlock()
        // A tap that silences, or that no longer must, is made anew; its listeners stay.
        if device != kAudioObjectUnknown, tapSilences != silence { stopTap() }
        guard device != kAudioObjectUnknown || startTap() else {
            lock.lock(); silencing.remove(fd); lock.unlock()
            close(fd)
            return
        }
        var rate = format.mSampleRate.bitPattern.littleEndian
        guard Darwin.send(fd, &rate, 8, 0) == 8 else {
            lock.lock(); silencing.remove(fd); lock.unlock()
            close(fd)
            return
        }
        lock.lock(); listeners.append(fd); lock.unlock()
    }

    /// The engine's sound, as it plays it, still heard on the Mac.
    private func startTap() -> Bool {
        guard let engine = engineProcess() else {
            AppLog.write("Android's sound can't be recorded: the engine plays none")
            return false
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [engine])
        description.uuid = UUID()
        lock.lock(); tapSilences = !silencing.isEmpty; lock.unlock()
        description.muteBehavior = tapSilences ? .muted : .unmuted
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            AppLog.write("Android's sound can't be recorded: the Mac doesn't allow it")
            return false
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        var settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Inquiline Recording",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        // The Mac's speakers keep its time, as for the sound the engine plays there.
        if let output = Self.outputUID() {
            settings[kAudioAggregateDeviceMainSubDeviceKey] = output
            settings[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &device) == noErr,
              Self.takeDeviceRate(device, into: &format),
              AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue, { [weak self] _, input, inputTime, _, _ in
                  self?.deliver(input, at: inputTime.pointee.mHostTime)
              }) == noErr,
              AudioDeviceStart(device, proc) == noErr
        else {
            AppLog.write("Android's sound can't be recorded: its tap didn't start")
            stopTap()
            return false
        }
        return true
    }

    private func stopTap() {
        if device != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(device, proc)
                AudioDeviceDestroyIOProcID(device, proc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    /// To each window listening, as 32-bit stereo; a window gone is let go, and with none left
    /// the tap stops.
    private func deliver(_ input: UnsafePointer<AudioBufferList>, at hostTime: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mData != nil, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let frames = Int(first.mDataByteSize) / 4 / (interleaved ? channels : 1)
        guard frames > 0 else { return }
        var packet = Data(count: 12 + frames * 8)
        packet.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: hostTime.littleEndian, as: UInt64.self)
            raw.storeBytes(of: UInt32(frames).littleEndian, toByteOffset: 8, as: UInt32.self)
            let out = raw.baseAddress!.advanced(by: 12).assumingMemoryBound(to: Float.self)
            for channel in 0..<2 {
                let source = min(channel, channels - 1)
                if interleaved {
                    let samples = first.mData!.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames { out[frame * 2 + channel] = samples[frame * channels + source] }
                } else if source < buffers.count, let data = buffers[source].mData {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames { out[frame * 2 + channel] = samples[frame] }
                }
            }
        }
        lock.lock()
        listeners.removeAll { fd in
            let sent = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, MSG_DONTWAIT) }
            guard sent != packet.count else { return false }
            close(fd)
            silencing.remove(fd)
            return true
        }
        // With no listener left the tap stops; with the phone gone, the Mac plays the sound again,
        // for a recording still listening. Done on `queue`, once this delivery is over.
        let change = !reconciling && (listeners.isEmpty || tapSilences != !silencing.isEmpty)
        if change { reconciling = true }
        lock.unlock()
        if change { queue.async { [self] in reconcile() } }
    }

    /// On `queue`: the tap as its listeners want it, or none.
    private func reconcile() {
        lock.lock()
        reconciling = false
        let none = listeners.isEmpty, silence = !silencing.isEmpty
        lock.unlock()
        guard device != kAudioObjectUnknown else { return }
        if none {
            stopTap()
        } else if tapSilences != silence {
            stopTap()
            if !startTap() {
                lock.lock()
                listeners.forEach { close($0) }
                listeners.removeAll()
                silencing.removeAll()
                lock.unlock()
            }
        }
    }

    /// The engine, among the processes the Mac's sound system knows.
    private func engineProcess() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return nil }
        for object in objects {
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if String(cString: path).hasSuffix("/" + AndroidRuntime.engineName) { return object }
        }
        return nil
    }

    /// The tap's sound comes at the device's rate, the Mac's speakers' (44.1 kHz for many
    /// displays), not the engine's own 48 kHz, which the tap's format says: taken as the
    /// engine's, the sound ran 9% fast and ahead of the picture.
    private static func takeDeviceRate(_ device: AudioObjectID, into format: inout AudioStreamBasicDescription) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 { format.mSampleRate = rate }
        return true
    }

    private static func outputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var output = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr
        else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(output, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
