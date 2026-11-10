import AppKit

struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ApkInfo {
    let package: String
    let label: String
    var orientation: AppOrientation?
}

/// Owns the single Linux VM, and the Android inside it, that every app window is
/// served from. All methods block, so call them off the main thread.
final class AndroidRuntime {
    static let shared = AndroidRuntime()

    /// Connecting to this Mac port makes the VM shut down cleanly. It must stay
    /// outside 5555-5585, where any adb server on the Mac probes for emulators.
    private static let powerOffPort = 15557
    /// Samba in the VM, for AndroidFiles.
    static let filesPort = 15445
    private static let googlePlayFolder = "/data/inquiline-gapps"
    static let playStorePackage = "com.android.vending"

    private let lock = NSLock()
    /// The engine's process. Its own lock is only held to read or set it, so asking whether
    /// Android runs never waits for a boot, which holds `lock` for minutes the first time.
    private var vm: Process? {
        get { vmLock.lock(); defer { vmLock.unlock() }; return engine }
        set { vmLock.lock(); engine = newValue; vmLock.unlock() }
    }
    private var engine: Process?
    private let vmLock = NSLock()

    private init() {}

    /// INQUILINE_HOME replaces the data folder, for a clean first launch when testing. The apps
    /// such a copy makes then go in it too, and carry it, so the real ones are left alone.
    static let testHome: URL? = (ProcessInfo.processInfo.environment["INQUILINE_HOME"]
        ?? Bundle.main.object(forInfoDictionaryKey: AppShortcuts.homeKey) as? String).map { URL(fileURLWithPath: $0) }

    var home: URL {
        Self.testHome ?? Self.supportFolder.appendingPathComponent("Inquiline")
    }

    private static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Holds the VM's disk. QEMU and the rest of the VM are in the app bundle.
    private var vmHome: URL { home.appendingPathComponent("vm") }
    private var disk: URL { vmHome.appendingPathComponent("disk.raw") }
    /// Where gfxstream in the VM process hands app windows their frames (FrameRenderer).
    var framesSocket: URL { vmHome.appendingPathComponent("frames.sock") }

    // MARK: - VM lifecycle

