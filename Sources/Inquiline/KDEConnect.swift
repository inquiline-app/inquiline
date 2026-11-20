import Foundation
import Security

/// Android's notifications reach the Mac through KDE Connect, the open-source app that has
/// carried phones' notifications to computers for years: its unmodified Android app
/// (Vendor/kdeconnect.apk, GPL, from F-Droid) runs inside Android, and Inquiline is the computer
/// it is paired with, speaking its protocol (invent.kde.org/network/kdeconnect-meta, protocol.md).
/// The user never sees KDE Connect: Inquiline pairs them itself, as their trusted device, and
/// shows what arrives as the Mac's own notifications (NotificationBridge).
///
/// Inquiline reaches Android's KDE Connect over a Unix socket the engine forwards to its TCP
/// port 1716, as it does adb's. Whoever opens the TCP connection is the TLS server in KDE
/// Connect, so after the plain identity line the Mac answers the handshake as the server
/// (SecureTransport, which can take either side on any socket), with a certificate whose common
/// name is its device id. Android's certificate is pinned: the one KDE Connect keeps in Android.
final class KDEConnect {
    static let shared = KDEConnect()

    static let package = "org.kde.kdeconnect_tp"
    private static let version = 13703
    private static let listener = "org.kde.kdeconnect.plugins.notifications.NotificationReceiver"
    private static let service = "org.kde.kdeconnect.BackgroundService"
    fileprivate static let label = "Inquiline KDE Connect"

    /// A packet from Android: its type and body.
    var received: ((String, [String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "inquiline.kdeconnect")
    private var link: Link?
    private var connecting = false

    /// Called whenever Android is ready: connects once, and again when the connection ends
    /// while Android runs.
    func start() {
        queue.async { [self] in
            guard link == nil, !connecting else { return }
            connecting = true
            defer { connecting = false }
            do {
                let me = try Identity.load()
                let android = try prepareAndroid(trusting: me)
                let link = try Link.open(socket: AndroidRuntime.shared.kdeConnectSocket, me: me, android: android)
                self.link = link
                link.send("kdeconnect.notification.request", ["request": true])
                Thread.detachNewThread { [self] in
                    link.read { type, body in self.received?(type, body) }
                    queue.async { [self] in
                        if self.link === link { self.link = nil }
                    }
                    queue.asyncAfter(deadline: .now() + 3) { [self] in
                        if AndroidRuntime.shared.isRunning { start() }
                    }
                }
            } catch {
                AppLog.write("Notifications aren't available: \(error.localizedDescription)")
                queue.asyncAfter(deadline: .now() + 10) { [self] in
                    if AndroidRuntime.shared.isRunning { start() }
                }
            }
        }
    }

    /// Sends a packet to Android's KDE Connect, when connected.
    func send(_ type: String, _ body: [String: Any]) {
        queue.async { [self] in link?.send(type, body) }
    }

    // MARK: - Android's side

    fileprivate struct Android {
        let id: String
        let certificate: Data
    }

    /// Installs KDE Connect in Android when it isn't there, lets it read notifications and
    /// run in the background, and makes the Mac its trusted device: what pairing would store.
    private func prepareAndroid(trusting me: Identity) throws -> Android {
        let pkg = Self.package
        let installed = (try? AdbClient.shell("pm list packages --show-versioncode \(pkg)")) ?? ""
        let current = installed.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        if current < Self.version {
            guard let apk = Bundle.main.url(forResource: "kdeconnect", withExtension: "apk"),
                  let size = try apk.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { throw RuntimeError("KDE Connect is missing from the app bundle.") }
            let result = try AdbClient.exec("cmd package install -S \(size) -r", input: apk)
            guard result.contains("Success") else { throw RuntimeError("Could not add KDE Connect.") }
        }
        _ = try AdbClient.shell("cmd notification allow_listener \(pkg)/\(Self.listener); "
                                + "pm grant \(pkg) android.permission.POST_NOTIFICATIONS 2>/dev/null; "
                                + "su 0 dumpsys deviceidle whitelist +\(pkg) >/dev/null")
        let prefs = "/data/data/\(pkg)/shared_prefs"
        // Its own id and certificate, which it makes the first time it runs.
        var own = ""
        for _ in 0..<20 {
            own = (try? AdbClient.shell("su 0 cat \(prefs)/\(pkg)_preferences.xml 2>/dev/null")) ?? ""
            if own.contains("name=\"certificate\"") && own.contains("device_id_preference") { break }
            _ = try? AdbClient.shell("su 0 am start-foreground-service -n \(pkg)/\(Self.service) >/dev/null 2>&1")
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let id = Self.xmlValue(own, "device_id_preference"),
              let certificate = Self.xmlValue(own, "certificate").flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) })
        else { throw RuntimeError("KDE Connect didn't start in Android.") }

        // The Mac as its trusted device, unless it already is, with this certificate.
        let mine = me.certificate.base64EncodedString()
        let stored = (try? AdbClient.shell("su 0 cat \(prefs)/\(me.id).xml \(prefs)/trusted_devices.xml 2>/dev/null")) ?? ""
        if !(stored.contains(mine) && stored.contains("name=\"\(me.id)\" value=\"true\"")) {
            let trusted = """
            <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
            <map>
                <boolean name="\(me.id)" value="true" />
            </map>
            """
            let device = """
            <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
            <map>
                <string name="certificate">\(mine)</string>
                <string name="deviceName">Mac</string>
                <string name="deviceType">desktop</string>
                <int name="protocolVersion" value="8" />
            </map>
            """
            let write = { (name: String, text: String) in
                "echo \(Data(text.utf8).base64EncodedString()) | base64 -d > \(prefs)/\(name); "
            }
            let script = "am force-stop \(pkg); mkdir -p \(prefs); "
                + write("trusted_devices.xml", trusted) + write("\(me.id).xml", device)
                + "u=$(stat -c %u /data/data/\(pkg)); chown $u:$u \(prefs) \(prefs)/*; chmod 660 \(prefs)/*; "
                + "restorecon -R \(prefs) 2>/dev/null; am start-foreground-service -n \(pkg)/\(Self.service) >/dev/null"
            _ = try AdbClient.shell("su 0 sh -c '\(script)'")
            AppLog.write("KDE Connect in Android now trusts this Mac")
        } else {
            _ = try? AdbClient.shell("su 0 am start-foreground-service -n \(pkg)/\(Self.service) >/dev/null 2>&1")
        }
        return Android(id: id, certificate: certificate)
    }

