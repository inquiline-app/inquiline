import AppKit
import CommonCrypto
import DiskArbitration
import NetFS
import dnssd

/// Android's files as a disk in Finder, as a phone's storage or a USB drive shows: its
/// internal storage, and each app's own folders. Samba in the VM shares a folder whose
/// subfolders are bound to Android's, and a new file takes the owner of the folder it's
/// put in, so the app it belongs to can use it.
enum AndroidFiles {
    struct App: Equatable {
        let package: String
        let label: String
    }

    /// Finder names a disk's server after its host, so the host is "Android", a name
    /// that only this Mac knows (see `nameHost`).
    private static let share = URL(string: "smb://root@Android.local:\(AndroidRuntime.filesPort)/Android")!
    private static var nameService: DNSServiceRef?
    private static let root = "/data/inquiline-files"
    private static let lock = NSLock()

    /// Lays the folders out for these apps. Call off the main thread.
    static func update(_ apps: [App]) throws {
        var lines = [
            "cd \(root) || exit 1",
            // Only the bindings and the empty folders under them go: rmdir can't remove
            // a folder that is still bound, so Android's own files are never touched.
            "grep -o ' \(root)/[^ ]*' /proc/mounts | sort -r | while read -r m; do umount \"$(printf %b \"$m\")\"; done",
            "for d in Apps/*/* Apps/* Apps 'Internal storage'; do rmdir \"$d\"; done 2>/dev/null",
            bind("/data/media/0", "Internal storage"),
        ]
        for app in apps {
            let folder = "Apps/" + app.label.replacingOccurrences(of: "/", with: "-")
            lines.append(bind("/data/data/\(app.package)", folder + "/App data"))
            lines.append(bind("/data/media/0/Android/data/\(app.package)", folder + "/Shared files"))
            lines.append(bind("/data/media/0/Android/obb/\(app.package)", folder + "/Game data (OBB)"))
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("inquiline-files-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: script) }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        // The stream doesn't end with the file, so the shell reads exactly its size.
        _ = try AdbClient.exec("sh -c 'head -c \(text.utf8.count) | su 0 sh'", input: script)
    }

    private static func bind(_ source: String, _ target: String) -> String {
        "[ -d \(quote(source)) ] && mkdir -p \(quote(target)) && mount --bind \(quote(source)) \(quote(target))"
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Mounts the disk if it isn't, and returns where it is. Call off the main thread.
    @discardableResult
    static func mount() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        // Already in Finder, as when an eject didn't go through: where the system has it, not
        // where this run last put it. Mounting it again would fail as already there.
        if let point = mounted().first { return point }
        guard let password = password() else {
            AppLog.write("Android's disk has no password to mount with")
            return nil
        }
        guard allowIn(password) else {
            AppLog.write("Android's disk couldn't be opened to this Mac")
            return nil
        }
        nameHost()
        let open = NSMutableDictionary()
        open[kNetFSUseGuestKey] = false
        // Never a sign-in window, and the password never goes to the Keychain.
        open[kNAUIOptionKey] = kNAUIOptionNoUI
        var points: Unmanaged<CFArray>?
        let result = NetFSMountURLSync(share as CFURL, nil, "root" as CFString, password as CFString, open, nil, &points)
        guard result == 0, let path = (points?.takeRetainedValue() as? [String])?.first else {
            AppLog.write("Android's disk couldn't be mounted: error \(result)")
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// The disk's password, made for this installation and kept in Inquiline's own folder,
    /// which only this Mac user opens: apps sandboxed or of other users can't mount the disk.
    /// Not the Keychain, which may be locked and would then ask for its password.
    private static func password() -> String? {
        let file = AndroidRuntime.shared.home.appendingPathComponent("vm/files-password")
        if let saved = try? String(contentsOf: file, encoding: .utf8), saved.count == 32 { return saved }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let made = bytes.map { String(format: "%02x", $0) }.joined()
        guard FileManager.default.createFile(atPath: file.path, contents: Data(made.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
        return made
    }

    /// Samba takes the password as its NT hash (MD4 of its UTF-16), from a file in Android's
    /// /data only root reads there, written before each mount: Android and the Mac can't disagree.
    private static func allowIn(_ password: String) -> Bool {
        let text = Array(password.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD4_DIGEST_LENGTH))
        CC_MD4(text, CC_LONG(text.count), &digest)
        let hash = digest.map { String(format: "%02X", $0) }.joined()
        // When the password was set, in hex: 0 would mean it must change before use.
        let set = String(format: "%08X", UInt32(Date().timeIntervalSince1970))
        let line = "root:0:" + String(repeating: "X", count: 32) + ":\(hash):[U          ]:LCT-\(set):"
        return (try? AdbClient.shell("su 0 sh -c \"umask 077; echo '\(line)' > /data/.inquiline-smbpasswd\" && echo ok"))?
            .contains("ok") == true
    }

    /// Answers Android.local with this Mac, for this Mac only: the name isn't announced on
    /// the network. It lasts as long as Inquiline runs.
    private static func nameHost() {
        guard nameService == nil, DNSServiceCreateConnection(&nameService) == kDNSServiceErr_NoError else { return }
        var record: DNSRecordRef?
        var address: [UInt8] = [127, 0, 0, 1]
        let error = DNSServiceRegisterRecord(nameService, &record, DNSServiceFlags(kDNSServiceFlagsShared),
                                             UInt32(kDNSServiceInterfaceIndexLocalOnly), "Android.local",
                                             UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), 4, &address, 0,
                                             { _, _, _, _, _ in }, nil)
        if error != kDNSServiceErr_NoError {
            DNSServiceRefDeallocate(nameService)
            nameService = nil
        }
    }

    /// Ejects the disk before Android stops, as a drive is before it's pulled out: the one
    /// this run mounted, and any left from a run that ended without ejecting it.
    /// `gone`: Android has already stopped, as when the engine crashed. Asking Finder to
    /// eject would wait on a server that's no longer there while Finder reports it lost, so
    /// the disk goes at once, as a pulled drive does.
    static func eject(gone: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        for point in mounted() {
            if gone { forceUnmount(point) } else { eject(at: point) }
        }
    }

    /// Where Android's disk is mounted now, found from the system, not remembered.

    private static func mounted() -> [URL] {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return [] }
        return (0..<Int(count)).compactMap { i in
            var entry = list[i]
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return from.lowercased().contains("@android.local") ? URL(fileURLWithPath: on) : nil
        }
    }

    private static func eject(at mountPoint: URL) {
        let done = DispatchSemaphore(value: 0)
        var ejected = false
        FileManager.default.unmountVolume(at: mountPoint, options: [.withoutUI]) { error in
            ejected = error == nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        // Finder may still be using it, as a window open on it. Android is going away regardless,
        // and Finder would then report a lost server: the disk goes now, as a pulled drive does.
        if !ejected { forceUnmount(mountPoint) }
    }

    /// Takes the disk away even while in use, through Disk Arbitration as Finder's own eject
    /// does: unmounting by path from Inquiline itself counts as reaching into a network
    /// volume, which macOS asks the user to allow.
    private static func forceUnmount(_ mountPoint: URL) {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mountPoint as CFURL)
        else { return }
        let queue = DispatchQueue(label: "inquiline.files-unmount")
        DASessionSetDispatchQueue(session, queue)
        let done = DispatchSemaphore(value: 0)
        let context = Unmanaged.passRetained(done).toOpaque()
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionForce), { _, _, context in
            Unmanaged<DispatchSemaphore>.fromOpaque(context!).takeRetainedValue().signal()
        }, context)
        _ = done.wait(timeout: .now() + 10)
        DASessionSetDispatchQueue(session, nil)
    }

    /// Mounts the disk and shows it in Finder: an app's own folder when `label` names one.
    /// Blocks until the disk is there, so call it off the main thread.
    static func show(label: String? = nil) throws {
        guard let volume = mount() else { throw RuntimeError("Android's disk couldn't be opened in Finder. Try again in a moment.") }
        var target = volume
        // Whether the app has its folder is asked of Android: Inquiline looking at files on the
        // disk itself would need the user's leave (macOS's "network volumes"), and Finder opens it.
        if let label {
            let name = label.replacingOccurrences(of: "/", with: "-")
            let there = (try? AdbClient.shell("su 0 sh -c " + quote("[ -d " + quote("\(root)/Apps/\(name)") + " ] && echo yes")))?
                .contains("yes") == true
            if there { target = volume.appendingPathComponent("Apps").appendingPathComponent(name) }
        }
        DispatchQueue.main.async { NSWorkspace.shared.open(target) }
    }
}
