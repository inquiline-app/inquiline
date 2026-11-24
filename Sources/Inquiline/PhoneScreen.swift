import CoreMedia
import Metal
import QuartzCore
import VideoToolbox

/// A window's picture for a phone (PhoneRemote's screen), as game streaming makes it (Sunshine,
/// Moonlight): each picture the window draws (FrameRenderer), scaled to at most 1080p on the GPU
/// and made H.264 by the Mac's video encoder in its low-latency mode, with no pictures held back
/// for reordering. A still screen sends nothing; a phone missing a picture asks for a key frame.
final class PhoneScreen {
    /// H.264 access units, each NAL unit after its 4-byte length (AVCC), with the sequence and
    /// picture parameter sets before a key frame; and the picture's time in seconds. Called on
    /// the encoder's thread.
    var onFrame: ((Data, Double) -> Void)?

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let queue = DispatchQueue(label: "inquiline.phone-screen")
    private var cache: CVMetalTextureCache?
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var width = 0, height = 0
    private var start: Double?
    private var lastTime = 0.0
    private var inFlight = 0
    private var wantsKeyFrame = true
    private var stopped = false

    /// The longest side it sends: a phone's screen shows no more.
    private static let longest = 1920

    init?(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.shaders, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    deinit { stop() }

    func stop() {
        queue.sync {
            stopped = true
            endSession()
        }
    }

    /// The next picture is a key frame, as when a phone lost one.
    func keyFrame() {
        queue.async { self.wantsKeyFrame = true }
    }

    /// Encodes drawing `frame` into `commands`; the picture is encoded once the GPU has drawn it.
    /// On the window's frame thread.
    func take(_ frame: MTLTexture, in commands: MTLCommandBuffer) {
        let now = CACurrentMediaTime()
        let made: (CVPixelBuffer, CVMetalTexture)? = queue.sync { () -> (CVPixelBuffer, CVMetalTexture)? in
            // The encoder keeps up at 60 a second; pictures beyond, or while two are still being
            // encoded, wait for the next.
            guard !stopped, inFlight < 2, now - lastTime >= 1.0 / 62 else { return nil }
            prepare(for: frame)
            guard let pool, let cache else { return nil }
            var made: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
            var wrapped: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapped)
                    == kCVReturnSuccess, let wrapped else { return nil }
            lastTime = now
            inFlight += 1
            return (buffer, wrapped)
        }
        guard let (buffer, wrapped) = made, let target = CVMetalTextureGetTexture(wrapped) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            queue.async { self.inFlight -= 1 }
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.addCompletedHandler { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                _ = wrapped
                self.encode(buffer, at: now)
            }
        }
    }

    // MARK: - On the queue

    /// A session for the frame's size, scaled to fit `longest`, in even pixels.
    private func prepare(for frame: MTLTexture) {
        let scale = min(1, Double(Self.longest) / Double(max(frame.width, frame.height)))
        let w = max(Int(Double(frame.width) * scale) & ~1, 2), h = max(Int(Double(frame.height) * scale) & ~1, 2)
        guard w != width || h != height || session == nil else { return }
        endSession()
        width = w
        height = h
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        // Low-latency rate control (as FaceTime's): each picture about the same size, none held.
        let specification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ]
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
                                         compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &made) == noErr, let made else {
            AppLog.write("The phone's screen: the Mac's encoder didn't start")
            return
        }
        // About what game streaming takes for its size: 10 Mbit/s at 1080p.
        let bitRate = max(w * h * 5, 3_000_000)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 4,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        VTSessionSetProperties(made, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(made)
        session = made
        wantsKeyFrame = true
        AppLog.write("The phone's screen: \(w)×\(h)")
    }

    private func endSession() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        pool = nil
        width = 0
        height = 0
    }

    private func encode(_ buffer: CVPixelBuffer, at time: Double) {
        defer { inFlight -= 1 }
        guard !stopped, let session, CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return }
        if start == nil { start = time }
        let seconds = time - (start ?? time)
        let options: CFDictionary? = wantsKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        wantsKeyFrame = false
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 90_000),
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self, let data = Self.accessUnit(sample) else { return }
            self.onFrame?(data, seconds)
        }
    }

    /// The sample's NAL units, length-prefixed as the encoder gives them, with the parameter sets
    /// first when it's a key frame, which the phone needs to start decoding there.
    private static func accessUnit(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        var unit = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var set: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &set,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                guard let set else { continue }
                var big = UInt32(size).bigEndian
                unit.append(Data(bytes: &big, count: 4))
                unit.append(set, count: size)
            }
        }
        unit.append(Data(bytes: pointer, count: length))
        return unit
    }

    /// A triangle covering the picture, sampling the frame smoothly as it's made smaller.
    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct Varyings { float4 position [[position]]; float2 uv; };
    vertex Varyings screenVertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return { float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv };
    }
    fragment float4 screenFragment(Varyings in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
        constexpr sampler smooth(filter::linear);
        return frame.sample(smooth, in.uv);
    }
    """
}
