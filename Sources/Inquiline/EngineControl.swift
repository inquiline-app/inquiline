import Foundation

/// Talks to the engine over QEMU's control socket (QMP), from Inquiline or an app's own process.
///
/// Resting pauses only Android's processors. The engine's network stays awake, and a packet for
/// Android resumes them on its own (Scripts/vm/patches/qemu/0103-wake-on-network.patch), as a
/// phone's modem wakes its processor when a notification arrives.
enum EngineControl {
    static var socket: URL {
        (AndroidRuntime.testHome ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inquiline"))
            .appendingPathComponent("vm/control.sock")
    }

    static func pause() { _ = run("stop") }
    static func resume() { _ = run("cont") }

    /// True while Android rests; false when it runs, or when there is no engine.
    static var isPaused: Bool {
        run("query-status")?.contains("\"status\": \"paused\"") == true
    }

    /// Sends one command and returns its reply, or nil when the engine can't be reached.
    private static func run(_ command: String) -> String? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socket.path.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.withUnsafeBytes { bytes.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var reader = LineReader(fd: fd)
        guard reader.next()?.contains("QMP") == true,
              send("{\"execute\":\"qmp_capabilities\"}", to: fd), reply(&reader) != nil,
              send("{\"execute\":\"\(command)\"}", to: fd)
        else { return nil }
        return reply(&reader)
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
