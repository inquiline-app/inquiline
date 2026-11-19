import AppKit
import CoreImage
import Network

/// A phone on the same network as a remote for one app window: its camera reads the QR code the
/// window shows, and its browser opens a page with a controller, a touchpad and the assistant.
/// Nothing to install on the phone, and nothing goes past the local network.
///
/// The page comes from a small web server, and its input over a WebSocket. Both only answer the
/// phone that has the window's code, which is in the QR code: a random 128-bit token, made
/// anew each time the window opens.
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
    private let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    private var page: NWListener?
    private var socket: NWListener?
    private var phones: [ObjectIdentifier: NWConnection] = [:]
    private var trusted: Set<ObjectIdentifier> = []
    private let title: String

    init(title: String) {
        self.title = title
    }

    /// The page's address, once both servers listen; nil when the Mac has no local network.
    func start(_ done: @escaping (URL?) -> Void) {
        guard page == nil else { return done(address) }
        do {
            let page = try NWListener(using: .tcp)
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            let socket = try NWListener(using: parameters)
            self.page = page
            self.socket = socket
            page.newConnectionHandler = { [weak self] in self?.servePage($0) }
            socket.newConnectionHandler = { [weak self] in self?.accept($0) }
            var ready = 0
            for listener in [page, socket] {
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        ready += 1
                        if ready == 2 { DispatchQueue.main.async { done(self.address) } }
                    case .failed(let error):
                        AppLog.write("The phone remote can't listen: \(error.localizedDescription)")
                        DispatchQueue.main.async { done(nil) }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            AppLog.write("The phone remote can't listen: \(error.localizedDescription)")
            done(nil)
        }
    }

    func stop() {
        page?.cancel()
        socket?.cancel()
        page = nil
        socket = nil
        queue.async { [self] in
            phones.values.forEach { $0.cancel() }
            phones = [:]
            trusted = []
        }
    }

    private var address: URL? {
        guard let host = Self.localAddress(), let port = page?.port?.rawValue else { return nil }
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
    private static func localAddress() -> String? {
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

    // MARK: - The page

    private func servePage(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return connection.cancel() }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let response: Data
            if path == "/\(self.token)", let port = self.socket?.port?.rawValue {
                let body = Data(PhoneRemotePage.html(title: self.title, port: Int(port), token: self.token).utf8)
                response = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8) + body
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
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
            // The first message is the code from the QR code; without it the phone is let go.
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