    /// A value in an Android SharedPreferences file, its XML escapes undone.
    private static func xmlValue(_ xml: String, _ name: String) -> String? {
        guard let start = xml.range(of: "name=\"\(name)\">"),
              let end = xml.range(of: "</string>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "&#10;", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The Mac's identity

    /// The Mac as a KDE Connect device: an id, and an EC P-256 key with a self-signed certificate
    /// whose common name is the id, as KDE Connect makes its own. Kept in the login Keychain.
    struct Identity {
        let id: String
        let identity: SecIdentity
        let certificate: Data

        /// The certificate is a file beside Android's disk; its key stays in the Keychain.
        private static var file: URL { AndroidRuntime.shared.kdeConnectCertificate }

        static func load() throws -> Identity {
            if let der = try? Data(contentsOf: file), let found = identity(der) { return found }
            // None yet, or its key is gone: a new one, with no older key left behind.
            let stale: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrLabel: KDEConnect.label]
            while SecItemDelete(stale as CFDictionary) == errSecSuccess {}
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            var error: Unmanaged<CFError>?
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits: 256,
                kSecAttrLabel: KDEConnect.label,
                kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrLabel: KDEConnect.label],
            ]
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
                  let publicKey = SecKeyCopyPublicKey(key),
                  let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
                  let der = Certificate.make(id: id, publicKey: point, signer: key)
            else { throw RuntimeError("Could not make this Mac's notification certificate.") }
            try der.write(to: file, options: .atomic)
            guard let made = identity(der) else {
                throw RuntimeError("Could not use this Mac's notification certificate.")
            }
            return made
        }

