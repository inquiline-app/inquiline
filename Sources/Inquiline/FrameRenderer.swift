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
    let device: MTLDevice
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

    /// An app laid out for its window's size (AppWindowController's flexible apps): its picture is
    /// the window's own pixels, never upscaled; while the window is resized it's scaled to fit,
    /// and what it doesn't cover has the app's own background colour, not black.
    private(set) var keepsPixelSize = false
    /// Set when Android's screen has a new size (setSize): until the app draws for it, Android
    /// shows half-drawn pictures, which aren't shown.
    private var waitingForContent = false
    /// The size of the last picture shown, and how many pictures were held back since a new size.
    private var shownWidth = 0
    private var shownHeight = 0
    private var heldBack = 0
    private var background: (UInt8, UInt8, UInt8) = (0, 0, 0)
    /// Called on the main thread when the app has drawn for a new size of its screen.
    var onContent: (() -> Void)?

    /// For screenshots and recordings (ScreenRecorder): the slot of the picture shown last,
    /// which stays in memory until Android's third picture after it, and the recording that
    /// takes each picture. Held while a slot's memory is written or read.
    private let captureLock = NSLock()
    private var lastSlot = -1
    private var recorder: ScreenRecorder?
    /// A phone showing the window (PhoneRemote's screen).
    private var screen: PhoneScreen?

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
        // Readable, as macOS 26's glass (a popover's, a toolbar's) samples what is behind it: a
        // layer it can't read shows black or torn there, as App Settings opened over it.
        layer.framebufferOnly = false
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Frames show at the display's refresh, as a phone's screen shows them, without tearing.
        layer.displaySyncEnabled = true
    }

    /// Called on the main thread, once, for an app that lays out for its window.
    func keepPixelSize() {
        keepsPixelSize = true
        // Its picture is the window's size, up to the few pixels Android's display server rounds
        // it to: filled, not fitted, so no thin bars at its sides.
        layer.contentsGravity = .resize
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
        captureLock.lock()
        defer { captureLock.unlock() }
        lastSlot = -1
        self.width = width
        self.height = height
        if keepsPixelSize {
            outputLock.lock()
            waitingForContent = true
            outputLock.unlock()
        }
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
        captureLock.lock()
        let copied = copy(resource: resource, offset: UInt64(slot * slotSize))
        captureLock.unlock()
        guard copied, let commands = queue.makeCommandBuffer() else {
            freeSlots.signal()
            return
        }
        if keepsPixelSize, !takeContent(slot: slot) {
            freeSlots.signal()
            return
        }
        captureLock.lock()
        lastSlot = slot
        recorder?.record(textures[slot], in: commands)
        screen?.take(textures[slot], in: commands)
        captureLock.unlock()
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

    /// Whether the frame in `slot` is shown: after a new size, an empty screen isn't, as Android
    /// draws one while the app lays out again. Also takes the app's background colour from the
    /// frame's bottom right corner, for the part of the window the picture doesn't cover.
    private func takeContent(slot: Int) -> Bool {
        guard let memory else { return true }
        let pixels = memory.advanced(by: slot * slotSize).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }
        outputLock.lock()
        let waiting = waitingForContent
        outputLock.unlock()
        if waiting {
            // Until the app draws for the new size, Android shows its last picture on the bigger
            // screen and leaves the new part black, or shows nothing. Such pictures aren't shown,
            // as a Mac keeps a window's old picture until its app draws. Android holds at most
            // its few queued pictures before the app's own; a picture that is still black after
            // those is the app's, as a video's black bars.
            func black(_ xs: [Int], _ ys: [Int]) -> Bool {
                !xs.contains { x in ys.contains { y in pixel(x, y) != (0, 0, 0) } }
            }
            let grid = (0..<16).map { (2 * $0 + 1) }
            let columns = grid.map { width * $0 / 32 }, rows = grid.map { height * $0 / 32 }
            var unfinished = black(columns, rows)
            if !unfinished, shownWidth > 0, width > shownWidth + 8 {
                unfinished = black(grid.map { shownWidth + (width - shownWidth) * $0 / 32 }, rows)
            }
            if !unfinished, shownHeight > 0, height > shownHeight + 8 {
                unfinished = black(columns, grid.map { shownHeight + (height - shownHeight) * $0 / 32 })
            }
            if unfinished, heldBack < Self.slots {
                heldBack += 1
                return false
            }
            outputLock.lock()
            waitingForContent = false
            outputLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onContent?() }
        }
        heldBack = 0
        shownWidth = width
        shownHeight = height
        let corner = pixel(width - 4, height - 4)
        if corner != background {
            background = corner
            let color = CGColor(srgbRed: CGFloat(corner.0) / 255, green: CGFloat(corner.1) / 255,
                                blue: CGFloat(corner.2) / 255, alpha: 1)
            DispatchQueue.main.async { [layer] in layer.backgroundColor = color }
        }
        return true
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
        // Its picture is the window's own pixels, never scaled up.
        if keepsPixelSize { return nil }
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

    // MARK: - Screenshots and recordings

    /// The picture shown now, as Android drew it: its own pixels, not the window's.
    func picture() -> CGImage? {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard lastSlot >= 0, let memory, width > 0, height > 0,
              let provider = CGDataProvider(data: Data(bytes: memory.advanced(by: lastSlot * slotSize),
                                                       count: width * height * 4) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The size of Android's picture now.
    var pictureSize: CGSize {
        captureLock.lock()
        defer { captureLock.unlock() }
        return CGSize(width: width, height: height)
    }

    /// Each picture from now goes to `recorder` too, starting with the one shown, as the screen
    /// may stay still a while; nil stops.
    func record(to recorder: ScreenRecorder?) {
        captureLock.lock()
        defer { captureLock.unlock() }
        self.recorder = recorder
        if let recorder, lastSlot >= 0, lastSlot < textures.count, let commands = queue.makeCommandBuffer() {
            recorder.record(textures[lastSlot], in: commands)
            commands.commit()
        }
    }

    /// Each picture from now goes to a phone too, starting with the one shown; nil stops.
    func mirror(to screen: PhoneScreen?) {
        captureLock.lock()
        defer { captureLock.unlock() }
        self.screen = screen
        if let screen, lastSlot >= 0, lastSlot < textures.count, let commands = queue.makeCommandBuffer() {
            screen.take(textures[lastSlot], in: commands)
            commands.commit()
        }
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
    static let shaders = """
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
