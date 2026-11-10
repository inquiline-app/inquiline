import Darwin
import Foundation

/// Starts scrcpy-server on Android and opens its sockets. The server version must
/// match the scrcpy-server file in the app bundle.
enum ScrcpyServer {
    private static let version = "5.0.1"
    private static let remotePath = "/data/local/tmp/inquiline-scrcpy-server.jar"
    /// The server's native part, which names the GPU resource of each frame. It loads it from here.
    private static let framesLibraryPath = "/data/local/tmp/libinquiline-frames.so"

    static func push() throws {
        guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil),
              let library = Bundle.main.url(forResource: "libinquiline-frames", withExtension: "so")
        else {
            throw RuntimeError("scrcpy-server is missing from the app bundle.")
        }
        // Each file is written beside the old one and renamed over it, as installers do: servers
        // of apps already open keep running from the old file, which rewriting in place would
        // change under them.
        for (file, path) in [(jar, remotePath), (library, framesLibraryPath)] {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            _ = try AdbClient.exec(
                "sh -c 'head -c \(size) > \(path).$$ && chmod 644 \(path).$$ && mv -f \(path).$$ \(path)'",
                input: file)
        }
    }

    /// Runs as Android's system user: on Android 15 the shell user can't create
    /// the trusted virtual displays that app windows use. Our build of the server
    /// names the matching package, "android". Closing the returned socket stops it.
    static func launch(parameters: [String]) throws -> Int32 {
        let command = "CLASSPATH=\(remotePath) app_process / com.genymobile.scrcpy.Server \(version) "
            + parameters.joined(separator: " ")
        let fd = try AdbClient.open("shell,raw:su 1000 sh -c '\(command)'")
        // The server must never block on its log output.
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while recv(fd, &buffer, buffer.count, 0) > 0 {}
        }
        thread.name = "inquiline.server-output"
        thread.start()
        return fd
    }

    /// The stream fails until the server listens, and it counts once the
    /// server's first byte arrives.
    static func connectFirstSocket(scid: String, isCancelled: () -> Bool) throws -> Int32 {
        let deadline = Date().addingTimeInterval(15)
        while true {
            if isCancelled() { throw RuntimeError("Session closed.") }
            if let fd = try? openStream(scid: scid) {
                var byte: UInt8 = 0
                if recv(fd, &byte, 1, 0) == 1 { return fd }
                close(fd)
            }
            if Date() > deadline { throw RuntimeError("The display server did not start.") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func openStream(scid: String) throws -> Int32 {
        try AdbClient.open("localabstract:scrcpy_\(scid)")
    }

    static func openSocket(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeError("Could not create a socket.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw RuntimeError("Could not connect to the display server.")
        }
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            while offset < count {
                let received = recv(fd, buffer.baseAddress! + offset, count - offset, 0)
                if received <= 0 { throw EndOfStream() }
                offset += received
            }
        }
        return data
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private struct EndOfStream: LocalizedError {
        var errorDescription: String? { "The app's display stream ended." }
    }
}
