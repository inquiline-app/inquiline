import AppKit
import CoreServices

/// Android's shared storage (its photos, downloads, documents, as a phone's "Internal storage")
/// is a folder on the Mac, ~/Android, as ChromeOS keeps its Android's: Finder shows real files,
/// at the Mac's own speed, with nothing to mount or eject. Android reads and writes them through
/// the VM (9p; QEMU patch 0107, inquiline-storage in the VM).
/// Android's storage layer keeps what it read and indexes what it writes itself, so when the
/// Mac changes the folder, Android is told: it forgets what it kept, and its media scanner
/// looks again, so a photo put there shows in its gallery.
enum AndroidFiles {
    /// The share's root, Android's /data/media. Its "0", Android's first user's storage, is
    /// `folder` instead (the engine sees to that); the rest, games' OBB data, stays in here.
    static var storageRoot: URL { AndroidRuntime.shared.home.appendingPathComponent("vm/storage") }

    /// ~/Android, or "Android Files" if the user has an Android folder of their own. A test copy
    /// (INQUILINE_HOME) has its own, in its folder.
    static let folder: URL = {
        let files = FileManager.default
        guard AndroidRuntime.testHome == nil else { return AndroidRuntime.shared.home.appendingPathComponent("Android") }
        let home = files.homeDirectoryForCurrentUser
        for name in ["Android", "Android Files"] {
            let candidate = home.appendingPathComponent(name)
            let empty = (try? files.contentsOfDirectory(atPath: candidate.path))?.isEmpty ?? true
            if !files.fileExists(atPath: candidate.path) || isOurs(candidate) || empty { return candidate }
        }
        return home.appendingPathComponent("Android Files")
    }()

    /// Marks the folder as Android's, in an extended attribute Android never sees.
    private static let mark = "app.inquiline.storage"

    private static func isOurs(_ url: URL) -> Bool {
        getxattr(url.path, mark, nil, 0, 0, 0) >= 0
    }

    /// Makes the folders the engine shares, before it starts.
    static func prepare() throws {
        let files = FileManager.default
        try files.createDirectory(at: storageRoot.appendingPathComponent("0"), withIntermediateDirectories: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        if !isOurs(folder) { setxattr(folder.path, mark, "1", 1, 0, 0) }
    }

    /// Shows the folder in Finder: an app's own files when `package` has some.
    static func show(package: String? = nil) {
        var target = folder
        if let package {
            let own = folder.appendingPathComponent("Android/data/\(package)")
            if FileManager.default.fileExists(atPath: own.path) { target = own }
        }
        NSWorkspace.shared.open(target)
    }

    // MARK: - What the Mac changes

    private static var stream: FSEventStreamRef?
    private static let queue = DispatchQueue(label: "inquiline.files-watch")
    private static var changed = Set<String>()
    private static var pending = false

    /// Watches the folder for what the Mac changes there. Called each time Android is ready.
    static func watch() {
        queue.async {
            guard stream == nil else { return }
            let callback: FSEventStreamCallback = { _, _, count, paths, _, _ in
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                AndroidFiles.noticed(list.prefix(count))
            }
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, nil, [folder.path] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
            else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    /// On `queue`. Android's own writes show here too: the files it makes carry their owner in an
    /// extended attribute (the engine's mapped-xattr), and those are left out.
    private static func noticed<S: Sequence>(_ paths: S) where S.Element == String {
        // As FSEvents names it: the real path (Foundation's resolving keeps /tmp for /private/tmp).
        let real = realpath(folder.path, nil).map { path in defer { free(path) }; return String(cString: path) }
        let roots = Set([folder.path, real ?? folder.path]).map { $0 + "/" }
        for full in paths {
            guard let root = roots.first(where: { full.hasPrefix($0) }) else { continue }
            let relative = String(full.dropFirst(root.count))
            // Android's own working files, and apps' private ones, which it alone writes.
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) || relative.hasPrefix("Android/") { continue }
            if getxattr(full, "user.virtfs.uid", nil, 0, 0, XATTR_NOFOLLOW) >= 0 { continue }
            changed.insert(relative)
        }
        guard !changed.isEmpty, !pending else { return }
        pending = true
        // A copy of many files comes as many events: they're told together.
        queue.asyncAfter(deadline: .now() + 1) { tell() }
    }

    /// On `queue`: Android forgets the files it kept, and scans what changed: a file, which
    /// a scan adds or, if it's gone, removes, or a folder, whose files a scan goes through.
    /// Many at once, as a copied folder's, are one scan of the whole storage, as Android does
    /// when its storage appears.
    private static func tell() {
        pending = false
        let items = changed.count > 20 ? [""] : Array(changed)
        changed.removeAll()
        guard AndroidRuntime.shared.isRunning else { return }
        var lines = ["su 0 sh -c 'echo 2 > /proc/sys/vm/drop_caches'"]
        for item in items {
            lines.append(item.isEmpty
                ? "content call --uri content://media --method scan_volume --arg external_primary >/dev/null"
                : "content call --uri content://media --method scan_file --arg " + quote("/storage/emulated/0/" + item) + " >/dev/null")
        }
        _ = try? AdbClient.shell(lines.joined(separator: "; "), timeout: 60)
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
