import AppKit
import Darwin

/// Client for the scrcpy server protocol: runs one app on its own Android virtual
/// display, receives its frames and sends input back. Our server build sends each frame
/// as the GPU resource Android drew it into (see FrameRenderer), not as video.
final class ScrcpySession {
    /// The app's Android screen: its size in pixels and its density.
    struct Screen: Equatable {
        let width: Int
        let height: Int
        let density: Int
    }
    let screen: Screen

    /// The toolbar's Resolution, kept for each app: how many pixels Android draws, 16:9. Apps
    /// lay out the same at each, as on 1440 by 810 at 320 dpi; only sharpness changes.
    enum Resolution: Int, CaseIterable {
        case low = 1, medium, high

        var name: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }

        var longSide: Int {
            switch self {
            case .low: return 1440
            case .medium: return 2560
            case .high: return 3840
            }
        }

        func screen(landscape: Bool) -> Screen {
            let short = longSide * 9 / 16, density = 320 * longSide / 1440
            return landscape ? Screen(width: longSide, height: short, density: density)
                : Screen(width: short, height: longSide, density: density)
        }
    }

    static func resolution(package: String) -> Resolution {
        Resolution(rawValue: UserDefaults.standard.integer(forKey: resolutionKey(package))) ?? .medium
    }

    static func resolutionKey(_ package: String) -> String { "Resolution.\(package)" }

    /// What our server build sends where scrcpy sends a codec id.
    private static let framesCodec: UInt32 = 0x6672_6D73 // "frms"
    private static let maxClipboardBytes = (1 << 18) - 14

    private static let sessionFlag: UInt32 = 0x8000_0000

    private let package: String
    private let restartsApp: Bool
    private let scid = String(format: "%08x", UInt32.random(in: 1...0x7FFF_FFFF))

    private let stateLock = NSLock()
    private var videoFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var stopped = false
    private var pictures = 0
    private var server: Int32 = -1
    private let controlQueue = DispatchQueue(label: "inquiline.control")

    /// Called on the receive thread.
    var onSessionSize: ((_ width: Int, _ height: Int) -> Void)?
    /// Called on the receive thread with each frame's GPU resource. Android gets the frame's
    /// buffer back once it returns, so the frame must be copied by then.
    var onFrame: ((_ resource: UInt32) -> Void)?
    var onEnd: ((Error?) -> Void)?
    /// Called on a background thread once Android is ready, before the app starts.
    var beforeLaunch: (() -> Void)?
    /// Called on a background thread when Android's clipboard changes.
    var onClipboard: ((String) -> Void)?

    /// `restartsApp` stops the app first, so it starts again on this session's screen.
    init(package: String, screen: Screen, restartsApp: Bool = false) {
        self.package = package
        self.screen = screen
        self.restartsApp = restartsApp
    }

    func start() {
        let thread = Thread { [self] in
            do {
                try connect()
                try receiveLoop()
                finish(nil)
            } catch {
                finish(error)
            }
        }
        thread.name = "inquiline.video"
        thread.start()
    }

    func stop() {
        guard markStopped() else { return }
        teardown()
    }

    private func finish(_ error: Error?) {
        guard markStopped() else { return }
        teardown()
        onEnd?(error)
    }

    private func markStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if stopped { return false }
        stopped = true
        return true
    }

    private func teardown() {
        // shutdown() also unblocks the receive thread; descriptors close with it.
        if videoFD >= 0 { shutdown(videoFD, SHUT_RDWR) }
        if controlFD >= 0 { shutdown(controlFD, SHUT_RDWR) }
        if server >= 0 { shutdown(server, SHUT_RDWR) }
    }

    // MARK: - Connection

    private func connect() throws {
        try ScrcpyServer.push()
        beforeLaunch?()

        let parameters = [
            "scid=\(scid)",
            "log_level=info",
            "audio=false", // Android's sound card plays the sound of all apps
            "tunnel_forward=true",
            "frames=true",
            "new_display=\(screen.width)x\(screen.height)/\(screen.density)",
            "vd_system_decorations=false",
            "display_ime_policy=hide",
            "power_on=false",
            // Its clean-up process restores settings these sessions never change.
            "cleanup=false",
        ]
        server = try ScrcpyServer.launch(parameters: parameters)

        videoFD = try ScrcpyServer.connectFirstSocket(scid: scid) { isStopped }
        controlFD = try ScrcpyServer.openStream(scid: scid)

        _ = try readExactly(64) // device name
        let codec = ScrcpyServer.readUInt32(try readExactly(4), at: 0)
        guard codec == Self.framesCodec else {
            throw RuntimeError("The display server could not start the video stream.")
        }
        sendStartApp()
        startDeviceMessageReader()
        askForPictureIfNone(tries: 2)
    }

    private func startDeviceMessageReader() {
        let thread = Thread { [self] in
            // Ends with an error once the socket shuts down.
            try? readDeviceMessages()
        }
        thread.name = "inquiline.device-messages"
        thread.start()
    }

    private func readDeviceMessages() throws {
        while true {
            let type = try readExactly(1, from: controlFD)[0]
            switch type {
            case 0: // clipboard
                let length = Int(ScrcpyServer.readUInt32(try readExactly(4, from: controlFD), at: 0))
                let text = try readExactly(length, from: controlFD)
                onClipboard?(String(decoding: text, as: UTF8.self))
            case 1: // clipboard acknowledgement
                _ = try readExactly(8, from: controlFD)
            case 2: // HID output: id, then a sized payload
                let header = try readExactly(4, from: controlFD)
                _ = try readExactly(Int(header[2]) << 8 | Int(header[3]), from: controlFD)
            default:
                return
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    // MARK: - Video

    private func receiveLoop() throws {
        defer {
            close(videoFD)
            close(controlFD)
        }
        while true {
            let first = ScrcpyServer.readUInt32(try readExactly(4), at: 0)
            if first & Self.sessionFlag != 0 {
                let size = try readExactly(8)
                onSessionSize?(Int(ScrcpyServer.readUInt32(size, at: 0)), Int(ScrcpyServer.readUInt32(size, at: 4)))
                continue
            }
            let number = ScrcpyServer.readUInt32(try readExactly(4), at: 0)
            stateLock.lock()
            pictures += 1
            stateLock.unlock()
            onFrame?(first)
            var release = Data([100])
            release.appendBigEndian(number)
            send(release)
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        try ScrcpyServer.readExactly(count, from: videoFD)
    }

    private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        try ScrcpyServer.readExactly(count, from: fd)
    }

    // MARK: - Control messages

    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }
    enum KeyAction: UInt8 { case down = 0, up = 1 }

    func sendTouch(_ action: TouchAction, x: Int, y: Int, width: Int, height: Int) {
        var message = Data([2, action.rawValue])
        message.appendBigEndian(UInt64(bitPattern: -2)) // generic finger
        message.appendPosition(x: x, y: y, width: width, height: height)
        message.appendBigEndian(action == .up ? UInt16(0) : UInt16.max) // pressure
        message.appendBigEndian(UInt32(0)) // action button
        message.appendBigEndian(UInt32(0)) // buttons
        send(message)
    }

    /// `horizontal` and `vertical` are in [-16, 16].
    func sendScroll(x: Int, y: Int, width: Int, height: Int, horizontal: Double, vertical: Double) {
        var message = Data([3])
        message.appendPosition(x: x, y: y, width: width, height: height)
        message.appendBigEndian(Self.scrollFixedPoint(horizontal))
        message.appendBigEndian(Self.scrollFixedPoint(vertical))
        message.appendBigEndian(UInt32(0)) // buttons
        send(message)
    }

    func sendKey(_ action: KeyAction, keycode: Int32, metaState: UInt32 = 0) {
        var message = Data([0, action.rawValue])
        message.appendBigEndian(UInt32(bitPattern: keycode))
        message.appendBigEndian(UInt32(0)) // repeat
        message.appendBigEndian(metaState)
        send(message)
    }

    enum CopyKey: UInt8 { case copy = 1, cut = 2 }

    /// Makes the app copy or cut its selection; the text returns through `onClipboard`.
    func sendCopy(_ key: CopyKey) {
        send(Data([8, key.rawValue]))
    }

    /// Hands the Mac's clipboard to Android and pastes it into the focused app.
    func sendPaste(_ text: String) {
        let bytes = Data(text.utf8)
        guard bytes.count <= Self.maxClipboardBytes else { return }
        var message = Data([9])
        message.appendBigEndian(UInt64(0)) // sequence: no acknowledgement wanted
        message.append(1) // paste
        message.appendBigEndian(UInt32(bytes.count))
        message.append(bytes)
        send(message)
    }

    func sendText(_ text: String) {
        let bytes = Data(text.utf8.prefix(300))
        var message = Data([1])
        message.appendBigEndian(UInt32(bytes.count))
        message.append(bytes)
        send(message)
    }

    private func sendStartApp() {
        // A leading "+" makes the server force-stop the app before starting it.
        let name = Data(((restartsApp ? "+" : "") + package).utf8.prefix(255))
        var message = Data([16, UInt8(name.count)])
        message.append(name)
        send(message)
    }

    /// Android sends a picture only when the screen changes. An app that sits still once
    /// started would leave the window black until something moved, so the capture is started
    /// again, which sends what the screen shows.
    private func askForPictureIfNone(tries: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            stateLock.lock()
            let none = pictures < 2 && !stopped
            stateLock.unlock()
            guard none, tries > 0 else { return }
            send(Data([17])) // reset video
            askForPictureIfNone(tries: tries - 1)
        }
    }

    /// Turns the Android screen, as when turning a phone. Apps locked to one way ignore it.
    func sendRotate() {
        send(Data([11]))
    }

    /// Plugs a HID device into Android, on this app's display only.
    func sendHIDOpen(id: UInt16, vendor: UInt16, product: UInt16, name: String, descriptor: [UInt8]) {
        let nameBytes = Data(name.utf8.prefix(127))
        var message = Data([12])
        message.appendBigEndian(id)
        message.appendBigEndian(vendor)
        message.appendBigEndian(product)
        message.append(UInt8(nameBytes.count))
        message.append(nameBytes)
        message.appendBigEndian(UInt16(descriptor.count))
        message.append(contentsOf: descriptor)
        send(message)
    }

    func sendHIDInput(id: UInt16, report: [UInt8]) {
        var message = Data([13])
        message.appendBigEndian(id)
        message.appendBigEndian(UInt16(report.count))
        message.append(contentsOf: report)
        send(message)
    }

    func sendHIDClose(id: UInt16) {
        var message = Data([14])
        message.appendBigEndian(id)
        send(message)
    }

    private static func scrollFixedPoint(_ value: Double) -> UInt16 {
        let normalized = min(max(value / 16, -1), 1)
        let fixed = normalized >= 1 ? Int16.max : Int16(normalized * 32768)
        return UInt16(bitPattern: fixed)
    }

    private func send(_ message: Data) {
        controlQueue.async { [self] in
            guard !isStopped, controlFD >= 0 else { return }
            message.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let sent = Darwin.send(controlFD, buffer.baseAddress! + offset, buffer.count - offset, 0)
                    if sent <= 0 { return }
                    offset += sent
                }
            }
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendPosition(x: Int, y: Int, width: Int, height: Int) {
        appendBigEndian(Int32(x))
        appendBigEndian(Int32(y))
        appendBigEndian(UInt16(clamping: width))
        appendBigEndian(UInt16(clamping: height))
    }
}
