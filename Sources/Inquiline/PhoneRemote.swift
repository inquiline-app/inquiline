import AppKit
import CDataChannel
import CoreImage
import Network

/// A phone on the same network as a remote for the app windows: a controller, a touchpad and
/// the assistant, in its browser, with nothing to install. Nothing goes past the local network.
///
/// The phone pairs once, from a QR code, with Inquiline itself (PhoneRemoteDoor), whose address
/// stays the same, so the page can live on the phone's home screen. The page then works the
/// window in front on the Mac: each window takes the phone's input itself, here, over its own
/// WebSocket, and tells Inquiline where it listens through a file in Inquiline's folder, which
/// only the user can read (`remote/<pid>.json`). The socket takes only a phone with the
/// window's random code, which the phone gets from Inquiline once paired.
final class PhoneRemote {
    enum Input {
        /// The controller as it is now: sticks from -1 to 1 (down positive), triggers from 0
        /// to 1, buttons as GamepadBridge's report bits, and the d-pad as its hat (0 centered).
        case pad(leftX: Double, leftY: Double, rightX: Double, rightY: Double,
                 leftTrigger: Double, rightTrigger: Double, buttons: UInt16, hat: UInt8)
        /// A finger on the touchpad, at a point from 0 to 1 across the app's screen.
        case touch(ScrcpySession.TouchAction, x: Double, y: Double, finger: Int)
        /// A remote's key, pressed and let go: Back or Play/Pause.
        case key(Int32)
        /// The window's own mute, which works for any app, switched.
        case mute
        case assistant
    }

    /// Called on the remote's own queue, straight from the network, as a finger's moves must
    /// not wait for the window to draw; PhoneInput takes them from there.
    var onInput: ((Input) -> Void)?
    /// How many phones are connected now; called on the main queue.
    var onPhones: ((Int) -> Void)?

    private let queue = DispatchQueue(label: "inquiline.phone-remote")
    private let token = PhoneRemote.newToken()
    private var socket: NWListener?
    private var phones: [ObjectIdentifier: NWConnection] = [:]
    private var trusted: Set<ObjectIdentifier> = []
    private let title: String

    init(title: String) {
        self.title = title
    }

    static func newToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Where the windows and Inquiline meet: only the user can read it.
    static var folder: URL {
        let folder = AndroidRuntime.shared.home.appendingPathComponent("remote")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return folder
    }

    private var registration: URL {
        Self.folder.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json")
    }