    /// Boots the VM if needed and returns once it can install and start apps.
    /// `status` reports what is happening.
    func ensureReady(status: @escaping (String) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        if vm?.isRunning == true {
            if isReady() {
                watchPackages()
                return
            }
        } else {
            try FileManager.default.createDirectory(at: vmHome, withIntermediateDirectories: true)
            let firstLaunch = !FileManager.default.fileExists(atPath: disk.path)
            AppLog.write(firstLaunch ? "Setting up Android for the first time" : "Starting Android")
            status(firstLaunch ? "Setting up Android, the first launch takes longer…" : "Starting Android…")
            try VMInstaller.installIfNeeded(at: disk)
            try updateDiskIfNeeded(firstLaunch: firstLaunch, status: status)
            try launchVM()
        }

        let start = Date(), deadline = start.addingTimeInterval(180)
        while !isReady() {
            if let vm, !vm.isRunning {
                throw RuntimeError("The Android VM exited during startup.")
            }
            if Date() > deadline {
                throw RuntimeError("Android did not finish starting within 3 minutes.")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        AppLog.write("Android is ready after \(Int(Date().timeIntervalSince(start))) s")
        setFullVolume()
        keepLogs()
        turnOffBluetooth()
        watchPackages()
    }

    /// The VM has no Bluetooth, and Android's Bluetooth crashes over and over at each start
    /// while it's on, so it's turned off as on a phone: Android remembers it. Controllers
    /// reach Android through the Mac, as USB devices.
    private func turnOffBluetooth() {
        _ = try? shell("[ \"$(settings get global bluetooth_on)\" = 0 ] || cmd bluetooth_manager disable")
    }

    /// Android keeps its log on its disk, as phones do for their bug reports, so a problem's
    /// lines are still there after Android restarts: 16 files of 2 MB at most, the oldest
    /// going first. Report a Problem reads them. Android's own setting, so it stays set.
    private func keepLogs() {
        _ = try? shell("su 0 sh -c '[ \"$(getprop persist.logd.logpersistd)\" = logcatd ] || { "
            + "setprop persist.logd.logpersistd.size 16; setprop persist.logd.logpersistd.rotate_kbytes 2048; "
            + "setprop persist.logd.logpersistd.buffer main,system,crash,events; setprop persist.logd.logpersistd logcatd; }'")
    }

    /// The Mac's volume is the one that counts, as for iPhone apps on a Mac, so Android's own
    /// volumes stay at their highest: music and games, ringtones, alarms, notifications and
    /// system sounds. Android's sound card plays at the level these leave.
    private func setFullVolume() {
        _ = try? shell("for v in '1 7' '2 7' '3 15' '4 7' '5 7'; do cmd audio set-volume $v >/dev/null; done")
    }

    /// Called on a background thread when an app is installed or removed inside Android,
    /// from the Play Store for instance, as a phone's home screen follows them.
    var onPackagesChanged: (() -> Void)?
    /// Goes up each time Android starts, which loses what was set up inside it.
    private(set) var bootCount = 0
    private var packageWatch: Int32 = -1

    /// Each install or removal adds or deletes a folder in /data/app, which inotifyd reports.
    private func watchPackages() {
        guard packageWatch < 0, let socket = try? AdbClient.open("shell,raw:su 0 inotifyd - /data/app:nd") else { return }
        packageWatch = socket
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while recv(socket, &buffer, buffer.count, 0) > 0 { onPackagesChanged?() }
            lock.lock()
            if packageWatch == socket { packageWatch = -1 }
            lock.unlock()
            close(socket)
        }
        thread.name = "inquiline.package-watch"
        thread.start()
    }

    func shutdown() {
        // ensureReady holds the lock for the whole boot; quitting must not wait for that.
        guard lock.try() else {
            AndroidFiles.eject()
            vm?.terminate()
            return
        }
        defer { lock.unlock() }
        guard vm != nil || isDeviceAttached() else { return }
        AppLog.write("Stopping Android")
        AndroidFiles.eject()
        // As a phone does before turning off: data still in memory is written to disk first,
        // so that cutting the VM after the deadline below can't leave files half written.
        _ = try? shell("sync")
        powerDownVM()

        // A clean shutdown protects Android's data, but quitting can't wait forever.
        let deadline = Date().addingTimeInterval(20)
        while vm?.isRunning == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if vm?.isRunning == true {
            AppLog.write("Android didn't stop within 20 s, so it was ended")
            vm?.terminate()
        }
        vm = nil
    }

    private func powerDownVM() {
        if let socket = try? ScrcpyServer.openSocket(port: Self.powerOffPort) { close(socket) }
    }

    private func isDeviceAttached() -> Bool {
        (try? shell("true")) != nil
    }

    /// Asked from the main thread: answers at once, even while Android starts.
    var isRunning: Bool {
        vm?.isRunning == true
    }

    private func isReady() -> Bool {
        Self.isReady()
    }

    /// `sys.boot_completed` flips before the system services are usable, so the
    /// services an install depends on are probed as well. While Android starts, a probe
    /// can go unanswered, so each gives up after a few seconds and is asked again.
    private static func isReady() -> Bool {
        guard let booted = try? AdbClient.shell("getprop sys.boot_completed", timeout: 5),
              booted.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              (try? AdbClient.shell("settings get global device_name", timeout: 5))?.isEmpty == false,
              let packages = try? AdbClient.shell("cmd package path android", timeout: 5),
              packages.contains("package:")
        else { return false }
        return true
    }

    /// For an app's own process: asks Inquiline, in the menu bar, to start Android
    /// (which opens Inquiline if it isn't), then waits until Android is ready.
    static func waitUntilReady() -> Bool {
        if isReady() { return true }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(URL(string: "inquiline://start")!, configuration: configuration)
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if isReady() { return true }
        }
        return false
    }

