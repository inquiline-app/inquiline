import AppKit
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
        case assistant
    }

    /// Called on the main queue.
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
            let parameters = NWParameters.tcp
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
            let count = trusted.count
            DispatchQueue.main.async { self.onPhones?(count) }
            return
        }
        func number(_ name: String) -> Double { (message[name] as? NSNumber)?.doubleValue ?? 0 }
        let input: Input
        switch message["t"] as? String {
        case "pad":
            input = .pad(leftX: number("lx"), leftY: number("ly"), rightX: number("rx"), rightY: number("ry"),
                         leftTrigger: number("lt"), rightTrigger: number("rt"),
                         buttons: UInt16(clamping: Int(number("b"))), hat: UInt8(clamping: Int(number("hat"))))
        case "touch":
            let actions: [String: ScrcpySession.TouchAction] = ["down": .down, "move": .move, "up": .up]
            guard let action = actions[message["a"] as? String ?? ""] else { return }
            input = .touch(action, x: min(max(number("x"), 0), 1), y: min(max(number("y"), 0), 1),
                           finger: Int(number("id")) % 10)
        case "assistant":
            input = .assistant
        default:
            return
        }
        DispatchQueue.main.async { self.onInput?(input) }
    }
}
