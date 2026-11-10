import Darwin
import Foundation
import Metal
import MetalFX
import QuartzCore

/// Draws an app's Android frames in its window as Android drew them: no video encoding.
/// For each frame Android reports, gfxstream in the VM process copies the frame's GPU
/// resource into memory this process shares with it (one GPU copy, see
/// inquiline_frame_server.cpp), and Metal draws it from there.
final class FrameRenderer {
    let layer = CAMetalLayer()

    private static let slots = 3
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// One permit per slot: a slot is reused once the GPU has drawn it.
    private let freeSlots = DispatchSemaphore(value: FrameRenderer.slots)
    private var nextSlot = 0

    private var server: Int32 = -1
    private var memory: UnsafeMutableRawPointer?
    private var memorySize = 0
    private var buffer: MTLBuffer?
    private var width = 0
    private var height = 0
    private var slotSize = 0
    private var textures: [MTLTexture] = []

    /// The window's size in pixels. Frames are made this size with MetalFX, Apple's upscaler
    /// for Mac games, which keeps edges and text sharp; scaling by the layer alone blurs them.
    private let outputLock = NSLock()
    private var windowPixels = CGSize.zero
    private var windowChanged = Date.distantPast
    private var scaler: MTLFXSpatialScaler?
    private var scaled: MTLTexture?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaders, options: nil)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "frameVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frameFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Frames show at the display's refresh, as a phone's screen shows them, without tearing.
        layer.displaySyncEnabled = true
    }

    deinit {
        if server >= 0 { close(server) }
        unmapMemory()
    }

    /// The Android display's size changed: a new display, or one turned. Called on the
    /// session's receive thread, as draw(resource:) is.
    func setSize(width: Int, height: Int) {
        guard width > 0, height > 0, width != self.width || height != self.height else { return }
        // Memory the GPU may still be reading can't be replaced.
        for _ in 0..<Self.slots { freeSlots.wait() }
        defer { for _ in 0..<Self.slots { freeSlots.signal() } }
        self.width = width
        self.height = height
        layer.drawableSize = CGSize(width: width, height: height)
        scaler = nil
        textures = []
        let page = Int(getpagesize())
        slotSize = (width * height * 4 + page - 1) / page * page
        if slotSize * Self.slots > memorySize { _ = shareMemory(size: slotSize * Self.slots) }
        guard let buffer else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        for slot in 0..<Self.slots {
            if let texture = buffer.makeTexture(descriptor: descriptor, offset: slot * slotSize, bytesPerRow: width * 4) {
                textures.append(texture)
            }
        }
    }

    /// Called on the session's receive thread for each frame. Returns once the frame is in
    /// this process's memory, so Android can have its buffer back.
    func draw(resource: UInt32) {
        guard textures.count == Self.slots else { return }
        freeSlots.wait()
        let slot = nextSlot
        nextSlot = (nextSlot + 1) % Self.slots
        guard copy(resource: resource, offset: UInt64(slot * slotSize)),
              let commands = queue.makeCommandBuffer()
        else {
            freeSlots.signal()
            return
        }
        var frame = textures[slot]
        if let scaler = upscaler() {
            scaler.colorTexture = frame
            scaler.outputTexture = scaled
            scaler.encode(commandBuffer: commands)
            frame = scaled!
        }
        guard let drawable = layer.nextDrawable() else {
            commands.addCompletedHandler { [freeSlots] _ in freeSlots.signal() }
            commands.commit()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(frame, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.addCompletedHandler { [freeSlots] _ in freeSlots.signal() }
        commands.commit()
    }

    /// Called on the main thread when the window's size or screen changes.
    func setWindowPixels(_ size: CGSize) {
        outputLock.lock()
        if size != windowPixels {
            windowPixels = size
            windowChanged = Date()
        }
        outputLock.unlock()
    }

    /// The upscaler for the window's current size, made again when it changes. None when the
    /// window shows the frame at its own size or smaller, where the layer's scaling is enough.
    private func upscaler() -> MTLFXSpatialScaler? {
        outputLock.lock()
        let window = windowPixels, changed = windowChanged
        outputLock.unlock()
        // While the window is resized or goes in or out of full screen, its size changes each
        // frame; making a scaler for each flickered. The current one stays, and the layer
        // scales its picture, until the size has held for a moment.
        if scaler != nil, Date().timeIntervalSince(changed) < 0.3 { return scaler }
        // The frame's shape, as large as fits the window.
        let fit = min(window.width / CGFloat(width), window.height / CGFloat(height))
        let output = CGSize(width: (CGFloat(width) * fit).rounded(), height: (CGFloat(height) * fit).rounded())
        guard fit > 1.05, output.width <= 8192, output.height <= 8192 else {
            if scaler != nil {
                scaler = nil
                scaled = nil
                layer.drawableSize = CGSize(width: width, height: height)
            }
            return nil
        }
        if let scaler, scaler.outputWidth == Int(output.width), scaler.outputHeight == Int(output.height) { return scaler }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = width
        descriptor.inputHeight = height
        descriptor.outputWidth = Int(output.width)
        descriptor.outputHeight = Int(output.height)
        descriptor.colorTextureFormat = .rgba8Unorm
        descriptor.outputTextureFormat = .rgba8Unorm
        // Android's pixels are sRGB-encoded, as a game's final image is.
        descriptor.colorProcessingMode = .perceptual
        guard let made = descriptor.makeSpatialScaler(device: device) else { return nil }
        let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: made.outputWidth,
                                                               height: made.outputHeight, mipmapped: false)
        texture.usage = made.outputTextureUsage.union(.shaderRead)
        texture.storageMode = .private
        scaled = device.makeTexture(descriptor: texture)
        guard scaled != nil else { return nil }
        made.inputContentWidth = width
        made.inputContentHeight = height
        scaler = made
        layer.drawableSize = output
        return made
    }

    // MARK: - The VM's frame server

    /// Shared memory both processes map; the VM copies frames into it. The VM makes it, as
    /// Swift can't call shm_open with the arguments that create one.
    private func shareMemory(size: Int) -> Bool {
        unmapMemory()
        var request = Data([UInt8(ascii: "M")])
        withUnsafeBytes(of: UInt64(size).littleEndian) { request.append(contentsOf: $0) }
        guard ask(request) else { return false }
        var length: UInt16 = 0
        guard recv(server, &length, 2, MSG_WAITALL) == 2 else { return false }
        var nameBytes = [UInt8](repeating: 0, count: Int(UInt16(littleEndian: length)) + 1)
        guard recv(server, &nameBytes, nameBytes.count - 1, MSG_WAITALL) == nameBytes.count - 1 else { return false }
        // Opening an existing one takes no mode, so the variadic call is safe with two arguments.
        typealias Open = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else { return false }
        let open = unsafeBitCast(symbol, to: Open.self)
        let fd = nameBytes.withUnsafeBufferPointer { $0.withMemoryRebound(to: CChar.self) { open($0.baseAddress!, O_RDWR) } }
        nameBytes.withUnsafeBufferPointer { _ = $0.withMemoryRebound(to: CChar.self) { shm_unlink($0.baseAddress!) } }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else { return false }
        memory = mapped
        memorySize = size
        buffer = device.makeBuffer(bytesNoCopy: mapped, length: size, options: .storageModeShared, deallocator: nil)
        return buffer != nil
    }

    private func unmapMemory() {
        buffer = nil
        textures = []
        if let memory { munmap(memory, memorySize) }
        memory = nil
        memorySize = 0
    }

    private func copy(resource: UInt32, offset: UInt64) -> Bool {
        var request = Data([UInt8(ascii: "C")])
        withUnsafeBytes(of: resource.littleEndian) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: offset.littleEndian) { request.append(contentsOf: $0) }
        return ask(request)
    }

    /// Sends one request and waits for its status byte, connecting first if needed.
    private func ask(_ request: Data) -> Bool {
        if server < 0 { server = Self.connect(to: AndroidRuntime.shared.framesSocket.path) }
        guard server >= 0 else { return false }
        let sent = request.withUnsafeBytes { Darwin.send(server, $0.baseAddress!, $0.count, 0) }
        var status: UInt8 = 1
        guard sent == request.count, recv(server, &status, 1, MSG_WAITALL) == 1 else {
            close(server)
            server = -1
            return false
        }
        return status == 0
    }

    private static func connect(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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

    /// A triangle covering the drawable, sampling the frame; Android's top row comes first.
    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct Varyings { float4 position [[position]]; float2 uv; };
    vertex Varyings frameVertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return { float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv };
    }
    fragment float4 frameFragment(Varyings in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
        constexpr sampler pixels(filter::nearest);
        return frame.sample(pixels, in.uv);
    }
    """
}