    /// Work an app keeps going after its screen closes, such as a Play Store download or
    /// music, runs as a foreground service, which a phone never stops. Android's own
    /// services don't count: only those of installed apps and the Play Store do.
    func hasForegroundWork() -> Bool {
        guard let output = try? shell("dumpsys activity services | grep -E '^  \\* ServiceRecord|isForeground=true'"),
              let apps = try? installedPackages()
        else { return false }
        var package = ""
        for line in output.split(whereSeparator: \.isNewline) {
            if line.contains("ServiceRecord{") {
                package = line.split(separator: " ").first { $0.contains("/") }?.split(separator: "/").first.map(String.init) ?? ""
            } else if apps.contains(package) {
                return true
            }
        }
        return false
    }

    /// Play Store downloads end in an install session; stopping Android would cut them off.
    func isInstalling() -> Bool {
        (try? shell("dumpsys package | grep -m1 'Active Session'"))?.contains("Active Session") ?? false
    }

    /// Goes up with each release that changes what Android runs on, as in its disk's
    /// disk-update.tar, which holds everything since revision 1. 2: gfxstream and ANGLE
    /// instead of Mesa's virgl. 3: Android claims Vulkan 1.3, as it has. 4: ANGLE gives GLES 3.2.
    /// 5: game controllers (uhid, and input devices handed to Android by mdev).
    /// 6: a sound card (virtio-sound) and an audio HAL that plays into it.
    /// 7: the Vulkan driver slept, not spun, while the Mac worked. 8: back to upstream's
    /// waiting, as in revision 6. 9: the sound card holds 100 ms, not 40.
    /// 10: Inquiline's own names for its files inside Android.
    private static let diskRevision = 10
    /// The VM's memory map fits the 36-bit (64 GB) address space Apple's M1 and M2 give a VM:
    /// above the RAM, the window for 64-bit device memory, such as the GPU's 2 GB, is 16 GB,
    /// not QEMU's 512 GB, which only M3 and later have room for (see the QEMU patch 0102).
    private static let machine = "virt,highmem=on,highmem-mmio-size=16G"
    /// QEMU, named for the app so Activity Monitor shows whose it is.
    static let engineName = "Inquiline Engine"
    private var revisionFile: URL { vmHome.appendingPathComponent("disk-revision") }

