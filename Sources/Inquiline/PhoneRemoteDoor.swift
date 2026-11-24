import AppKit
import Network
import SystemConfiguration

/// The phone remote's door, in Inquiline itself, which runs as long as Android does: one
/// address that stays the same, so a phone pairs once, from a window's QR code, and keeps the
/// page on its home screen. The page asks here which windows there are and which is in front,
/// and works that one, over the window's own socket (PhoneRemote); when another window comes
/// to the front, the page follows it.
///
/// The address holds a random 128-bit code, kept in Inquiline's folder, which only the user can
/// read; a phone without it gets nothing. The ports stay the same too, unless another app has
/// one, as the home screen's link holds them.
final class PhoneRemoteDoor {
    static let shared = PhoneRemoteDoor()

    private let queue = DispatchQueue(label: "inquiline.phone-remote-door")
    private var page: NWListener?
    private var control: NWListener?
    private var phones: [ObjectIdentifier: NWConnection] = [:]
    private var trusted: Set<ObjectIdentifier> = []
    private var lastState = ""
    private var lastFront: Int32?
    private var timer: DispatchSourceTimer?
    /// Inquiline's apps, as the Dock shows them: package and name, kept up to date by the app.
    private var apps: [(package: String, label: String)] = []
    /// Small icons for the phone, made once each.
    private var smallIcons: [String: Data] = [:]
    /// Opens an app on the Mac, as a click in the Dock does; called on the main queue.
    var onLaunch: ((String) -> Void)?
    private lazy var token: String = {
        let file = PhoneRemote.folder.appendingPathComponent("pairing")
        if let saved = try? String(contentsOf: file, encoding: .utf8), saved.count == 32 { return saved }
        let token = PhoneRemote.newToken()
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }()

