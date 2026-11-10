import Darwin
import Foundation

/// A small client for Android's adb protocol, talking directly to adbd in the VM.
/// Each stream gets its own connection, so a slow stream can't hold up another.
enum AdbClient {
    private static let port = 5556
    private static let maxPayload = 1 << 20

    /// Runs a command and returns its output. Android's exit status isn't reported.
    /// With a `timeout`, a command that doesn't finish in time returns what it has so far.
    static func shell(_ command: String, timeout: Int = 0) throws -> String {
        try run(service: "shell,raw:\(command)", input: nil, timeout: timeout)
    }

    /// Runs a command that reads exactly the file's size from its standard input.
    static func exec(_ command: String, input: URL) throws -> String {
        try run(service: "exec:\(command)", input: input)
    }

    /// Runs a command and saves its output, which can be binary and large, to a file.
    static func download(_ command: String, to file: URL) throws {
        let connection = try Connection(service: "exec:\(command)")
        defer { connection.close() }
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw RuntimeError("Could not create \(file.lastPathComponent).")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        connection.receive { handle.write($0) }
    }

    /// Opens a stream and returns a socket for it. Closing the socket closes the stream.
    static func open(_ service: String) throws -> Int32 {
        let connection = try Connection(service: service)
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            connection.close()
            throw RuntimeError("Could not create a socket.")
        }
        let (mine, theirs) = (pair[0], pair[1])
        startThread("inquiline.adb-read") {
            connection.receive { data in
                data.withUnsafeBytes { Self.writeAll(mine, $0) }
            }
            // Wakes the writing thread, which closes the socket.
            Darwin.shutdown(mine, SHUT_RDWR)
        }
        startThread("inquiline.adb-write") {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while case let count = recv(mine, &buffer, buffer.count, 0), count > 0 {
                guard (try? connection.send(Data(buffer[0..<count]))) != nil else { break }
            }
            connection.close()
            Darwin.close(mine)
        }
        return theirs
    }

    private static func run(service: String, input: URL?, timeout: Int = 0) throws -> String {
        let connection = try Connection(service: service)
        defer { connection.close() }
        connection.setReceiveTimeout(seconds: timeout)
        if let input {
            startThread("inquiline.adb-input") {
                guard let handle = try? FileHandle(forReadingFrom: input) else { return }
                defer { try? handle.close() }
                while let chunk = try? handle.read(upToCount: maxPayload), !chunk.isEmpty {
                    guard (try? connection.send(chunk)) != nil else { return }
                }
            }
        }
        var output = Data()
        connection.receive { output.append($0) }
        return String(decoding: output, as: UTF8.self)
    }

    private static func startThread(_ name: String, _ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.start()
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < bytes.count {
            let sent = Darwin.send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
            if sent <= 0 { return }
            offset += sent
        }
    }

    private final class Connection {
        private enum Command: UInt32 {
            case connect = 0x4E58_4E43 // CNXN
            case open = 0x4E45_504F // OPEN
            case okay = 0x5941_4B4F // OKAY
            case close = 0x4553_4C43 // CLSE
            case write = 0x4554_5257 // WRTE
        }
        private static let version: UInt32 = 0x0100_0001 // packets without checksums
        private static let localID: UInt32 = 1

        private var fd: Int32 = -1
        private let writeLock = NSLock()
        private let writable = DispatchSemaphore(value: 1)
        private var remoteID: UInt32 = 0
        private var payloadLimit = AdbClient.maxPayload

        init(service: String) throws {
            try connect()
            do {
                try sendPacket(.open, Self.localID, 0, Data((service + "\0").utf8))
                let reply = try readPacket()
                guard reply.command == Command.okay.rawValue else { throw Unavailable() }
                remoteID = reply.arg0
                setReceiveTimeout(seconds: 0)
            } catch {
                Darwin.close(fd)
                throw error
            }
        }

        /// A connection can drop for a few seconds after Android starts, so this
        /// tries again a few times before giving up.
        private func connect() throws {
            var attempts = 10
            while true {
                do {
                    fd = try ScrcpyServer.openSocket(port: AdbClient.port)
                    setReceiveTimeout(seconds: 5)
                    try sendPacket(.connect, Self.version, UInt32(AdbClient.maxPayload), Data("host::\0".utf8))
                    let hello = try readPacket()
                    guard hello.command == Command.connect.rawValue else { throw Unavailable() }
                    payloadLimit = min(payloadLimit, Int(hello.arg1))
                    return
                } catch {
                    if fd >= 0 { Darwin.close(fd) }
                    fd = -1
                    attempts -= 1
                    if attempts == 0 { throw error }
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
        }

        func close() {
            Darwin.shutdown(fd, SHUT_RDWR)
        }

        /// Blocks until the other side has taken the data.
        func send(_ data: Data) throws {
            var offset = 0
            while offset < data.count {
                let end = min(offset + payloadLimit, data.count)
                writable.wait()
                try sendPacket(.write, Self.localID, remoteID, data.subdata(in: offset..<end))
                offset = end
            }
        }

        /// Delivers data until the stream ends, then closes the socket.
        func receive(_ deliver: (Data) -> Void) {
            defer { Darwin.close(fd) }
            while let packet = try? readPacket() {
                switch packet.command {
                case Command.write.rawValue:
                    deliver(packet.payload)
                    guard (try? sendPacket(.okay, Self.localID, remoteID, Data())) != nil else { return }
                case Command.okay.rawValue:
                    writable.signal()
                case Command.close.rawValue:
                    _ = try? sendPacket(.close, Self.localID, remoteID, Data())
                    writable.signal()
                    return
                default:
                    break
                }
            }
            writable.signal()
        }

        func setReceiveTimeout(seconds: Int) {
            var timeout = timeval(tv_sec: seconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        private func sendPacket(_ command: Command, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data) throws {
            var packet = Data(capacity: 24 + payload.count)
            for field in [command.rawValue, arg0, arg1, UInt32(payload.count), 0, ~command.rawValue] {
                Swift.withUnsafeBytes(of: field.littleEndian) { packet.append(contentsOf: $0) }
            }
            packet.append(payload)
            writeLock.lock()
            defer { writeLock.unlock() }
            try packet.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < bytes.count {
                    let sent = Darwin.send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
                    if sent <= 0 { throw Unavailable() }
                    offset += sent
                }
            }
        }

        private func readPacket() throws -> (command: UInt32, arg0: UInt32, arg1: UInt32, payload: Data) {
            let header = try ScrcpyServer.readExactly(24, from: fd)
            func field(_ index: Int) -> UInt32 {
                header[index * 4..<index * 4 + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            }
            let payload = try ScrcpyServer.readExactly(Int(field(3)), from: fd)
            return (field(0), field(1), field(2), payload)
        }

        private struct Unavailable: LocalizedError {
            var errorDescription: String? { "Android isn't ready." }
        }
    }
}