    /// A disk from an earlier release gets the new system files while the user's apps and
    /// data stay, as a phone's system update does. Android isn't started for this: Linux
    /// alone unpacks disk-update.tar onto the disk and stops, in about a second. A new disk
    /// gets it too, so the disk image needn't be built again for each revision.
    private func updateDiskIfNeeded(firstLaunch: Bool, status: (String) -> Void) throws {
        let revision = firstLaunch ? 0
            : (try? String(contentsOf: revisionFile, encoding: .utf8)).flatMap { Int($0) } ?? 1
        if revision < Self.diskRevision {
            guard let qemu = Bundle.main.url(forAuxiliaryExecutable: AndroidRuntime.engineName),
                  let kernel = Bundle.main.url(forResource: "vmlinux", withExtension: nil),
                  let update = Bundle.main.url(forResource: "disk-update", withExtension: "tar")
            else {
                throw RuntimeError("Android is missing from the app bundle.")
            }
            AppLog.write("Updating Android's disk from revision \(revision) to \(Self.diskRevision)")
            status("Updating Android…")
            let done = "INQUILINE-UPDATED"
            let process = Process()
            process.executableURL = qemu
            process.arguments = [
                "-M", Self.machine, "-accel", "hvf", "-cpu", "host", "-smp", "2", "-m", "512",
                "-kernel", kernel.path,
                "-append", "root=/dev/vda rw quiet console=ttyAMA0 init=/bin/sh -- -c \"mount -t devtmpfs dev /dev 2>/dev/null; "
                    + "tar -xf /dev/vdb -C / && sh /disk-update.sh && echo \(done); rm -f /disk-update.sh; sync; poweroff -f\"",
                "-drive", "if=virtio,format=raw,file=\(disk.path)",
                "-drive", "if=virtio,format=raw,file=\(update.path),readonly=on",
                "-nic", "none", "-display", "none", "-serial", "stdio", "-monitor", "none",
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let console = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard String(decoding: console, as: UTF8.self).contains(done) else {
                throw RuntimeError("Could not update Android. Check that the Mac has free disk space.")
            }
        }
        if revision != Self.diskRevision || firstLaunch {
            try String(Self.diskRevision).write(to: revisionFile, atomically: true, encoding: .utf8)
        }
    }

    private func launchVM() throws {
        guard let qemu = Bundle.main.url(forAuxiliaryExecutable: AndroidRuntime.engineName),
              let kernel = Bundle.main.url(forResource: "vmlinux", withExtension: nil)
        else {
            throw RuntimeError("Android is missing from the app bundle.")
        }
        let cores = max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        // 8 GB on Macs with 16 GB or more, 4 GB below. Android only holds what it uses and gives
        // freed memory back. The GPU's memory (textures, shaders) is on the Mac, outside this.
        let memory = ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? 8192 : 4096
        let process = Process()
        process.executableURL = qemu
        process.currentDirectoryURL = vmHome
        // Memory follows what Android uses, as an app's does on a Mac: the kernel keeps
        // gathering free pages into whole blocks in the background (proactive compaction),
        // and reports those blocks, which QEMU gives back to the Mac within seconds.
        process.arguments = [
            "-M", Self.machine, "-accel", "hvf", "-cpu", "host",
            "-smp", "\(cores)", "-m", "\(memory)",
            "-kernel", kernel.path,
            "-append", "root=/dev/vda rw selinux=0 quiet page_reporting.page_reporting_order=2 sysctl.vm.compaction_proactiveness=100",
            "-drive", "if=virtio,format=raw,file=\(disk.path),cache=writeback,discard=unmap",
            // Android's Vulkan goes to the Mac's GPU through gfxstream and MoltenVK, and its
            // GLES is ANGLE on that Vulkan, so the Mac needs no GLES of its own. Android 15
            // knows Vulkan up to 1.3, and its tools crash on a driver claiming 1.4.
            "-device", "virtio-gpu-rutabaga-pci,gfxstream-vulkan=on,x-gfxstream-gles=on,x-gfxstream-composer=on,"
                + "hostmem=2G,x-gfxstream-features=GuestVulkanOnly:enabled;GuestVulkanMaxApiVersion:1.3",
            // Android's sound card: its audio HAL plays into it, and QEMU plays it on the Mac.
            "-audiodev", "coreaudio,id=sound", "-device", "virtio-sound-pci,audiodev=sound",
            // Memory is taken as Android needs it, and this reports what it frees to QEMU,
            // which gives it back to the Mac through memory-release.c.
            "-device", "virtio-balloon-pci,free-page-reporting=on",
            "-device", "virtio-net-pci,netdev=n,romfile=",
            "-netdev", "user,id=n,hostfwd=tcp:127.0.0.1:5556-:5555,hostfwd=tcp:127.0.0.1:\(Self.powerOffPort)-:5000,hostfwd=tcp:127.0.0.1:\(Self.filesPort)-:445",
            "-display", "none", "-serial", "none", "-monitor", "none",
        ]
        let contents = qemu.deletingLastPathComponent().deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_EMU_VK_ICD"] = "moltenvk"
        env["VK_DRIVER_FILES"] = contents.appendingPathComponent("Resources/vulkan/MoltenVK_icd.json").path
        // gfxstream opens the Vulkan loader by name.
        env["DYLD_FALLBACK_LIBRARY_PATH"] = contents.appendingPathComponent("Frameworks").path
        env["DYLD_INSERT_LIBRARIES"] = contents.appendingPathComponent("Frameworks/libmemory-release.dylib").path
        env["INQUILINE_FRAMES_SOCKET"] = framesSocket.path
        // MoltenVK's errors only; its warnings would fill the log.
        env["MVK_CONFIG_LOG_LEVEL"] = "1"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Self.engineLog() ?? FileHandle.nullDevice
        // If the engine ends on its own, as when it crashes, Android's disk goes with it at once,
        // not when Finder finds its server gone.
        process.terminationHandler = { engine in
            AndroidFiles.eject(gone: true)
            let how = engine.terminationReason == .uncaughtSignal ? "signal" : "status"
            AppLog.write("The engine ended with \(how) \(engine.terminationStatus)")
        }
        AppLog.write("Starting the engine: \(cores) cores, \(memory) MB of memory")
        try process.run()
        vm = process
        bootCount += 1
        packageWatch = -1 // ended with the previous VM
    }

    /// What the engine prints, mostly errors from the GPU's side, for finding why something
    /// failed: ~/Library/Logs/Inquiline/engine.log, with the previous run's as engine.old.log.
    private static func engineLog() -> FileHandle? {
        let files = FileManager.default
        let folder = AppLog.folder
        let log = folder.appendingPathComponent("engine.log"), old = folder.appendingPathComponent("engine.old.log")
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        try? files.removeItem(at: old)
        try? files.moveItem(at: log, to: old)
        guard files.createFile(atPath: log.path, contents: Data("\(Date())\n".utf8)) else { return nil }
        // Appended to, so the log can be cut short under the engine.
        let fd = open(log.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return nil }
        // Its own copy of the file's descriptor, which the engine's handle closing can't reuse.
        let own = dup(fd)
        engineLogTrim.setEventHandler { trimEngineLog(fd: own, log: log, old: old) }
        if engineLogFD >= 0 { close(engineLogFD) }
        engineLogFD = own
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static var engineLogFD: Int32 = -1

    /// A long run that keeps failing could fill the engine's log without end, so past 4 MB
    /// it moves to engine.old.log and starts again.
    private static let engineLogTrim: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {}
        timer.resume()
        return timer
    }()

    private static func trimEngineLog(fd: Int32, log: URL, old: URL) {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 4 << 20 else { return }
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.copyItem(at: log, to: old)
        ftruncate(fd, 0)
    }

    /// Android keeps the files apps have read in its cache, though the Mac already
    /// caches the disk they come from: the copy inside the VM only costs the Mac memory.
    /// Files an app still has mapped stay; the rest goes once it passes 256 MB.
    func trimFileCache() {
        _ = try? shell("su 0 sh -c 'set -- $(grep -E \"^(Cached|Mapped|Shmem):\" /proc/meminfo | tr -s \" \" | cut -d\" \" -f2); [ $(($1 - $2 - $3)) -gt 262144 ] && echo 1 > /proc/sys/vm/drop_caches'")
    }

    /// Android keeps what an app used as file cache and idle processes. Freeing those
    /// lets the memory go back to the Mac, at the cost of a slower next app start.
    func releaseMemory() {
        _ = try? shell("am kill-all")
        compactMemory()
    }

    /// Android reports free memory to the Mac only in whole blocks, which its free pages
    /// rarely form on their own: starting Android leaves gigabytes scattered. Dropping the
    /// file cache and compacting gathers them, and the Mac gets them back within seconds.
    /// Compacting takes a moment of CPU, so this runs when no app is being played.
    func compactMemory() {
        _ = try? shell("su 0 sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'")
    }

    // MARK: - Apps

    func install(apk: URL) throws -> ApkManifest {
        guard let manifest = ApkManifest(apk: apk) else {
            throw RuntimeError("\(apk.lastPathComponent) is not a valid APK.")
        }
        guard let size = try apk.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw RuntimeError("Could not read \(apk.lastPathComponent).")
        }
        // Adding an APK is a USB install in Android's terms. With Google Play added, Play Protect
        // checks those through a Google service that MindTheGapps lacks, so the install waits
        // forever. Android's developer option "Verify apps over USB" turns that check off.
        _ = try shell("settings put global verifier_verify_adb_installs 0")
        // -g grants runtime permissions up front: the app is confined to the VM.
        let output = try AdbClient.exec("cmd package install -S \(size) -r -d -t -g", input: apk)
        guard output.contains("Success") else {
            throw RuntimeError(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return manifest
    }

    /// Mutes one app as Android itself does, by taking away its permission to play sound
    /// (app op PLAY_AUDIO).
    func setMuted(_ muted: Bool, package: String) {
        _ = try? shell("cmd appops set \(package) PLAY_AUDIO \(muted ? "ignore" : "allow")")
    }

    /// As Android's Settings > Apps > Storage does: Clear Cache keeps the app's accounts, saves
    /// and settings; Clear Storage removes them, as if the app had just been installed.
    func clearCache(package: String) {
        // What Settings does, done directly: `pm clear --cache-only` never returns here.
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return }
        let folders = ["/data/data/\(package)/cache", "/data/data/\(package)/code_cache",
                       "/data/user_de/0/\(package)/cache", "/data/user_de/0/\(package)/code_cache",
                       "/data/media/0/Android/data/\(package)/cache"]
        _ = try? shell("su 0 sh -c '" + folders.map { "rm -rf \($0)/* \($0)/.[!.]*" }.joined(separator: "; ") + "'")
    }

    func clearData(package: String) {
        _ = try? shell("pm clear \(package)")
    }

    /// With `keepData`, adding the app again brings back its saves and settings.
    func uninstall(package: String, keepData: Bool = false) throws {
        let output = try shell("cmd package uninstall \(keepData ? "-k " : "")\(package)")
        guard output.contains("Success") else {
            throw RuntimeError(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// An app that can't be resized and turns itself after starting keeps its first
    /// screen's size: Android shows it scaled down, with "Tap to restart" for a better view.
    func isInSizeCompatMode(package: String) -> Bool {
        let output = (try? shell("dumpsys activity activities | grep -E 'Hist  #|letterboxReason='")) ?? ""
        var inApp = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.contains("Hist  #") {
                inApp = line.contains(" \(package)/")
            } else if inApp, line.contains("SIZE_COMPAT_MODE") {
                return true
            }
        }
        return false
    }

    /// Reads an installed app's manifest, as for apps installed from inside Android.
    func manifest(package: String) -> ApkManifest? {
        guard let path = try? shell("pm path \(package)")
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.hasSuffix("/base.apk") })?
            .dropFirst("package:".count)
        else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inquiline-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? AdbClient.download("unzip -p '\(path)' AndroidManifest.xml", to: file)) != nil,
              let data = try? Data(contentsOf: file)
        else { return nil }
        return ApkManifest(manifest: data)
    }