    func start() {
        guard page == nil else { return }
        _ = token // made now, for the windows' QR codes
        let defaults = UserDefaults.standard
        page = listen(port: defaults.integer(forKey: "PhoneRemotePagePort"), fallback: 47810, protocols: []) { port in
            defaults.set(port, forKey: "PhoneRemotePagePort")
            // The windows show it in their QR code.
            let door = PhoneRemote.folder.appendingPathComponent("door")
            FileManager.default.createFile(atPath: door.path, contents: Data(String(port).utf8), attributes: [.posixPermissions: 0o600])
        }
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        control = listen(port: defaults.integer(forKey: "PhoneRemoteControlPort"), fallback: 47811, protocols: [options]) { port in
            defaults.set(port, forKey: "PhoneRemoteControlPort")
        }
        page?.newConnectionHandler = { [weak self] in self?.servePage($0) }
        control?.newConnectionHandler = { [weak self] in self?.accept($0) }
        page?.start(queue: queue)
        control?.start(queue: queue)
        // The windows come and go, and the one in front changes; the page hears of both.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.pushState() }
        timer.resume()
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: nil) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, let pid = app?.processIdentifier else { return }
            self.queue.async {
                if self.windows().contains(where: { $0["pid"] as? Int == Int(pid) }) { self.lastFront = pid }
                self.pushState()
            }
        }
    }

    /// Listens on the port the phone already knows, or the first time on a usual one; another
    /// if another app has it.
    private func listen(port saved: Int, fallback: Int, protocols: [NWProtocolOptions],
                        remember: @escaping (Int) -> Void) -> NWListener? {
        func make(_ port: NWEndpoint.Port?) -> NWListener? {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            for item in protocols.reversed() { parameters.defaultProtocolStack.applicationProtocols.insert(item, at: 0) }
            return port.flatMap { try? NWListener(using: parameters, on: $0) } ?? (port == nil ? try? NWListener(using: parameters) : nil)
        }
        let wanted = NWEndpoint.Port(rawValue: UInt16(clamping: saved > 0 ? saved : fallback))
        guard let listener = make(wanted) ?? make(nil) else {
            AppLog.write("The phone remote can't listen")
            return nil
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue { remember(Int(port)) }
            case .failed(let error):
                AppLog.write("The phone remote can't listen: \(error.localizedDescription)")
            default:
                break
            }
        }
        return listener
    }

    // MARK: - The apps

    /// The apps the page lists behind its title, as the Dock shows them.
    func setApps(_ list: [(package: String, label: String)]) {
        queue.async { [self] in
            apps = list
            smallIcons = smallIcons.filter { entry in list.contains { $0.package == entry.key } }
        }
    }

    /// An app's icon at the size the phone shows it (Library keeps them at 1024 pixels).
    private func smallIcon(_ package: String) -> Data? {
        if let cached = smallIcons[package] { return cached }
        guard apps.contains(where: { $0.package == package }),
              let image = NSImage(contentsOf: AndroidRuntime.shared.home.appendingPathComponent("icons/\(package).png")),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 180, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 180, height: 180))
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])
        smallIcons[package] = png
        return png
    }

    private func sendApps(to connection: NWConnection) {
        let list = apps.map { ["p": $0.package, "n": $0.label] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["t": "apps", "apps": list]),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text, to: connection)
    }

    // MARK: - The windows

    /// The open windows that take a phone, from their files; files of windows gone are removed.
    private func windows() -> [[String: Any]] {
        let folder = PhoneRemote.folder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = entry["pid"] as? Int else { return nil }
            guard kill(pid_t(pid), 0) == 0 else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return entry
        }.sorted { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }
    }

    private func pushState() {
        guard !trusted.isEmpty else { return }
        let windows = windows()
        let pids = windows.compactMap { $0["pid"] as? Int }
        let front = Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        if pids.contains(front) { lastFront = pid_t(front) }
        let active = lastFront.map(Int.init).flatMap { pids.contains($0) ? $0 : nil } ?? pids.first
        let state: [String: Any] = ["t": "state", "windows": windows, "active": active ?? 0]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8), text != lastState else { return }
        lastState = text
        for key in trusted { phones[key].map { send(text, to: $0) } }
    }

    private func send(_ text: String, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "state", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: - The page

    private static var macName: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? ""
    }

    private func servePage(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return connection.cancel() }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let base = "/\(self.token)"
            var type = "text/html; charset=utf-8", body: Data?, extra = ""
            switch path {
            case base:
                let port = self.control?.port.map { Int($0.rawValue) } ?? 0
                body = Data(PhoneRemotePage.html(port: port, token: self.token, macName: Self.macName).utf8)
            case base + "/ping":
                type = "text/plain"
                body = Data("ok".utf8)
                // Asked from the page at the Mac's numeric address, to move it to the Mac's name.
                extra = "Access-Control-Allow-Origin: *\r\n"
            case base + "/manifest.json":
                type = "application/manifest+json"
                body = Data(PhoneRemotePage.manifest(token: self.token).utf8)
            case base + "/icon.png":
                type = "image/png"
                body = Self.icon
            case let path where path.hasPrefix(base + "/app-icon/"):
                type = "image/png"
                body = self.smallIcon(String(path.dropFirst(base.count + "/app-icon/".count)))
            default:
                body = nil
            }
            let response: Data
            if let body {
                response = Data(("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\n\(extra)"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8) + body
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Inquiline's icon for the phone's home screen.
    private static let icon: Data? = {
        let size = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSApp.applicationIconImage.draw(in: NSRect(x: 48, y: 48, width: size - 96, height: size - 96))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }()

    // MARK: - The phone

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        phones[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.phones[key] = nil
                self?.trusted.remove(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { return connection.cancel() }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { return connection.cancel() }
            if let data, let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               !self.trusted.contains(ObjectIdentifier(connection)) {
                guard message["t"] as? String == "hello", message["token"] as? String == self.token else {
                    return connection.cancel()
                }
                self.trusted.insert(ObjectIdentifier(connection))
                self.lastState = ""
                self.pushState()
            } else if let data, let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                switch message["t"] as? String {
                case "apps":
                    self.sendApps(to: connection)
                case "launch":
                    if let package = message["p"] as? String, self.apps.contains(where: { $0.package == package }) {
                        DispatchQueue.main.async { self.onLaunch?(package) }
                    }
                default:
                    break
                }
            }
            self.receive(on: connection)
        }
    }
}
