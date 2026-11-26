import Foundation

/// Talks to the engine over QEMU's control socket (QMP), from Inquiline or an app's own process.
///
/// When Android sleeps, only its processors pause. The engine's network stays awake, and a packet
/// for Android resumes them on its own (Scripts/vm/patches/qemu/0103-wake-on-network.patch), as a
/// phone's modem wakes its processor when a notification arrives.
enum EngineControl {
    static var socket: URL {
        (AndroidRuntime.testHome ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inquiline"))
            .appendingPathComponent("vm/control.sock")
    }

    /// The engine's events, as Android starting again, come on a socket of their own, as each
    /// takes one connection at a time.
    static var eventsSocket: URL { socket.deletingLastPathComponent().appendingPathComponent("events.sock") }

    static func pause() { _ = run("stop") }
    static func resume() { _ = run("cont") }

    /// Called on a background thread whenever Android's processors start again, by
    /// Inquiline or by the engine for a packet.
    static var onResume: (() -> Void)? {
        didSet { if onResume != nil { watchEvents() } }
    }

    /// Keeps a connection open for the engine's events, again after it restarts.
    private static func watchEvents() {
        Thread.detachNewThread {
            while true {
                if let fd = connect(to: eventsSocket) {
                    var reader = LineReader(fd: fd)
                    var timeout = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    if reader.next()?.contains("QMP") == true, send("{\"execute\":\"qmp_capabilities\"}", to: fd) {
                        while let line = reader.next() {
                            if line.contains("\"event\": \"RESUME\"") { onResume?() }
                        }
                    }
                    close(fd)
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    /// True while Android rests; false when it runs, or when there is no engine.
    static var isPaused: Bool {
        run("query-status")?.contains("\"status\": \"paused\"") == true
    }

    /// How long the sound the engine has just been given waits before the Mac's sound device plays
    /// it, in seconds (its virtio-sound's "output-delay-us", QEMU patch 0108); nil while unknown.
    static var soundDelay: Double? {
        guard let line = run("qom-get", arguments: "{\"path\":\"/machine/peripheral/sound/virtio-backend\",\"property\":\"output-delay-us\"}"),
              let range = line.range(of: #""return": *(-?[0-9]+)"#, options: .regularExpression),
              let micro = Double(line[range].split(separator: ":").last!.trimmingCharacters(in: .whitespaces)),
              micro > 0
        else { return nil }
        return micro / 1_000_000
    }

    /// Sends one command and returns its reply, or nil when the engine can't be reached.
    private static func run(_ command: String, arguments: String? = nil) -> String? {
        guard let fd = connect(to: socket) else { return nil }
        defer { close(fd) }
        var reader = LineReader(fd: fd)
        guard reader.next()?.contains("QMP") == true,
              send("{\"execute\":\"qmp_capabilities\"}", to: fd), reply(&reader) != nil,
              send(arguments.map { "{\"execute\":\"\(command)\",\"arguments\":\($0)}" } ?? "{\"execute\":\"\(command)\"}", to: fd)
        else { return nil }
        return reply(&reader)
    }

    private static func connect(to socket: URL) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socket.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.withUnsafeBytes { bytes.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    private static func send(_ line: String, to fd: Int32) -> Bool {
        let data = Array((line + "\n").utf8)
        return write(fd, data, data.count) == data.count
    }

    /// The command's answer; events the engine sends meanwhile are skipped.
    private static func reply(_ reader: inout LineReader) -> String? {
        while let line = reader.next() {
            if line.contains("\"return\"") || line.contains("\"error\"") { return line }
        }
        return nil
    }

    private struct LineReader {
        let fd: Int32
        var buffer = [UInt8]()

        mutating func next() -> String? {
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[..<end], as: UTF8.self)
                    buffer.removeSubrange(...end)
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer += chunk[..<count]
            }
        }
    }
}