        /// The identity the certificate and its key in the Keychain make; only for a certificate
        /// whose common name is a KDE Connect device id.
        private static func identity(_ der: Data) -> Identity? {
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
            var name: CFString?
            SecCertificateCopyCommonName(certificate, &name)
            guard let id = name as String?, id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil
            else { return nil }
            var identity: SecIdentity?
            let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
            guard status == errSecSuccess, let identity else {
                AppLog.write("KDE Connect identity: no key for the certificate (\(status))")
                return nil
            }
            return Identity(id: id, identity: identity, certificate: der)
        }
    }

    // MARK: - The connection

    /// One TLS connection with Android's KDE Connect, newline-separated JSON packets.
    final class Link {
        private let fd: Int32
        private let context: SSLContext
        private let sending = NSLock()
        private var box: UnsafeMutablePointer<Int32>

        private init(fd: Int32, context: SSLContext, box: UnsafeMutablePointer<Int32>) {
            self.fd = fd
            self.context = context
            self.box = box
        }

        deinit {
            SSLClose(context)
            close(fd)
            box.deallocate()
        }

        fileprivate static func open(socket path: URL, me: Identity, android: Android) throws -> Link {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw RuntimeError("No socket for notifications.") }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                close(fd)
                throw RuntimeError("The notifications socket's path is too long.")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard connected == 0 else {
                close(fd)
                throw RuntimeError("Android's KDE Connect can't be reached.")
            }
            // Who we are and whom we want, in plain text, before TLS.
            let hello = packet("kdeconnect.identity", identity(me).merging([
                "targetDeviceId": android.id, "targetProtocolVersion": 8]) { $1 })
            guard writeAll(fd, hello) else {
                close(fd)
                throw RuntimeError("Android's KDE Connect closed the connection.")
            }
            let box = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            box.pointee = fd
            guard let context = SSLCreateContext(nil, .serverSide, .streamType) else {
                close(fd)
                box.deallocate()
                throw RuntimeError("No TLS for notifications.")
            }
            let link = Link(fd: fd, context: context, box: box)
            SSLSetIOFuncs(context, { connection, data, length in
                let fd = connection.assumingMemoryBound(to: Int32.self).pointee
                let wanted = length.pointee
                var done = 0
                while done < wanted {
                    let got = Darwin.read(fd, data.advanced(by: done), wanted - done)
                    if got <= 0 {
                        length.pointee = done
                        return got == 0 ? errSSLClosedGraceful : errSSLClosedAbort
                    }
                    done += got
                }
                return noErr
            }, { connection, data, length in
                let fd = connection.assumingMemoryBound(to: Int32.self).pointee
                let wanted = length.pointee
                var done = 0
                while done < wanted {
                    let sent = Darwin.write(fd, data.advanced(by: done), wanted - done)
                    if sent <= 0 {
                        length.pointee = done
                        return errSSLClosedAbort
                    }
                    done += sent
                }
                return noErr
            })
            SSLSetConnection(context, UnsafeRawPointer(box))
            SSLSetCertificate(context, [me.identity] as CFArray)
            SSLSetProtocolVersionMin(context, .tlsProtocol12)
            SSLSetProtocolVersionMax(context, .tlsProtocol12)
            SSLSetClientSideAuthenticate(context, .alwaysAuthenticate)
            SSLSetSessionOption(context, .breakOnClientAuth, true)
            var status: OSStatus
            repeat {
                status = SSLHandshake(context)
                if status == errSSLPeerAuthCompleted {
                    // Android's own certificate, the one KDE Connect keeps, and no other.
                    var trust: SecTrust?
                    SSLCopyPeerTrust(context, &trust)
                    let chain = trust.flatMap { SecTrustCopyCertificateChain($0) as? [SecCertificate] } ?? []
                    guard let peer = chain.first, SecCertificateCopyData(peer) as Data == android.certificate else {
                        throw RuntimeError("Android's KDE Connect showed another certificate.")
                    }
                    status = errSSLWouldBlock
                }
            } while status == errSSLWouldBlock
            guard status == noErr else { throw RuntimeError("The notifications connection's TLS failed (\(status)).") }
            link.send("kdeconnect.identity", identity(me))
            return link
        }

        private static func identity(_ me: Identity) -> [String: Any] {
            [
                "deviceId": me.id, "deviceName": "Mac", "deviceType": "desktop", "protocolVersion": 8,
                "incomingCapabilities": ["kdeconnect.notification"],
                "outgoingCapabilities": ["kdeconnect.notification.request", "kdeconnect.notification.reply",
                                         "kdeconnect.notification.action"],
            ]
        }

        private static func packet(_ type: String, _ body: [String: Any]) -> Data {
            let object: [String: Any] = ["id": 0, "type": type, "body": body]
            var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            data.append(10)
            return data
        }

        private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
            data.withUnsafeBytes { raw in
                var done = 0
                while done < raw.count {
                    let sent = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                    if sent <= 0 { return false }
                    done += sent
                }
                return true
            }
        }

        func send(_ type: String, _ body: [String: Any]) {
            let data = Self.packet(type, body)
            sending.lock()
            defer { sending.unlock() }
            data.withUnsafeBytes { raw in
                var written = 0
                _ = SSLWrite(context, raw.baseAddress, raw.count, &written)
            }
        }

        /// Reads packets until the connection ends; Android's identity, the first, is passed over.
        func read(_ handle: (String, [String: Any]) -> Void) {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                var count = 0
                let status = SSLRead(context, &chunk, chunk.count, &count)
                if count > 0 { buffer.append(contentsOf: chunk[..<count]) }
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[buffer.startIndex..<end]
                    buffer.removeSubrange(buffer.startIndex...end)
                    guard let packet = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let type = packet["type"] as? String else { continue }
                    if type == "kdeconnect.identity" { continue }
                    handle(type, packet["body"] as? [String: Any] ?? [:])
                }
                if status != noErr && status != errSSLWouldBlock { return }
            }
        }
    }
}