    /// Listens, and tells Inquiline, so a paired phone can find this window.
    func start() {
        guard socket == nil else { return }
        do {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            let socket = try NWListener(using: parameters)
            self.socket = socket
            socket.newConnectionHandler = { [weak self] in self?.accept($0) }
            socket.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = socket.port?.rawValue else { return }
                    let entry: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier),
                                                "title": self.title, "port": Int(port), "token": self.token]
                    if let data = try? JSONSerialization.data(withJSONObject: entry) {
                        FileManager.default.createFile(atPath: self.registration.path, contents: data,
                                                       attributes: [.posixPermissions: 0o600])
                    }
                case .failed(let error):
                    AppLog.write("The phone remote can't listen: \(error.localizedDescription)")
                default:
                    break
                }
            }
            socket.start(queue: queue)
        } catch {
            AppLog.write("The phone remote can't listen: \(error.localizedDescription)")
        }
    }

    func stop() {
        try? FileManager.default.removeItem(at: registration)
        socket?.cancel()
        socket = nil
        queue.async { [self] in
            phones.values.forEach { $0.cancel() }
            phones = [:]
            trusted = []
        }
    }

    /// The page's address, at Inquiline's door (PhoneRemoteDoor), by the Mac's address on the
    /// network now; nil without a network, or before Inquiline listens.
    static func pairingAddress() -> URL? {
        guard let host = localAddress(),
              let port = try? String(contentsOf: folder.appendingPathComponent("door"), encoding: .utf8),
              let token = try? String(contentsOf: folder.appendingPathComponent("pairing"), encoding: .utf8)
        else { return nil }
        return URL(string: "http://\(host):\(port)/\(token)")
    }

    /// The QR code for the page, for the camera of a phone.
    static func code(for url: URL, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // A white margin of four modules around it, which cameras need to find a QR code.
        let modules = output.extent.width + 8
        let scale = (size * 2 / modules).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: 4, y: 4))
        let canvas = CGRect(x: 0, y: 0, width: modules * scale, height: modules * scale)
        let framed = scaled.composited(over: CIImage(color: .white).cropped(to: canvas))
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(NSCIImageRep(ciImage: framed))
        return image
    }

    /// The Mac's address on the local network: Wi-Fi's or Ethernet's, as a phone sees it.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let address = String(cString: host)
            // A link-local address is one the router didn't give; the phone can't reach it.
            guard !address.hasPrefix("169.254.") else { continue }
            found.append((String(cString: item.pointee.ifa_name), address))
        }
        return (found.first { $0.name.hasPrefix("en") } ?? found.first)?.address
    }

    // MARK: - The phone's input

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        phones[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(key)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func drop(_ key: ObjectIdentifier) {
        if let peer = peers.removeValue(forKey: key) { peer.close() }
        dropScreen(key)
        padSequence[key] = nil
        guard phones.removeValue(forKey: key) != nil else { return }
        let wasTrusted = trusted.remove(key) != nil
        let count = trusted.count
        if wasTrusted { DispatchQueue.main.async { self.onPhones?(count) } }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { return connection.cancel() }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { return connection.cancel() }
            if let data, metadata?.opcode == .text,
               let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handle(message, from: connection)
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ message: [String: Any], from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard trusted.contains(key) else {
            // The first message is the window's code; without it the phone is let go.
            guard message["t"] as? String == "hello", message["token"] as? String == token else {
                return connection.cancel()
            }
            trusted.insert(key)
            if !shared.isEmpty { signal(shared, key: key) }
            let count = trusted.count
            DispatchQueue.main.async { self.onPhones?(count) }
            return
        }
        switch message["t"] as? String {
        case "rtc-offer":
            guard let sdp = message["sdp"] as? String else { return }
            peers[key]?.close()
            peers[key] = PhonePeer(offer: sdp, key: key, remote: self)
        case "rtc-candidate":
            guard let candidate = message["cand"] as? String else { return }
            peers[key]?.add(candidate: candidate, mid: message["mid"] as? String)
        case "screen-start":
            screenPeers[key]?.close()
            screenPeers[key] = PhoneScreenPeer(key: key, remote: self)
        case "screen-answer":
            guard let sdp = message["sdp"] as? String else { return }
            screenPeers[key]?.answer(sdp)
        case "screen-candidate":
            guard let candidate = message["cand"] as? String else { return }
            screenPeers[key]?.add(candidate: candidate, mid: message["mid"] as? String)
        case "screen-stop":
            dropScreen(key)
        case "screen-fit":
            let width = (message["w"] as? NSNumber)?.doubleValue ?? 0, height = (message["h"] as? NSNumber)?.doubleValue ?? 0
            guard width > 0, height > 0 else { return }
            DispatchQueue.main.async { self.onScreenFit?(width / height) }
        default:
            process(message, key: key)
        }
    }

    // MARK: - WebRTC
    //
    // Over the WebSocket, a packet lost on Wi-Fi holds back every one after it until it's sent
    // again, a tenth of a second or more: a dragged finger stops, then jumps. So the phone
    // also opens a WebRTC data channel, over UDP, unordered and never resent, and sends its
    // moves there: a late one is simply passed by the next. Landing, lifting and letting go
    // still go over the WebSocket, which loses nothing. Without WebRTC, everything does.

    private var peers: [ObjectIdentifier: PhonePeer] = [:]
    /// The latest controller state's number per phone, as states come over both ways, and an
    /// older one must not undo a newer one.
    private var padSequence: [ObjectIdentifier: Double] = [:]

    // MARK: - The window's picture on the phone
    //
    // A phone asks for the window's picture; the Mac offers it as an H.264 video track on a
    // WebRTC connection of its own (as libdatachannel's streamer), which the phone's browser
    // plays: nothing to install. One encoder (PhoneScreen) for every phone that watches; none
    // while no phone does.

    /// For the encoder; set by the window.
    var screenDevice: MTLDevice?
    /// The window's frames go to the encoder, or stop (nil); called on the main queue.
    var onScreen: ((PhoneScreen?) -> Void)?
    /// Whether the window takes the phone's shape (a flexible app), so the phone turns freely.
    var windowFits = false
    /// The shape (width over height) of a phone showing the window; called on the main queue.
    var onScreenFit: ((Double) -> Void)?
    private var screenPeers: [ObjectIdentifier: PhoneScreenPeer] = [:]
    private var screen: PhoneScreen?

    /// On `queue`.
    fileprivate func screenOpened(_ key: ObjectIdentifier) {
        if screen == nil, let device = screenDevice, let made = PhoneScreen(device: device) {
            made.onFrame = { [weak self] data, seconds in
                self?.queue.async { self?.screenPeers.values.forEach { $0.send(data, seconds: seconds) } }
            }
            screen = made
            DispatchQueue.main.async { self.onScreen?(made) }
            AppLog.write("A phone shows the window")
        }
        screen?.keyFrame()
    }

    fileprivate func screenTrackOpened(_ peer: PhoneScreenPeer) {
        queue.async { [self] in
            guard screenPeers[peer.key] === peer else { return }
            peer.markOpen()
            screenOpened(peer.key)
        }
    }

    fileprivate func screenPeerLost(_ peer: PhoneScreenPeer) {
        queue.async { [self] in
            guard screenPeers[peer.key] === peer else { return }
            AppLog.write("The phone showing the window is gone")
            dropScreen(peer.key)
        }
    }

    fileprivate func screenWantsKeyFrame() {
        screen?.keyFrame()
    }

    /// On `queue`.
    private func dropScreen(_ key: ObjectIdentifier) {
        screenPeers.removeValue(forKey: key)?.close()
        guard screenPeers.isEmpty, let ended = screen else { return }
        screen = nil
        DispatchQueue.main.async {
            self.onScreen?(nil)
            ended.stop()
        }
        AppLog.write("No phone shows the window")
    }

    /// What the phone shows of the window, as the window has it now: whether it's muted. Sent
    /// to every phone when it changes, and to a phone when it connects.
    private var shared: [String: Any] = [:]

    func share(muted: Bool) {
        queue.async { [self] in
            shared = ["t": "state", "muted": muted]
            for key in trusted { signal(shared, key: key) }
        }
    }

    /// To the phone, over its WebSocket: the Mac's answer and its addresses.
    fileprivate func signal(_ message: [String: Any], key: ObjectIdentifier) {
        queue.async { [self] in
            guard let connection = phones[key], let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "signal", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    /// Input from a phone's data channel.
    fileprivate func channelMessage(_ data: Data, key: ObjectIdentifier) {
        queue.async { [self] in
            guard trusted.contains(key), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            process(message, key: key)
        }
    }

    private func process(_ message: [String: Any], key: ObjectIdentifier) {
        func number(_ name: String) -> Double { (message[name] as? NSNumber)?.doubleValue ?? 0 }
        let input: Input
        switch message["t"] as? String {
        case "pad":
            let sequence = number("s")
            if sequence > 0 {
                guard sequence > padSequence[key] ?? 0 else { return }
                padSequence[key] = sequence
            }
            input = .pad(leftX: number("lx"), leftY: number("ly"), rightX: number("rx"), rightY: number("ry"),
                         leftTrigger: number("lt"), rightTrigger: number("rt"),
                         buttons: UInt16(clamping: Int(number("b"))), hat: UInt8(clamping: Int(number("hat"))))
        case "touch":
            let actions: [String: ScrcpySession.TouchAction] = ["down": .down, "move": .move, "up": .up]
            guard let action = actions[message["a"] as? String ?? ""] else { return }
            input = .touch(action, x: min(max(number("x"), 0), 1), y: min(max(number("y"), 0), 1),
                           finger: Int(number("id")) % 10)
        case "key":
            if message["k"] as? String == "mute" { input = .mute; break }
            // Android's keycodes for the remote's keys: Back, Play/Pause.
            let keys: [String: Int32] = ["back": 4, "playpause": 85]
            guard let code = keys[message["k"] as? String ?? ""] else { return }
            input = .key(code)
        case "assistant":
            input = .assistant
        default:
            return
        }
        onInput?(input)
    }
}

/// A phone's input for one window's Android screen, sent from the network's queue as it comes:
/// the window keeps it up to date with its session, screen size and task.
final class PhoneInput {
    private let lock = NSLock()
    private var session: ScrcpySession?
    private var width = 0, height = 0
    private var task: Int?
    private var plugged = false
    private var lastActive = Date.distantPast
    /// How evenly a drag's moves arrive, for the log: the network, not the app, if uneven.
    private var dragStart: TimeInterval = 0, lastMove: TimeInterval = 0, longestGap: TimeInterval = 0, moves = 0
    /// Called on the main queue.
    var onAssistant: (() -> Void)?
    /// The phone's mute key, for the window's own mute; called on the main queue.
    var onMute: (() -> Void)?
    /// A touchpad finger, for showing it on the Mac; called on the main queue.
    var onTouch: ((ScrcpySession.TouchAction, Double, Double, Int) -> Void)?

    /// The phone's controller in Android, after the Mac's own (GamepadBridge, 3 to 10).
    private static let padID: UInt16 = 11

    // MARK: Smooth fingers
    //
    // Over Wi-Fi a finger's moves come unevenly: in bursts, and with gaps of a tenth of a second
    // or more while a lost packet is sent again or the phone's radio naps. Sent as they come, a
    // dragged ship stops and jumps. So they go to Android at a steady 120 a second instead: each
    // finger glides to where it was last seen, and through a gap keeps going the way it went,
    // for up to 130 ms, as it most likely did.

    private struct Finger {
        var x: Double, y: Double, time: TimeInterval
        var vx = 0.0, vy = 0.0
        var shownX: Double, shownY: Double

        init(x: Double, y: Double, time: TimeInterval) {
            self.x = x; self.y = y; self.time = time
            shownX = x; shownY = y
        }

        mutating func received(x: Double, y: Double, time: TimeInterval) {
            let dt = max(time - self.time, 0.008)
            // Speed from the last two places, evened out over a few, as single ones jitter.
            vx = vx * 0.5 + (x - self.x) / dt * 0.5
            vy = vy * 0.5 + (y - self.y) / dt * 0.5
            self.x = x; self.y = y; self.time = time
        }

        /// Where the finger likely is now: seen, or a little on along its way through a gap.
        func expected(at now: TimeInterval) -> (Double, Double) {
            let ahead = min(max(now - time, 0), 0.13)
            return (min(max(x + vx * ahead, 0), 1), min(max(y + vy * ahead, 0), 1))
        }
    }

    private var fingers: [Int: Finger] = [:]
    private var pacer: DispatchSourceTimer?
    private let pacing = DispatchQueue(label: "inquiline.phone-fingers", qos: .userInteractive)

    private func startPacing() {
        guard pacer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: pacing)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .nanoseconds(500_000))
        timer.setEventHandler { [weak self] in self?.pace() }
        timer.resume()
        pacer = timer
    }

    private func pace() {
        lock.lock(); defer { lock.unlock() }
        guard !fingers.isEmpty else {
            pacer?.cancel()
            pacer = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (id, var finger) in fingers {
            let (x, y) = finger.expected(at: now)
            // Most of the way there each tick: smooth, and only a few milliseconds behind.
            let nextX = finger.shownX + (x - finger.shownX) * 0.6
            let nextY = finger.shownY + (y - finger.shownY) * 0.6
            guard abs(nextX - finger.shownX) * Double(width) >= 0.5 || abs(nextY - finger.shownY) * Double(height) >= 0.5
            else { continue }
            finger.shownX = nextX; finger.shownY = nextY
            fingers[id] = finger
            send(.move, x: nextX, y: nextY, finger: id)
        }
    }

    /// Called with the lock held.
    private func send(_ action: ScrcpySession.TouchAction, x: Double, y: Double, finger: Int) {
        guard let session, width > 0, height > 0 else { return }
        // Fingers of their own, apart from the mouse's and the keyboard controls'.
        session.sendTouch(action, x: Int(x * Double(width)), y: Int(y * Double(height)),
                          width: width, height: height, finger: Int64(20 + finger))
        if let onTouch { DispatchQueue.main.async { onTouch(action, x, y, finger) } }
    }

    func update(session: ScrcpySession? = nil, size: NSSize? = nil, task: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let session, session !== self.session {
            self.session = session
            // A new session's Android screen has no phone controller until the phone uses it.
            plugged = false
        }
        if let size { width = Int(size.width); height = Int(size.height) }
        if let task { self.task = task }
    }

    /// No phone is connected, or the window closes: the controller is unplugged.
    func unplug() {
        lock.lock(); defer { lock.unlock() }
        if plugged { session?.sendHIDClose(id: Self.padID) }
        plugged = false
    }

    func handle(_ input: PhoneRemote.Input) {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return }
        switch input {
        case let .pad(lx, ly, rx, ry, lt, rt, buttons, hat):
            let active = buttons != 0 || hat != 0 || lt > 0 || rt > 0 || lx != 0 || ly != 0 || rx != 0 || ry != 0
            // Plugged in with the first use, so a phone used only as a touchpad isn't a controller.
            if !plugged {
                guard active else { return }
                session.sendHIDOpen(id: Self.padID, vendor: 0x045E, product: 0x028E, name: "Microsoft X-Box 360 Pad",
                                    descriptor: GamepadBridge.descriptor)
                plugged = true
            }
            // A controller's buttons go to the app in focus, which a click on the Mac doesn't change
            // and touches on another window do; so the phone's controller brings its app into focus
            // when it starts being used again.
            if active, Date().timeIntervalSince(lastActive) > 2, let task {
                DispatchQueue.global().async { AndroidRuntime.shared.focus(task: task) }
            }
            if active { lastActive = Date() }
            session.sendHIDInput(id: Self.padID, report: GamepadBridge.report(
                leftX: lx, leftY: ly, rightX: rx, rightY: ry, leftTrigger: lt, rightTrigger: rt, buttons: buttons, hat: hat))
        case let .touch(action, x, y, finger):
            guard width > 0, height > 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch action {
            case .down: dragStart = now; lastMove = now; longestGap = 0; moves = 0
            case .move: longestGap = max(longestGap, now - lastMove); lastMove = now; moves += 1
            case .up:
                if moves >= 30 {
                    let seconds = now - dragStart
                    AppLog.write(String(format: "Phone drag: %d moves in %.1f s (%.0f a second), longest gap %.0f ms",
                                        moves, seconds, Double(moves) / seconds, longestGap * 1000))
                }
            }
            switch action {
            case .down:
                fingers[finger] = Finger(x: x, y: y, time: now)
                send(.down, x: x, y: y, finger: finger)
                startPacing()
            case .move:
                fingers[finger]?.received(x: x, y: y, time: now)
            case .up:
                fingers[finger] = nil
                send(.up, x: x, y: y, finger: finger)
            }
        case let .key(code):
            session.sendKey(.down, keycode: code)
            session.sendKey(.up, keycode: code)
        case .mute:
            DispatchQueue.main.async { self.onMute?() }
        case .assistant:
            DispatchQueue.main.async { self.onAssistant?() }
        }
    }
}