    func installedPackages() throws -> [String] {
        try shell("cmd package list packages -3; cmd package list packages \(Self.playStorePackage)")
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                return text.hasPrefix("package:") ? String(text.dropFirst("package:".count)) : nil
            }
    }

    /// The launcher already renders each app's icon, adaptive ones included, and
    /// caches the result. Reading it needs root, which this Android allows.
    func iconPNG(package: String) -> Data? {
        guard let hex = launcherCache(column: "hex(icon)", package: package) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), next > index {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.isEmpty ? nil : bytes
    }

    func label(package: String) -> String? {
        launcherCache(column: "label", package: package)
    }

    // MARK: - Google Play

    /// Google's apps can't be shipped with Inquiline, so the user brings them as a
    /// MindTheGapps zip. They go into copies of Android's product and system_ext folders
    /// kept in /data, which the VM mounts over the originals whenever they exist.
    func installGooglePlay(zip: URL, status: @escaping (String) -> Void) throws {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("inquiline-gapps-\(UUID().uuidString)")
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }

        try runTool("/usr/bin/unzip", ["-q", zip.path, "build.prop", "system/product/*", "system/system_ext/*", "-d", work.path])
        let properties = (try? String(contentsOf: work.appendingPathComponent("build.prop"), encoding: .utf8)) ?? ""
        let system = work.appendingPathComponent("system")
        guard properties.contains("arch=arm64"), properties.contains("version=35"),
              files.fileExists(atPath: system.appendingPathComponent("product/priv-app/Phonesky").path)
        else {
            throw RuntimeError("This isn't MindTheGapps for Android 15 arm64.")
        }
        // Only what the Play Store needs: Google's search app alone takes about 750 MB on
        // disk and 190 MB of memory, and nothing else here is used on a Mac. The setup
        // wizard goes too, as this Android never runs a first-time setup.
        for app in ["product/priv-app/Velvet", "product/priv-app/VelvetTitan", "product/priv-app/Wellbeing",
                    "product/priv-app/GoogleRestore", "product/priv-app/AndroidAutoStub", "product/app/talkback",
                    "product/app/MarkupGoogle_v2", "system_ext/priv-app/SetupWizard"] {
            try? files.removeItem(at: system.appendingPathComponent(app))
        }
        let archive = work.appendingPathComponent("google.tar")
        try runTool("/usr/bin/tar", ["-cf", archive.path, "-C", system.path, "product", "system_ext"],
                    environment: ["COPYFILE_DISABLE": "1"])
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        // Built under another name, so an interrupted install leaves nothing half done.
        let target = Self.googlePlayFolder
        let command = """
        rm -rf \(target).new; mkdir -p \(target).new; cp -a /system/product /system/system_ext \(target).new/; \
        head -c \(size) | tar -xf - -C \(target).new; \
        chown -R 0:0 \(target).new; [ -d \(target).new/product/priv-app/Phonesky ] && mv \(target).new \(target) && sync && echo installed
        """
        let output = try AdbClient.exec("su 0 sh -c '\(command)'", input: archive)
        guard output.contains("installed") else {
            throw RuntimeError("Could not add Google Play. Check that the Mac has free disk space.")
        }
        try restart(status: status)
    }

    func removeGooglePlay(status: @escaping (String) -> Void) throws {
        let target = Self.googlePlayFolder
        // Play updates itself, and those copies would outlive the originals.
        _ = try shell("su 0 sh -c 'for p in \(Self.playStorePackage) com.google.android.gms com.google.android.gsf; do pm uninstall-system-updates $p; done; mv \(target) \(target).old'")
        try restart(status: status)
        // Deleted only now, because Android was running from these files.
        _ = try shell("su 0 rm -rf \(target).old")
    }

    private func restart(status: @escaping (String) -> Void) throws {
        shutdown()
        try ensureReady(status: status)
    }

    private func runTool(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: path)
        tool.arguments = arguments
        tool.environment = environment
        tool.standardOutput = FileHandle.nullDevice
        tool.standardError = FileHandle.nullDevice
        try tool.run()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else {
            throw RuntimeError("Could not read the Google Play zip.")
        }
    }

    private func launcherCache(column: String, package: String) -> String? {
        // The package goes into a device shell command, so only valid names pass.
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return nil }
        let database = "/data/data/com.android.launcher3/databases/app_icons.db"
        let query = "select \(column) from icons where componentName like '\(package)/%' and icon is not null order by label is null limit 1"
        guard let output = try? shell("su 0 sqlite3 \(database) \"\(query)\" 2>/dev/null") else { return nil }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func shell(_ command: String) throws -> String {
        try AdbClient.shell(command)
    }
}
