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
    var isGame: Bool?
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
        Self.wake()
        lock.lock()
        defer { lock.unlock() }

        if vm?.isRunning == true {
            if isReady() {
                DispatchQueue.global().async { self.followMacFreeSpace() }
                watchPackages()
                watchSleep()
                NotificationBridge.shared.start()
                return
            }
        } else {
            try FileManager.default.createDirectory(at: vmHome, withIntermediateDirectories: true)
            let firstLaunch = !FileManager.default.fileExists(atPath: disk.path)
            AppLog.write(firstLaunch ? "Setting up Android for the first time" : "Starting Android")
            status(firstLaunch ? "Setting up Android, the first launch takes longer…" : "Starting Android…")
            try VMInstaller.installIfNeeded(at: disk)
            try updateDiskIfNeeded(firstLaunch: firstLaunch, status: status)
            growDiskToMac()
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
        followMacFreeSpace()
        setFullVolume()
        keepLogs()
        turnOffBluetooth()
        nameDevice()
        watchPackages()
        watchSleep()
        NotificationBridge.shared.start()
        followMac()
    }

    // MARK: - Following the Mac

    /// Android takes the Mac's languages, appearance, time zone and clock, as an iPhone app on a
    /// Mac does: they're set once, on the Mac, never again inside Android. Called when Android
    /// starts and when one changes on the Mac; only what differs changes in Android.
    func followMac() {
        guard isRunning else { return }
        // Read fresh each time: the process's own copies of these only change at its next launch.
        func preference(_ key: String) -> Any? {
            CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        let languages = ((preference("AppleLanguages") as? [String]) ?? Locale.preferredLanguages)
            .filter { $0.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil }
            .joined(separator: ",")
        let dark = (preference("AppleInterfaceStyle") as? String) == "Dark"
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current.identifier
        let hours24 = (preference("AppleICUForce24HourTime") as? Bool)
            ?? !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.autoupdatingCurrent) ?? "").contains("a")
        guard zone.range(of: "^[A-Za-z0-9_+/-]+$", options: .regularExpression) != nil else { return }
        let clock = hours24 ? "24" : "12"
        let night = dark ? "yes" : "no"
        // The time zone is the user's own choice in Android's terms, as Android here has no
        // network or location to find it from.
        _ = try? shell("""
            [ "$(settings get system time_12_24)" = \(clock) ] || settings put system time_12_24 \(clock); \
            cmd uimode night | grep -q ": \(night)$" || cmd uimode night \(night); \
            [ "$(getprop persist.sys.timezone)" = \(zone) ] || { cmd time_zone_detector set_auto_detection_enabled false; \
            su 1000 cmd time_zone_detector suggest_manual_time_zone --zone_id \(zone) >/dev/null; }
            """)
        guard !languages.isEmpty else { return }
        NotificationBridge.shared.withAgent {
            _ = try? AdbClient.shell("CLASSPATH=$(pm path \(NotificationBridge.agent) | cut -d: -f2) "
                                     + "app_process / \(NotificationBridge.agent).Languages \(languages)")
        }
    }

    /// The VM has no Bluetooth, and Android's Bluetooth crashes over and over at each start
    /// while it's on, so it's turned off as on a phone: Android remembers it. Controllers
    /// reach Android through the Mac, as USB devices.
    private func turnOffBluetooth() {
        _ = try? shell("[ \"$(settings get global bluetooth_on)\" = 0 ] || cmd bluetooth_manager disable")
    }

    /// The name Android gives itself where a phone shows its own, set once from the old
    /// build name to Inquiline's.
    private func nameDevice() {
        _ = try? shell("[ \"$(settings get global device_name)\" = Inquiline ] || settings put global device_name Inquiline")
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
    /// volumes stay at their highest: music and games, ringtones, alarms and system sounds.
    /// Android's sound card plays at the level these leave. Notifications are silent in
    /// Android: the Mac plays their sound (NotificationBridge), so Focus applies to them.
    private func setFullVolume() {
        _ = try? shell("for v in '1 7' '2 7' '3 15' '4 7' '5 0'; do cmd audio set-volume $v >/dev/null; done")
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
        // Frozen, it couldn't shut down cleanly.
        Self.wake()
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

    // MARK: - Resting

    /// Android asleep, as a phone with its screen off: its processors stop, so it takes no
    /// CPU, and an app opens again in about a second. Its network stays awake, so a
    /// notification wakes it (EngineControl), and it keeps its memory until the Mac runs
    /// short of it.
    /// Returns when Android next wants to be woken, as a phone's alarm clock chip wakes it:
    /// Google's notification service keeps its connection alive this way.
    @discardableResult
    func freeze() -> TimeInterval? {
        guard isRunning, !Self.isFrozen() else { return nil }
        let wakeup = nextWakeupAlarm()
        // Finder would wait on a disk whose server can't answer.
        AndroidFiles.eject()
        EngineControl.pause()
        AppLog.write("Android is resting")
        return wakeup
    }

    /// Seconds to Android's next wake-up alarm, from "Next wakeup alarm: +4m12s345ms = ...".
    private func nextWakeupAlarm() -> TimeInterval? {
        guard let line = try? shell("dumpsys alarm | grep 'Next wakeup alarm:'"),
              let start = line.range(of: ": +")?.upperBound
        else { return nil }
        let text = line[start...].prefix { $0 != " " }
        var total = 0.0, number = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNumber {
                number.append(character)
            } else {
                let unit = text[index...].hasPrefix("ms") ? "ms" : String(character)
                let value = Double(number) ?? 0
                switch unit {
                case "d": total += value * 86400
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                case "ms": total += value / 1000; index = text.index(after: index)
                default: break
                }
                number = ""
            }
            index = text.index(after: index)
        }
        return total
    }

    /// Wakes a resting Android; Inquiline's app windows can do it too, as each runs on its own.
    static func wake() {
        guard isFrozen() else { return }
        EngineControl.resume()
        AppLog.write("Android woke up")
    }

    static func isFrozen() -> Bool {
        EngineControl.isPaused
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
        wake()
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

    /// Android's own screen, the one no window shows: off, as a phone's screen with nobody
    /// using it, so Android sleeps when nothing holds it awake. Windows have screens of their
    /// own, which keep Android awake while they're open.
    func setScreenOn(_ on: Bool) {
        guard isRunning else { return }
        _ = try? shell("input keyevent \(on ? "KEYCODE_WAKEUP" : "KEYCODE_SLEEP")")
    }

    /// After the last window closes, as pressing a phone's power button: Android lets itself
    /// sleep again only as its screen turns off, so the screen turns on and off.
    func pressPowerButton() {
        guard isRunning else { return }
        _ = try? shell("input keyevent KEYCODE_WAKEUP; input keyevent KEYCODE_SLEEP")
    }

    /// Called on a background thread each time Android's sleep service decides to sleep.
    var onSleep: (() -> Void)?
    private var sleepWatch: Int32 = -1

    /// Android's sleep service puts the processor to sleep by writing "mem" to
    /// /sys/power/state, which redroid binds to /data/.empty so it can't suspend the VM.
    /// Each write is Android deciding to sleep, as it does only when nothing holds it awake.
    private func watchSleep() {
        guard sleepWatch < 0, let socket = try? AdbClient.open("shell,raw:su 0 inotifyd - /data/.empty:c") else { return }
        sleepWatch = socket
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            while recv(socket, &buffer, buffer.count, 0) > 0 {
                onSleep?()
            }
            close(socket)
            sleepWatch = -1
        }
        thread.name = "inquiline.sleep-watch"
        thread.start()
    }


    // MARK: - Storage

    /// Android's storage follows the Mac's disk, as a Mac app's files do: there is no size to
    /// pick or outgrow. Its disk file is as large as the Mac's disk but sparse, so it takes only
    /// what Android writes; the VM grows its file system to match at each start
    /// (inquiline-boot), and what Android deletes goes back to the Mac at once. Only grows.
    private func growDiskToMac() {
        guard let total = try? vmHome.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity,
              let size = (try? FileManager.default.attributesOfItem(atPath: disk.path))?[.size] as? Int,
              total > size, let handle = try? FileHandle(forWritingTo: disk)
        else { return }
        defer { try? handle.close() }
        let wanted = (UInt64(total) >> 20) << 20
        do {
            try handle.truncate(atOffset: wanted)
            AppLog.write("Android's disk follows the Mac's: \(size >> 30) GB → \(wanted >> 30) GB")
        } catch {
            AppLog.write("Android's disk could not grow: \(error.localizedDescription)")
        }
    }

    /// A file inside Android that is allocated but never written. Its file system counts it as
    /// used; on the Mac it stays a hole and takes nothing.
    private static let spaceFile = "/data/.inquiline-space"

    /// Android sees as free what the Mac has free, as a phone shows its own free space, so its
    /// apps and Android itself see a full disk, warn and stop before the Mac fills. The space
    /// file holds the part of Android's file system the Mac doesn't have. Called when Android
    /// starts, when an app opens and before an install.
    func followMacFreeSpace() {
        guard let macFree = try? vmHome.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
              let output = try? shell("su 0 sh -c 'stat -f -c \"%a %S\" /data; stat -c %s \(Self.spaceFile) 2>/dev/null || echo 0'")
        else { return }
        let numbers = output.split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
        guard numbers.count == 3, numbers[1] > 0 else { return }
        let block = numbers[1], held = numbers[2]
        var wanted = max(0, numbers[0] * block + held - macFree)
        wanted -= wanted % block
        // Small changes of the Mac's free space are left alone.
        guard abs(wanted - held) >= 64 << 20 else { return }
        let command = wanted > held ? "fallocate -l \(wanted)" : "truncate -s \(wanted)"
        _ = try? shell("su 0 \(command) \(Self.spaceFile)")
    }

    /// Goes up with each release that changes what Android runs on, as in its disk's
    /// disk-update.tar, which holds everything since revision 1. 2: gfxstream and ANGLE
    /// instead of Mesa's virgl. 3: Android claims Vulkan 1.3, as it has. 4: ANGLE gives GLES 3.2.
    /// 5: game controllers (uhid, and input devices handed to Android by mdev).
    /// 6: a sound card (virtio-sound) and an audio HAL that plays into it.
    /// 7: the Vulkan driver slept, not spun, while the Mac worked. 8: back to upstream's
    /// waiting, as in revision 6. 9: the sound card holds 100 ms, not 40.
    /// 10: Inquiline's own names for its files inside Android. 11: the Vulkan driver sleeps
    /// after a short spin while the Mac compiles, as the Mac now compiles pipelines at once
    /// and needs the cores (Mesa patch 0101). 12: only after 5 ms of waiting, as sleeping in
    /// a frame's short waits cost about 15% of Asphalt Legends' frame rate.
    /// 13: a multitouch screen, ten fingers, as the trackpad and keyboard controls give.
    /// 14 took it away for a test, which 15 undoes.
    /// 16: named "Inquiline Mac" where Google Play and accounts show the device, not Redroid's
    /// build name; its code name, which apps may be filtered by, stays.
    /// 17: a gyroscope declared, as the accelerometer and compass are, for games Play Store
    /// lists only with one.
    /// 18: Android's own settings changed by an overlay in /vendor/overlay: no frame around the
    /// whole screen of a game once a key is pressed.
    /// 19: Android's sleep service may write its decisions to sleep, which Inquiline follows.
    /// 20: Android's storage follows the Mac's disk: its file system grows with the disk file
    /// (resize2fs at each start) and gives deleted space back at once (discard).
    /// 21: a tunnel device for Android's VPNs, which ad blocking uses, Android's own (system, vpn).
    private static let diskRevision = 21
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
        // 12 GB on Macs with 16 GB or more, so several apps stay in memory at once, 4 GB below.
        // Android only holds what it uses and gives freed memory back. The GPU's memory
        // (textures, shaders) is on the Mac, outside this.
        let memory = ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? 12288 : 4096
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
            "-qmp", "unix:\(EngineControl.socket.path),server=on,wait=off",
            // A second one, which Inquiline keeps open for the engine's events.
            "-qmp", "unix:\(EngineControl.eventsSocket.path),server=on,wait=off",
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
        guard !Self.isFrozen() else { return }
        _ = try? shell("su 0 sh -c 'set -- $(grep -E \"^(Cached|Mapped|Shmem):\" /proc/meminfo | tr -s \" \" | cut -d\" \" -f2); [ $(($1 - $2 - $3)) -gt 262144 ] && echo 1 > /proc/sys/vm/drop_caches'")
    }

    /// Android keeps what an app used as file cache and idle processes. Freeing those
    /// lets the memory go back to the Mac, at the cost of a slower next app start.
    func releaseMemory() {
        guard !Self.isFrozen() else { return }
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

    /// Installs one app of an APK or a bundle: all its parts at once, as Play Store does, then
    /// its game data.
    func install(_ app: ApkBundle.App) throws {
        // Adding an APK is a USB install in Android's terms. With Google Play added, Play Protect
        // checks those through a Google service that MindTheGapps lacks, so the install waits
        // forever. Android's developer option "Verify apps over USB" turns that check off.
        _ = try shell("settings put global verifier_verify_adb_installs 0")
        followMacFreeSpace()
        let sizes = try app.apks.map { url -> Int in
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw RuntimeError("Could not read \(url.lastPathComponent).")
            }
            return size
        }
        let package = app.manifest.package
        let notificationsBefore = notificationsAllowed(package: package)
        // -g grants runtime permissions up front: the app is confined to the VM.
        let created = try shell("cmd package install-create -S \(sizes.reduce(0, +)) -r -d -t -g")
        guard let session = created.split(whereSeparator: { "[]".contains($0) }).dropFirst().first.flatMap({ Int($0) }) else {
            throw RuntimeError(created.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            for (index, (apk, size)) in zip(app.apks, sizes).enumerated() {
                let written = try AdbClient.exec("cmd package install-write -S \(size) \(session) \(index).apk -", input: apk)
                guard written.contains("Success") else { throw RuntimeError(written.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            let committed = try shell("cmd package install-commit \(session)")
            guard committed.contains("Success") else { throw RuntimeError(committed.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } catch {
            _ = try? shell("cmd package install-abandon \(session)")
            throw error
        }
        // Except notifications, which reach the Mac: as from Google Play, a new app asks for
        // them when it wants them, and an updated one keeps what the user chose.
        if notificationsBefore == nil {
            _ = try? shell("pm revoke \(package) \(Self.notificationPermission)")
            _ = try? shell("pm clear-permission-flags \(package) \(Self.notificationPermission) user-set user-fixed")
        } else if notificationsBefore == false {
            _ = try? shell("pm revoke \(package) \(Self.notificationPermission)")
        }
        guard !app.obbs.isEmpty, package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return }
        let folder = "/sdcard/Android/obb/\(package)"
        _ = try shell("mkdir -p \(folder)")
        for obb in app.obbs {
            let name = obb.lastPathComponent
            guard name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
                  let size = try obb.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            // The stream gives no end of file, so the copy takes as many bytes as the file has.
            _ = try AdbClient.exec("sh -c 'head -c \(size) > \(folder)/\(name)'", input: obb)
        }
    }

    private static let notificationPermission = "android.permission.POST_NOTIFICATIONS"

    /// Whether the app may post notifications, as Android's Settings > Apps > Notifications
    /// shows it; nil when the app isn't installed.
    func notificationsAllowed(package: String) -> Bool? {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
              let output = try? shell("dumpsys package \(package) | grep '\(Self.notificationPermission): granted='"),
              !output.isEmpty
        else { return nil }
        return output.contains("granted=true")
    }

    /// As the switch in Android's Settings does: the app gets or loses the permission at once,
    /// without asking, and doesn't ask again on its own. `pm revoke` would end the running app,
    /// so the notifications helper does it the way that doesn't (its Switch class).
    func setNotificationsAllowed(_ allowed: Bool, package: String) {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
              let uid = try? shell("su 0 stat -c %u /data/data/\(package)").trimmingCharacters(in: .whitespacesAndNewlines),
              Int(uid) != nil
        else { return }
        let agent = NotificationBridge.agent
        _ = try? shell("su 0 sh -c 'CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).Switch \(package) \(uid) \(allowed ? "on" : "off")'")
    }

    /// An app's permissions as Android's Settings > Apps > Permissions shows them: by group, each
    /// allowed or not. Only the groups the app asks for.
    struct PermissionGroup {
        let name: String
        let permissions: [String]
        let allowed: Bool
    }

    /// Android's own groups of the permissions a user decides on. Notifications have their own switch.
    private static let permissionGroups: [(name: String, permissions: [String])] = [
        ("Location", ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION"]),
        ("Camera", ["CAMERA"]),
        ("Microphone", ["RECORD_AUDIO"]),
        ("Photos and Videos", ["READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_MEDIA_VISUAL_USER_SELECTED"]),
        ("Music and Audio", ["READ_MEDIA_AUDIO"]),
        ("Files", ["READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE"]),
        ("Contacts", ["READ_CONTACTS", "WRITE_CONTACTS", "GET_ACCOUNTS"]),
        ("Calendar", ["READ_CALENDAR", "WRITE_CALENDAR"]),
        ("Phone", ["READ_PHONE_STATE", "READ_PHONE_NUMBERS", "CALL_PHONE", "ANSWER_PHONE_CALLS", "ADD_VOICEMAIL",
                   "USE_SIP", "ACCEPT_HANDOVER"]),
        ("Call Logs", ["READ_CALL_LOG", "WRITE_CALL_LOG", "PROCESS_OUTGOING_CALLS"]),
        ("SMS", ["SEND_SMS", "RECEIVE_SMS", "READ_SMS", "RECEIVE_WAP_PUSH", "RECEIVE_MMS"]),
        ("Nearby Devices", ["BLUETOOTH_SCAN", "BLUETOOTH_CONNECT", "BLUETOOTH_ADVERTISE", "NEARBY_WIFI_DEVICES", "UWB_RANGING"]),
        ("Physical Activity", ["ACTIVITY_RECOGNITION"]),
        ("Body Sensors", ["BODY_SENSORS", "BODY_SENSORS_BACKGROUND"]),
    ]

    func permissions(package: String) -> [PermissionGroup]? {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
              let output = try? shell("dumpsys package \(package) | sed -n '/runtime permissions:/,$p' | grep 'android.permission.[A-Z_]*: granted='")
        else { return nil }
        var granted: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let name = text[..<colon].replacingOccurrences(of: "android.permission.", with: "")
            if granted[name] == nil { granted[name] = text.contains("granted=true") }
        }
        return Self.permissionGroups.compactMap { group in
            let asked = group.permissions.filter { granted[$0] != nil }
            guard !asked.isEmpty else { return nil }
            return PermissionGroup(name: group.name, permissions: asked, allowed: asked.contains { granted[$0] == true })
        }
    }

    /// As the switch in Android's Settings does, marked as the user's choice so the app doesn't
    /// ask again on its own. Allowing gives the permissions while the app is in use, as a phone's
    /// "Allow" does, not in the background. Taking one away ends the app, as on a phone, which
    /// then starts again.
    func setPermissions(_ group: PermissionGroup, allowed: Bool, package: String) {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return }
        let permissions = group.permissions.filter { !(allowed && $0.contains("BACKGROUND")) }
        let commands = permissions.map {
            "pm \(allowed ? "grant" : "revoke") \(package) android.permission.\($0) 2>/dev/null; "
                + "pm set-permission-flags \(package) android.permission.\($0) user-set 2>/dev/null"
        }
        _ = try? shell(commands.joined(separator: "; "))
    }

    /// Whether the helper blocks the app's ads (its AdBlock class), or nil when Android can't say.
    func adsBlocked(package: String) -> Bool? {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
              let output = try? shell("su 0 cat /data/data/\(NotificationBridge.agent)/files/adblock 2>/dev/null; echo end")
        else { return nil }
        return output.split(whereSeparator: \.isNewline).contains { $0 == package }
    }

    /// Blocks or lets through the app's ads, as a phone's ad blocker does, with a VPN for its name
    /// lookups only. Android lets the helper run one without asking, as Inquiline's.
    func setAdsBlocked(_ blocked: Bool, package: String) {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return }
        let agent = NotificationBridge.agent
        _ = try? shell("appops set \(agent) ACTIVATE_VPN allow; su 0 am start-foreground-service -n \(agent)/.AdBlock "
                       + "--es \(blocked ? "add" : "remove") \(package)")
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
    /// A game, as macOS's Game Mode and the App Store's categories see it: one that says so in
    /// its manifest, or one built on a game engine, as many don't say.
    func isGame(package: String, manifest: ApkManifest?) -> Bool {
        if manifest?.isGame == true { return true }
        guard let path = try? shell("pm path \(package)").split(whereSeparator: \.isNewline).first?.dropFirst("package:".count)
        else { return false }
        let folder = (String(path) as NSString).deletingLastPathComponent
        let engines = (try? shell("ls \(folder)/lib/*/ 2>/dev/null")) ?? ""
        return ["libunity.so", "libUE4.so", "libUnreal.so", "libil2cpp.so", "libcocos2dcpp.so", "libgodot_android.so"]
            .contains { engines.contains($0) }
    }

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

    /// Every app's version, by package, from one look at Android's package list.
    func versions() -> [String: String] {
        guard let output = try? shell("dumpsys package packages | grep -E '^  Package \\[|^    versionName='") else { return [:] }
        var versions: [String: String] = [:]
        var package: String?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("  Package [") {
                package = line.dropFirst("  Package [".count).split(separator: "]").first.map(String.init)
            } else if let current = package, let value = line.split(separator: "=", maxSplits: 1).last {
                versions[current] = String(value)
                package = nil
            }
        }
        return versions
    }

    /// Whether Android itself ended the app since `since`, when it was started, as when one of its permissions is
    /// taken away, memory runs short or it's updated: on a phone it then starts again when
    /// it's next shown. Not when the user closed it, it closed itself, or it crashed.
    func wasEndedBySystem(package: String, since: Date) -> Bool {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
              let output = try? shell("dumpsys activity exit-info \(package) | grep -E 'timestamp=|process='")
        else { return false }
        // ApplicationExitInfo reasons: low memory, permission change, dependency died, other
        // kills by system, freezer, package state change, package updated.
        let bySystem: Set<Int> = [3, 8, 12, 13, 14, 15, 16]
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var time: Date?
        for line in output.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: "timestamp=") {
                time = format.date(from: String(line[range.upperBound...].prefix(23)))
            } else if line.contains("process=\(package) "), let time {
                // The newest exit of the app's own process.
                guard time > since,
                      let reason = line.range(of: "reason=").flatMap({ Int(line[$0.upperBound...].prefix(while: \.isNumber)) })
                else { return false }
                return bySystem.contains(reason)
            }
        }
        return false
    }

    /// The apps the user has in Android: Inquiline's own helper isn't one.
    func installedPackages() throws -> [String] {
        try shell("cmd package list packages -3; cmd package list packages \(Self.playStorePackage)")
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                return text.hasPrefix("package:") ? String(text.dropFirst("package:".count)) : nil
            }
            .filter { $0 != NotificationBridge.agent }
    }

    /// The launcher already renders each app's icon, adaptive ones included, and
    /// caches the result. Reading it needs root, which this Android allows.
    /// The app's icon as its Mac app's: 1024 pixels, filled to its edges (the helper's Icon
    /// class), or else the launcher's small one.
    func iconPNG(package: String) -> Data? {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(package).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let agent = NotificationBridge.agent
        if (try? AdbClient.download("su 0 sh -c 'CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).Icon \(package)'",
                                    to: file)) != nil,
           let png = try? Data(contentsOf: file), png.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return png
        }
        return launcherIcon(package: package)
    }

    private func launcherIcon(package: String) -> Data? {
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