/// One phone's WebRTC connection (libdatachannel): it answers the phone's offer, and hands the
/// remote what comes over the phone's data channel. The phone and the Mac are on one network,
/// so the Mac's own addresses are all it offers: nothing goes through a server outside.
private final class PhonePeer {
    private let pc: Int32
    let key: ObjectIdentifier
    weak var remote: PhoneRemote?
    private var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    init(offer: String, key: ObjectIdentifier, remote: PhoneRemote) {
        self.key = key
        self.remote = remote
        var config = rtcConfiguration()
        config.iceServersCount = 0
        config.disableAutoNegotiation = false
        pc = rtcCreatePeerConnection(&config)
        guard pc >= 0 else { return }
        rtcSetUserPointer(pc, pointer)
        rtcSetLocalDescriptionCallback(pc) { _, sdp, type, user in
            guard let user, let sdp, let type else { return }
            let peer = Unmanaged<PhonePeer>.fromOpaque(user).takeUnretainedValue()
            peer.remote?.signal(["t": "rtc-answer", "sdp": String(cString: sdp), "type": String(cString: type)], key: peer.key)
        }
        rtcSetLocalCandidateCallback(pc) { _, candidate, mid, user in
            guard let user, let candidate else { return }
            let peer = Unmanaged<PhonePeer>.fromOpaque(user).takeUnretainedValue()
            peer.remote?.signal(["t": "rtc-candidate", "cand": String(cString: candidate),
                                 "mid": mid.map { String(cString: $0) } ?? "0"], key: peer.key)
        }
        rtcSetDataChannelCallback(pc) { _, channel, user in
            guard let user else { return }
            rtcSetUserPointer(channel, user)
            rtcSetOpenCallback(channel) { _, _ in AppLog.write("The phone's WebRTC channel is open") }
            rtcSetMessageCallback(channel) { _, message, size, user in
                guard let user, let message else { return }
                let peer = Unmanaged<PhonePeer>.fromOpaque(user).takeUnretainedValue()
                // A negative size is a string, ended by a zero.
                let data = size < 0 ? Data(String(cString: message).utf8)
                    : Data(bytes: message, count: Int(size))
                peer.remote?.channelMessage(data, key: peer.key)
            }
        }
        rtcSetRemoteDescription(pc, offer, "offer")
    }

