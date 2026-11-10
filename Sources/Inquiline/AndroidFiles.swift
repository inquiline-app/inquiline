import AppKit
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
    private static let share = URL(string: "smb://guest@Android.local:\(AndroidRuntime.filesPort)/Android")!
    private static var nameService: DNSServiceRef?
    private static let root = "/data/inquiline-files"
    private static let lock = NSLock()
    private static var mountPoint: URL?

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
        if let mountPoint, FileManager.default.fileExists(atPath: mountPoint.path) { return mountPoint }
        nameHost()
        let open = NSMutableDictionary()
        open[kNetFSUseGuestKey] = true
        var points: Unmanaged<CFArray>?
        guard NetFSMountURLSync(share as CFURL, nil, nil, nil, open, nil, &points) == 0,
              let path = (points?.takeRetainedValue() as? [String])?.first
        else { return nil }
        mountPoint = URL(fileURLWithPath: path)
        return mountPoint
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

    /// Ejects the disk before Android stops, as a drive is before it's pulled out.
    static func eject() {
        lock.lock()
        defer { lock.unlock() }
        guard let mountPoint else { return }
        self.mountPoint = nil
        let done = DispatchSemaphore(value: 0)
        var ejected = false
        FileManager.default.unmountVolume(at: mountPoint, options: [.withoutUI]) { error in
            ejected = error == nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        // Finder may still be using it, as a window open on it. Android is going away regardless,
        // and Finder would then report a lost server: the disk goes now, as a pulled drive does.
        if !ejected { _ = Darwin.unmount(mountPoint.path, MNT_FORCE) }
    }

    /// Mounts the disk and shows it in Finder.
    static func show() {
        DispatchQueue.global().async {
            guard let volume = mount() else { return }
            DispatchQueue.main.async { NSWorkspace.shared.open(volume) }
        }
    }
}