/// A self-signed X.509 certificate for an EC P-256 key, signed with ECDSA and SHA-256: subject
/// and issuer "CN=<id>, OU=KDE Connect, O=KDE", valid from a year ago for ten years, as KDE
/// Connect makes its own. DER, built by hand, as Security makes no certificates.
private enum Certificate {
    static func make(id: String, publicKey point: Data, signer: SecKey) -> Data? {
        let name = sequence([
            set([sequence([oid([2, 5, 4, 3]), utf8(id)])]),
            set([sequence([oid([2, 5, 4, 11]), utf8("KDE Connect")])]),
            set([sequence([oid([2, 5, 4, 10]), utf8("KDE")])]),
        ])
        let ecdsaSHA256 = sequence([oid([1, 2, 840, 10045, 4, 3, 2])])
        let now = Date()
        let tbs = sequence([
            tagged(0, integer([2])),
            integer([1]),
            ecdsaSHA256,
            name,
            sequence([time(now.addingTimeInterval(-365 * 86400)), time(now.addingTimeInterval(10 * 365 * 86400))]),
            name,
            sequence([sequence([oid([1, 2, 840, 10045, 2, 1]), oid([1, 2, 840, 10045, 3, 1, 7])]), bitString(point)]),
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(signer, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data?
        else { return nil }
        return sequence([tbs, ecdsaSHA256, bitString(signature)])
    }

    private static func element(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var length = [UInt8]()
            var n = count
            while n > 0 {
                length.insert(UInt8(n & 0xff), at: 0)
                n >>= 8
            }
            out.append(0x80 | UInt8(length.count))
            out.append(contentsOf: length)
        }
        out.append(content)
        return out
    }

    private static func sequence(_ items: [Data]) -> Data { element(0x30, items.reduce(Data(), +)) }
    private static func set(_ items: [Data]) -> Data { element(0x31, items.reduce(Data(), +)) }
    private static func tagged(_ number: UInt8, _ content: Data) -> Data { element(0xa0 | number, content) }
    private static func integer(_ bytes: [UInt8]) -> Data { element(0x02, Data(bytes)) }
    private static func utf8(_ text: String) -> Data { element(0x0c, Data(text.utf8)) }
    private static func bitString(_ bytes: Data) -> Data { element(0x03, Data([0]) + bytes) }

    private static func oid(_ parts: [UInt]) -> Data {
        var bytes = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var chunk = [UInt8(part & 0x7f)]
            var n = part >> 7
            while n > 0 {
                chunk.insert(UInt8(0x80 | (n & 0x7f)), at: 0)
                n >>= 7
            }
            bytes += chunk
        }
        return element(0x06, Data(bytes))
    }

    private static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return element(0x17, Data(formatter.string(from: date).utf8))
    }
}