    func add(candidate: String, mid: String?) {
        guard pc >= 0 else { return }
        rtcAddRemoteCandidate(pc, candidate, mid ?? "0")
    }

    func close() {
        guard pc >= 0 else { return }
        rtcDeletePeerConnection(pc)
    }
}

/// A phone's view of the window: a WebRTC connection the Mac offers, with one H.264 video track
/// the Mac only sends, packetized by libdatachannel, which also answers the phone's reports:
/// a lost packet is sent again (NACK), a lost picture brings a key frame (PLI).
private final class PhoneScreenPeer {
    private let pc: Int32
    private var track: Int32 = -1
    let key: ObjectIdentifier
    weak var remote: PhoneRemote?
    private var open = false
    private var startTimestamp: UInt32 = 0
    private var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    init(key: ObjectIdentifier, remote: PhoneRemote) {
        self.key = key
        self.remote = remote
        var config = rtcConfiguration()
        config.iceServersCount = 0
        config.disableAutoNegotiation = true
        pc = rtcCreatePeerConnection(&config)
        guard pc >= 0 else { return }
        rtcSetUserPointer(pc, pointer)
        rtcSetLocalDescriptionCallback(pc) { _, sdp, type, user in
            guard let user, let sdp, let type else { return }
            let peer = Unmanaged<PhoneScreenPeer>.fromOpaque(user).takeUnretainedValue()
            peer.remote?.signal(["t": "screen-offer", "sdp": String(cString: sdp), "type": String(cString: type),
                                 "fits": peer.remote?.windowFits ?? false], key: peer.key)
        }
        rtcSetLocalCandidateCallback(pc) { _, candidate, mid, user in
            guard let user, let candidate else { return }
            let peer = Unmanaged<PhoneScreenPeer>.fromOpaque(user).takeUnretainedValue()
            peer.remote?.signal(["t": "screen-candidate", "cand": String(cString: candidate),
                                 "mid": mid.map { String(cString: $0) } ?? "video"], key: peer.key)
        }
        // A phone gone without a word (locked, out of Wi-Fi, out of battery): the connection
        // stops answering, and the window is the Mac's again.
        rtcSetStateChangeCallback(pc) { _, state, user in
            guard let user, state == RTC_DISCONNECTED || state == RTC_FAILED || state == RTC_CLOSED else { return }
            let peer = Unmanaged<PhoneScreenPeer>.fromOpaque(user).takeUnretainedValue()
            peer.remote?.screenPeerLost(peer)
        }
        let ssrc = UInt32.random(in: 1...UInt32.max)
        startTimestamp = UInt32.random(in: 0...UInt32.max)
        // Constrained baseline, as the encoder makes it: every phone's browser plays it in hardware.
        track = "video".withCString { mid in
            "screen".withCString { name in
                "profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1".withCString { profile in
                    var init_ = rtcTrackInit(direction: RTC_DIRECTION_SENDONLY, codec: RTC_CODEC_H264, payloadType: 96,
                                             ssrc: ssrc, mid: mid, name: name, msid: name, trackId: name, profile: profile)
                    return rtcAddTrackEx(pc, &init_)
                }
            }
        }
        guard track >= 0 else { return }
        rtcSetUserPointer(track, pointer)
        var packetizer = rtcPacketizerInit()
        packetizer.ssrc = ssrc
        packetizer.payloadType = 96
        packetizer.clockRate = 90_000
        packetizer.timestamp = startTimestamp
        packetizer.nalSeparator = RTC_NAL_SEPARATOR_LENGTH
        "screen".withCString { cname in
            packetizer.cname = cname
            rtcSetH264Packetizer(track, &packetizer)
        }
        rtcChainRtcpSrReporter(track)
        rtcChainRtcpNackResponder(track, 512)
        rtcChainPliHandler(track) { _, user in
            guard let user else { return }
            let peer = Unmanaged<PhoneScreenPeer>.fromOpaque(user).takeUnretainedValue()
            peer.remote?.screenWantsKeyFrame()
        }
        rtcSetOpenCallback(track) { _, user in
            guard let user else { return }
            let peer = Unmanaged<PhoneScreenPeer>.fromOpaque(user).takeUnretainedValue()
            peer.remote?.screenTrackOpened(peer)
        }
        rtcSetLocalDescription(pc, "offer")
    }

    /// On the remote's queue.
    fileprivate func markOpen() { open = true }

    func answer(_ sdp: String) {
        guard pc >= 0 else { return }
        rtcSetRemoteDescription(pc, sdp, "answer")
    }

    func add(candidate: String, mid: String?) {
        guard pc >= 0 else { return }
        rtcAddRemoteCandidate(pc, candidate, mid ?? "video")
    }

    /// An access unit, at its time from the stream's start. On the remote's queue.
    func send(_ data: Data, seconds: Double) {
        guard open, track >= 0 else { return }
        var elapsed: UInt32 = 0
        rtcTransformSecondsToTimestamp(track, seconds, &elapsed)
        rtcSetTrackRtpTimestamp(track, startTimestamp &+ elapsed)
        data.withUnsafeBytes { bytes in
            _ = rtcSendMessage(track, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
        }
    }

    func close() {
        open = false
        // No callback may reach this peer once it's gone.
        if track >= 0 { rtcSetUserPointer(track, nil) }
        if pc >= 0 {
            rtcSetUserPointer(pc, nil)
            rtcDeletePeerConnection(pc)
        }
    }
}
