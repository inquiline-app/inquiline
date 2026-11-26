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

    /// adb and the clean shutdown are Unix sockets in the VM's own folder, which only this
    /// Mac user reaches: a port on 127.0.0.1 any app could connect to, sandboxed ones and
    /// other users' too, and adb on it is root in Android, Google sign-in included.
    var adbSocket: URL { vmHome.appendingPathComponent("adb.sock") }
    /// Android's KDE Connect, which brings its notifications to the Mac (KDEConnect).
    var kdeConnectSocket: URL { vmHome.appendingPathComponent("kdeconnect.sock") }
    /// The Mac's certificate as Android's KDE Connect knows it.
    var kdeConnectCertificate: URL { vmHome.appendingPathComponent("kdeconnect.cer") }
    /// Connecting to it makes the VM shut down cleanly.
    private var powerOffSocket: URL { vmHome.appendingPathComponent("power.sock") }
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
            // Android's disk and sockets are this Mac user's alone, as a phone's storage is its
            // owner's: other users of the Mac can't read the folder.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            let firstLaunch = !FileManager.default.fileExists(atPath: disk.path)
            AppLog.write(firstLaunch ? "Setting up Android for the first time" : "Starting Android")
            status(firstLaunch ? "Setting up Android, the first launch takes longer…" : "Starting Android…")
            try VMInstaller.installIfNeeded(at: disk)
            try AndroidFiles.prepare()
            try updateDiskIfNeeded(firstLaunch: firstLaunch, status: status)
            growDiskToMac()
            try launchVM()
        }

        let start = Date(), deadline = start.addingTimeInterval(180)
        var booted: Date?
        var fixedFolders = false
        while !isReady() {
            // The ad blocker's authority is trusted as Android starts, before any window opens
            // its app, so none has to start again for it.
            if (try? AdbClient.shell("getprop sys.boot_completed", timeout: 5))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                booted = booted ?? Date()
                // Never held up by it: after a while the apps open anyway, and are started again
                // once it's trusted, as before.
                if !fixedFolders { fixAppFolders(); fixedFolders = true }
                if !trustAdBlockAuthority(), let since = booted, Date().timeIntervalSince(since) > 15 {
                    _ = try? shell("su 0 setprop \(Self.authorityReady) 1")
                }
            }
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
        shareVideoDecoders()
        turnOffBluetooth()
        letGoogleLocate()
        letGoogleFill()
        keepUnlocked()
        letHelperHostWidgets()
        nameDevice()
        watchPackages()
        watchSleep()
        NotificationBridge.shared.start()
        AndroidFiles.watch()
        followMac()
        // As Android starts again without it, for apps whose ads are blocked; the helper may still
        // be making it, the first time after an update.
        DispatchQueue.global().async {
            for _ in 0..<30 {
                if self.trustAdBlockAuthority() { return }
                let chosen = (try? self.shell("su 0 cat /data/data/\(NotificationBridge.agent)/files/adblock 2>/dev/null")) ?? ""
                if chosen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                Thread.sleep(forTimeInterval: 1)
            }
        }
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
    /// Google Play services is Android's location service once the user adds it, as on a phone,
    /// where Android lets it know where the phone is from the first start. Added later here, it
    /// never got that leave, and apps asking it got no location; it's given what a phone gives.
    /// The two members of Android's widget host that its own launchers use to see what a tap
    /// on a widget starts, so that an app it opens opens in its Mac window (WidgetHost). Android
    /// lets processes use them once named here; set before the helper starts or is updated.
    private func letHelperHostWidgets() {
        let members = "Landroid/appwidget/AppWidgetHostView;->setInteractionHandler,"
            + "Landroid/widget/RemoteViews$RemoteResponse;->getLaunchOptions"
        let current = (try? shell("settings get global hidden_api_blacklist_exemptions"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != members else { return }
        _ = try? shell("settings put global hidden_api_blacklist_exemptions '\(members)'")
    }

    /// The widgets an app offers, as the helper's WidgetList prints them; nil if it couldn't tell.
    func widgetList(package: String) -> [[String: Any]]? {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return nil }
        let agent = NotificationBridge.agent
        guard let output = try? shell("su 0 sh -c 'CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).WidgetList \(package)'"),
              let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("[") }),
              let list = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]] else { return nil }
        return list
    }

    /// An app's shortcuts, as holding its icon on a phone shows them, from the helper's
    /// Shortcuts: each its id, label and icon as PNG; nil if Android couldn't tell.
    func shortcuts(package: String) -> [(id: String, label: String, icon: Data?)]? {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return nil }
        let agent = NotificationBridge.agent
        guard let output = try? shell("su 0 sh -c 'CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).Shortcuts list \(package)'"),
              let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("[") }),
              let list = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? String, let label = item["label"] as? String else { return nil }
            return (id, label, (item["icon"] as? String).flatMap { Data(base64Encoded: $0) })
        }
    }

    /// Opens one of an app's shortcuts on the display of its window.
    func openShortcut(package: String, id: String) {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return }
        // Its id goes to Android's shell, so only as base64-safe hex.
        let hex = id.utf8.map { String(format: "%02x", $0) }.joined()
        let display = Self.display(of: package) ?? 0
        let agent = NotificationBridge.agent
        _ = try? shell("su 0 sh -c 'CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).Shortcuts open \(package) \(hex) \(display)'")
    }

    /// The display of the app's window: one of Inquiline's, not Android's own (0).
    static func display(of package: String) -> Int? {
        guard let output = try? AdbClient.shell("dumpsys activity activities | grep -E '^Display #|Hist  #'") else { return nil }
        var current: Int?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Display #") {
                current = Int(line.dropFirst("Display #".count).prefix { $0.isNumber })
            } else if line.contains(" \(package)/"), let current, current > 0 {
                return current
            }
        }
        return nil
    }

    /// Google's passwords and passkeys fill in apps' sign-in screens, as a phone with Google Play
    /// has them from the start: Google Play services is Android's autofill and passkey provider
    /// unless the user chose another in Android's Settings.
    private func letGoogleFill() {
        let autofill = "com.google.android.gms/.autofill.service.AutofillService"
        let passkeys = "com.google.android.gms/.auth.api.credentials.credman.service.PasswordAndPasskeyService"
        guard (try? shell("pm path com.google.android.gms"))?.contains("package:") == true,
              let current = try? shell("settings get secure autofill_service; settings get secure credential_service")
        else { return }
        let values = current.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        func unset(_ index: Int) -> Bool { index >= values.count || values[index].isEmpty || values[index] == "null" }
        if unset(0) { _ = try? shell("settings put secure autofill_service \(autofill)") }
        if unset(1) {
            _ = try? shell("settings put secure credential_service \(passkeys); settings put secure credential_service_primary \(passkeys)")
        }
    }

    /// Android here never has a screen lock: its lock screen is on a screen no window shows, so
    /// with one its apps' windows would stay black, and after each start its apps' data would
    /// stay locked until it's unlocked. The Mac's own login guards it instead. Settings' screens
    /// that set a lock are turned off, as is the one other apps ask for (passkeys do).
    private func keepUnlocked() {
        let screens = ["ChooseLockGeneric", "ChooseLockGeneric\\$InternalActivity", "ChooseLockPassword", "ChooseLockPattern",
                       "SetNewPasswordActivity", "ScreenLockSuggestionActivity", "SetupChooseLockGeneric",
                       "SetupChooseLockPassword", "SetupChooseLockPattern"]
        guard let disabled = try? shell("dumpsys package com.android.settings | sed -n '/disabledComponents:/,/enabledComponents:/p'"),
              !disabled.contains("password.SetupChooseLockPattern") else { return }
        let commands = screens.map { "pm disable 'com.android.settings/.password.\($0)'" }.joined(separator: "; ")
        _ = try? shell("su 0 sh -c \"\(commands)\" >/dev/null 2>&1")
    }

    /// Opens Android's assistant (Gemini, once installed) over an app, as holding a phone's power
    /// button does: the app's task comes into focus, as touching it does, and Android opens the
    /// assistant on the screen in focus, the app's window, and gives it that screen (its system
    /// services are patched for that: Scripts/vm/build-services.sh).
    func showAssistant(task: Int) {
        let agent = NotificationBridge.agent
        // A phone comes with an assistant; Android here has none until the Google app is there
        // (missingAssistantApps): it becomes the assistant then, as on a phone.
        let current = (try? shell("settings get secure voice_interaction_service"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if current.isEmpty || current == "null" {
            _ = try? shell("cmd role add-role-holder --user 0 android.app.role.ASSISTANT \(Self.assistantApps[0].package)")
        }
        // The assistant reuses its open screen, which is left on another screen when the window it
        // was over closed (Android moves a closed screen's tasks to the main screen), or over
        // another app's window. That one is closed first, so the assistant opens anew over this
        // app, as on a phone's one screen. A window's own app, the bottom of its screen, stays,
        // as the assistant's app (Google) can be open in its own window.
        // Android asks before the assistant shares the screen live (Gemini Live), on the main
        // screen, which nothing shows; so the assistant, which the user calls with this button,
        // may share it, and what it shares is this app's screen (Vendor/services).
        let stale = """
            p=$(settings get secure voice_interaction_service | cut -d/ -f1); \
            appops set $p PROJECT_MEDIA allow; \
            am stack list | awk -v t=\(task) -v p="$p/" '\
            /^RootTask/ { r = substr($2, 4); for (i = 3; i <= NF; i++) if ($i ~ /^displayId=/) d = substr($i, 11); \
                bottom[d] = r } \
            /^  taskId=/ { if (substr($1, 8) + 0 == t) td = d; if (index($2, p) == 1) s[r] = d } \
            END { for (r in s) if (td != "" && s[r] != td && (s[r] == 0 || bottom[s[r]] != r)) print r }' \
            | while read r; do am stack remove $r; done
            """
        _ = try? shell(stale + "; CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).Focus \(task); "
                       + "su 1000 cmd voiceinteraction show >/dev/null 2>&1")
    }

    /// The apps Android's assistant, Gemini, needs, which a phone comes with: the Google app, which
    /// is the assistant, and Gemini.
    static let assistantApps = [(package: "com.google.android.googlequicksearchbox", name: "Google"),
                                (package: "com.google.android.apps.bard", name: "Gemini")]

    /// Those of the assistant's apps not installed yet; nil without Google Play, which has them.
    func missingAssistantApps() -> [(package: String, name: String)]? {
        guard let list = try? shell("pm list packages") else { return nil }
        let installed = Set(list.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        guard installed.contains("package:com.android.vending") else { return nil }
        return Self.assistantApps.filter { !installed.contains("package:\($0.package)") }
    }

    /// Brings an app's task into focus in Android, as touching its screen does, so a
    /// controller's buttons go to it.
    func focus(task: Int) {
        let agent = NotificationBridge.agent
        _ = try? shell("CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).Focus \(task)")
    }

    /// Android's on-screen keyboard on a task's screen, for a phone that shows the window and
    /// types by touch, as on a phone; or none, as Inquiline's windows type with the Mac's
    /// keyboard. Android hides it while a keyboard is plugged in (the Mac's, KeyboardBridge)
    /// unless asked to show it anyway, as its own setting does ("Show on-screen keyboard").
    func setTouchKeyboard(_ on: Bool, display: Int) {
        let agent = NotificationBridge.agent
        _ = try? shell("CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).Keyboard \(display) \(on ? 0 : 2); "
                       + "settings put secure show_ime_with_hard_keyboard \(on ? 1 : 0)")
    }

    /// When no window shows Android, the assistant stops listening (Gemini Live): on a phone its
    /// bar and notification show while it talks, here nothing would, nor let it be ended.
    func endListeningAssistant() {
        _ = try? shell("p=$(settings get secure voice_interaction_service | cut -d/ -f1); "
                       + "[ -n \"$p\" ] && cmd appops get $p RECORD_AUDIO | grep -q '(running)' && am force-stop $p")
    }

    private func letGoogleLocate() {
        let gms = "com.google.android.gms"
        guard let held = try? shell("dumpsys package \(gms) | grep -E 'ACCESS_(FINE|COARSE|BACKGROUND)_LOCATION: granted=true' | wc -l"),
              let count = Int(held.trimmingCharacters(in: .whitespacesAndNewlines)), count < 3,
              (try? shell("pm path \(gms)"))?.contains("package:") == true
        else { return }
        let permissions = ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION"]
        let grants = permissions.map { "pm grant \(gms) android.permission.\($0)" }.joined(separator: "; ")
        _ = try? shell("su 0 sh -c '\(grants); appops set \(gms) COARSE_LOCATION allow; appops set \(gms) FINE_LOCATION allow'")
        AppLog.write("Google Play services may now locate, as on a phone")
    }

    /// Android's video decoders (VideoDecoders) learn where the Mac listens and which kinds of
    /// video it decodes, in a file only their service reads. Android lists its codecs as it
    /// starts, from the file the last start left: when the kinds changed (the first start, or
    /// another Mac), its media service lists them again.
    private func shareVideoDecoders() {
        guard VideoDecoders.shared.port != 0 else { return }
        let file = "/data/vendor/inquiline/decoder"
        _ = try? shell("su 0 sh -c 'old=$(cut -d\" \" -f3 \(file) 2>/dev/null); mkdir -p /data/vendor/inquiline"
                       + " && echo \(VideoDecoders.shared.key) > \(file) && chown -R mediacodec:mediacodec /data/vendor/inquiline"
                       + " && chmod 700 /data/vendor/inquiline && chmod 400 \(file)"
                       + " && [ \"$old\" = \"$(cut -d\" \" -f3 \(file))\" ] || { stop media; start media; }'")
    }

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
    /// volumes stay at their highest: ringtones, alarms and system sounds. Music and games
    /// start at their highest too, and then stay where the user puts them in an app's window
    /// (mediaVolume), as Android keeps them. Notifications are silent in Android: the Mac plays
    /// their sound (NotificationBridge), so Focus applies to them.
    private func setFullVolume() {
        _ = try? shell("for v in '1 7' '2 7' '4 7' '5 0'; do cmd audio set-volume $v >/dev/null; done; "
                       + "[ \"$(settings get global inquiline_media_volume)\" = set ] || "
                       + "{ cmd audio set-volume 3 15 >/dev/null; settings put global inquiline_media_volume set; }")
    }

    static let mediaVolumeSteps = 15

    /// Android's music and game volume, from 0 to mediaVolumeSteps; nil if Android can't say.
    func mediaVolume() -> Int? {
        guard let output = try? shell("dumpsys audio | sed -n '/- STREAM_MUSIC:/,/Current:/p' | grep 'Current:'"),
              let match = output.range(of: #"\): (\d+)"#, options: .regularExpression) else { return nil }
        return Int(output[match].filter(\.isNumber))
    }

    /// Android's equalizer on all its sound (the helper's Sound): "off", "preset <n>" or
    /// "bands <five levels in millibels>".
    func equalizer() -> String {
        let value = (try? shell("su 0 cat /data/data/\(NotificationBridge.agent)/files/eq 2>/dev/null"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "off" : value
    }

    func setEqualizer(_ choice: String) {
        guard choice.range(of: "^(off|preset [0-9]+|bands( -?[0-9]+){5})$", options: .regularExpression) != nil else { return }
        _ = try? shell("su 0 am broadcast -n \(NotificationBridge.agent)/.Sound --es eq '\(choice)' >/dev/null")
    }

    /// How much louder Android plays, from 0 to 100 (the helper's Sound).
    func loudness() -> Int {
        Int((try? shell("su 0 cat /data/data/\(NotificationBridge.agent)/files/loudness 2>/dev/null"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    func setLoudness(_ level: Int) {
        _ = try? shell("su 0 am broadcast -n \(NotificationBridge.agent)/.Sound --es loudness '\(min(max(level, 0), 100))' >/dev/null")
    }

    static let equalizerPresets = ["Normal", "Classical", "Dance", "Flat", "Folk", "Heavy Metal", "Hip Hop", "Jazz", "Pop", "Rock"]
    static let equalizerBands = ["60", "230", "910", "3.6k", "14k"]

    func setMediaVolume(_ volume: Int) {
        _ = try? shell("cmd audio set-volume 3 \(min(max(volume, 0), Self.mediaVolumeSteps))")
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
            while recv(socket, &buffer, buffer.count, 0) > 0 {
                onPackagesChanged?()
                fixAppFoldersSoon()
            }
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
            vm?.terminate()
            return
        }
        defer { lock.unlock() }
        // Frozen, it couldn't shut down cleanly.
        Self.wake()
        guard vm != nil || isDeviceAttached() else { return }
        AppLog.write("Stopping Android")
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
        if let socket = try? ScrcpyServer.openSocket(path: powerOffSocket.path) { close(socket) }
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
              packages.contains("package:"),
              (try? AdbClient.shell("getprop \(authorityReady)", timeout: 5))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
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
    /// 22: Android's disk in Finder takes a password only Inquiline knows (Samba).
    /// 23: a GPS (Vendor/gnss) that reports where the Mac is.
    /// 24: a broadcast too large for its app is dropped alone, not retried by killing the app.
    /// 25: Android's video decoders hand video to the Mac's hardware (VideoDecoders).
    /// 26: they also bring pictures into memory for apps that read them there.
    /// 27: video up to 1080p on Macs whose chip doesn't decode AV1 (M1, M2).
    /// 28: video up to 4K on every Mac again.
    /// 29: Android's video decoders as in revision 25's first release to testers.
    /// 30: they work as a phone's hardware decoders do: inputs never wait for pictures.
    /// 31: Android's KDE Connect is reached through the VM (its TCP port 1716), for notifications.
    /// 32: Android's shared storage is on the Mac, through 9p (inquiline-storage); Samba goes.
    /// 33: Android's sound driver plays from a ring at the clock's pace (after the emulator's), at
    /// the Mac's 48 kHz: about a third of the delay it had.
    /// 34-37: HDR video, tried by testers and withdrawn.
    /// 38: the video decoders and system services as in 33.
    /// 39: the sound driver says the sound is as far along as it leads the picture on the Mac
    /// (vendor.inquiline.audio.lead_ms, PictureSoundSync), so players keep the two together.
    /// 40: the sound driver holds the sound back by that much, to the millisecond, as a TV does
    /// for its picture: before, it could only say so within its ring, which was too little.
    /// 41: the driver measures how far behind its clock the sound leaving Android is, and holds
    /// it back to what Inquiline asks (the picture's way, less the engine's and speakers').
    /// 42: sound later than its picture: the driver tells players the sound as really heard, so
    /// they show their pictures later, as Android asks of a sound driver.
    /// 43: its latency is what it really is too, for players that time pictures by that.
    private static let diskRevision = 43

    private var builtInScreen: ScrcpySession.Screen { ScrcpySession.Resolution.forThisMac.screen(landscape: false) }
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
    /// gets it only when the bundled disk is older than this revision.
    private func updateDiskIfNeeded(firstLaunch: Bool, status: (String) -> Void) throws {
        let revision = firstLaunch ? VMInstaller.bundledRevision
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
            // Android's built-in screen is as sharp as its apps' windows (ScrcpySession), as a
            // phone's is its panel: apps size video by it, YouTube's quality list among them.
            "-append", "root=/dev/vda rw selinux=0 quiet page_reporting.page_reporting_order=2 sysctl.vm.compaction_proactiveness=100"
                + " inquiline.screen=\(builtInScreen.width)x\(builtInScreen.height)x\(builtInScreen.density)",
            "-drive", "if=virtio,format=raw,file=\(disk.path),cache=writeback,discard=unmap",
            // Android's Vulkan goes to the Mac's GPU through gfxstream and MoltenVK, and its
            // GLES is ANGLE on that Vulkan, so the Mac needs no GLES of its own. Android 15
            // knows Vulkan up to 1.3, and its tools crash on a driver claiming 1.4.
            "-device", "virtio-gpu-rutabaga-pci,gfxstream-vulkan=on,x-gfxstream-gles=on,x-gfxstream-composer=on,"
                + "hostmem=2G,x-gfxstream-features=GuestVulkanOnly:enabled;GuestVulkanMaxApiVersion:1.3",
            // Android's sound card: its audio HAL plays into it, and QEMU plays it on the Mac.
            "-audiodev", "coreaudio,id=sound", "-device", "virtio-sound-pci,audiodev=sound,id=sound",
            // Memory is taken as Android needs it, and this reports what it frees to QEMU,
            // which gives it back to the Mac through memory-release.c.
            "-device", "virtio-balloon-pci,free-page-reporting=on",
            "-device", "virtio-net-pci,netdev=n,romfile=",
            "-netdev", "user,id=n,hostfwd=unix:\(adbSocket.path)-:5555,hostfwd=unix:\(kdeConnectSocket.path)-:1716,hostfwd=unix:\(powerOffSocket.path)-:5000",
            // Android's shared storage, its /data/media, is on the Mac (AndroidFiles), as Android
            // keeps it: owners and modes in the files' extended attributes, which Finder leaves alone.
            "-fsdev", "local,id=storage,path=\(AndroidFiles.storageRoot.path.replacingOccurrences(of: ",", with: ",,")),security_model=mapped-xattr",
            "-device", "virtio-9p-pci,fsdev=storage,mount_tag=storage",
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
        env.merge(VideoDecoders.shared.environment) { $1 }
        // The storage's "0", Android's first user's, is the Mac's Android folder (QEMU patch 0107).
        env["INQUILINE_STORAGE"] = AndroidFiles.folder.path
        // MoltenVK's errors only; its warnings would fill the log.
        env["MVK_CONFIG_LOG_LEVEL"] = "1"
        // A GPU error in one app's work (a timeout, or the Mac's GPU discarding others' work as it
        // recovers) drops that work only, as a phone's GPU driver does, instead of losing every
        // app's device; MoltenVK still loses it all when the GPU itself is gone.
        env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Self.engineLog() ?? FileHandle.nullDevice
        process.terminationHandler = { engine in
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

    /// What the app takes on Android's storage, in bytes, as Settings > Apps > Storage shows it
    /// (the helper's Sizes class); nil when Android can't say.
    func storage(package: String) -> (app: Int64, data: Int64, cache: Int64)? {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return nil }
        let agent = NotificationBridge.agent
        guard let output = try? shell("su 0 sh -c 'CLASSPATH=$(pm path \(agent) | cut -d: -f2) app_process / \(agent).Sizes \(package)'")
        else { return nil }
        let numbers = output.split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
        guard numbers.count == 3 else { return nil }
        return (numbers[0], numbers[1], numbers[2])
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

    /// What the helper blocks in the app (its AdBlock class): nil when Android can't say, empty
    /// when its ads aren't blocked, else the categories on for it ("ads", "privacy"...).
    func adBlocking(package: String) -> Set<String>? {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
              let output = try? shell("su 0 cat /data/data/\(NotificationBridge.agent)/files/adblock 2>/dev/null; echo end")
        else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.first.map(String.init) == package else { continue }
            let names = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : ["ads", "privacy", "malware"]
            return Set(names)
        }
        return []
    }

    /// How many requests the ad blocker blocked in the app, by category, since they were last
    /// reset (the helper's Counts): only categories with any.
    func adCounts(package: String) -> [String: Int] {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
              let output = try? shell("su 0 cat /data/data/\(NotificationBridge.agent)/files/adblock-counts 2>/dev/null")
        else { return [:] }
        var counts: [String: Int] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == package, let count = Int(parts[2]) else { continue }
            counts[String(parts[1])] = count
        }
        return counts
    }

    func resetAdCounts(package: String) {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return }
        _ = try? shell("su 0 am start-foreground-service -n \(NotificationBridge.agent)/.AdBlock --es reset \(package)")
    }

    /// What is blocked in the app, each category on its own ("ads", "privacy"...); none turns the
    /// ad blocker off for it.
    func setAdCategories(_ categories: Set<String>, package: String) {
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
              categories.allSatisfy({ $0.range(of: "^[a-z]+$", options: .regularExpression) != nil })
        else { return }
        let agent = NotificationBridge.agent
        _ = try? shell("appops set \(agent) ACTIVATE_VPN allow; su 0 am start-foreground-service -n \(agent)/.AdBlock "
                       + "--es set \(package)=\(categories.sorted().joined(separator: ","))")
        // The helper makes this installation's authority the first time; it's trusted once it's there.
        guard !categories.isEmpty else { return }
        for _ in 0..<20 {
            if trustAdBlockAuthority() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Set once Android trusts the ad blocker's authority this start, or there is none yet:
    /// windows wait for it before they open their apps (isReady), so no app opened as Android
    /// starts has to be ended to see the authority.
    private static let authorityReady = "vendor.inquiline.authority_ready"

    private var fixingAppFolders = false
    private let fixingLock = NSLock()

    /// Apps Inquiline ended to start again (wasEndedBySystem), one empty file each.
    private static let restartMarks = "/data/local/tmp/inquiline-restart"

    /**
     * Makes Android trust the ad blocker's authority, which the helper made for this installation
     * alone: in the system store, which apps trust, and in the user's, which is the one Chrome
     * trusts beside its own roots. The system store is read-only, so a copy with it is laid over
     * it, for Android and its app launcher (zygote), each start, and for the apps already running
     * (Google Play services starts before it, and would refuse the proxy that looks at its ad
     * requests). Apps may also listen on port 443, where the proxy takes Google Play services' ad
     * connections (Proxy.AD_SERVERS). Returns false while there is none.
     */
    @discardableResult
    func trustAdBlockAuthority() -> Bool {
        let files = "/data/data/\(NotificationBridge.agent)/files"
        let store = "/apex/com.android.conscrypt/cacerts", copy = "/dev/inquiline-cacerts"
        let script = """
            N=$(cat \(files)/ca.name 2>/dev/null); [ -n "$N" ] || { setprop \(Self.authorityReady) 1; echo none; exit 0; }; \
            if [ ! -f \(copy)/$N ]; then mkdir -p \(copy) && cp \(store)/* \(copy)/ && cp \(files)/ca.pem \(copy)/$N && chmod 644 \(copy)/*; fi; \
            [ -f \(store)/$N ] || mount --bind \(copy) \(store); \
            Z=$(pidof zygote64 zygote); NEW=; \
            for p in $Z; do nsenter --mount=/proc/$p/ns/mnt -- sh -c "[ -f \(store)/$N ]" || { NEW=1; nsenter --mount=/proc/$p/ns/mnt -- mount --bind \(copy) \(store); }; done; \
            for p in $(ps -A -o PID=,PPID= | while read a b; do case " $Z " in *" $b "*) echo $a;; esac; done); do \
            nsenter -t $p -m -- sh -c "[ -f \(store)/$N ]" || nsenter -t $p -m -- mount --bind \(copy) \(store); done; \
            echo 443 > /proc/sys/net/ipv4/ip_unprivileged_port_start; \
            U=/data/misc/user/0/cacerts-added; mkdir -p $U && cp \(files)/ca.pem $U/$N && chown system:system $U $U/$N && chmod 644 $U/$N; \
            if [ -n "$NEW" ]; then for a in $(cut -d" " -f1 \(files)/adblock 2>/dev/null); do P=$(pidof $a) && mkdir -p \(Self.restartMarks) && touch \(Self.restartMarks)/$a && kill -9 $P; done; fi; \
            setprop \(Self.authorityReady) 1; echo trusted
            """
        // An app only sees an authority added after it started once it starts again, as on a
        // phone: those running with their ads blocked then start again, their windows reopening
        // them (restartMarks), so they don't refuse every site the proxy opens for them.
        return (try? shell("su 0 sh -c '\(script)'"))?.contains("trusted") == true
    }

    /// Gives each app back its folders in shared storage (Android/data, Android/obb), as Android's
    /// vold does (fixupAppDir): an app installed again gets a new user ID, and folders an earlier
    /// install left keep the old one, so the app can't write there and says storage is full.
    func fixAppFolders() {
        let script = """
            pm list packages -U | while read l; do p=${l#package:}; p=${p%% *}; u=${l##*uid:}; u=${u%%,*}; \
            for d in /data/media/0/Android/data/$p /data/media/0/Android/obb/$p; do \
            [ -d $d ] && find $d ! -user $u -exec chown $u {} + ; done; done
            """
        _ = try? shell("su 0 sh -c '\(script)'")
    }

    /// fixAppFolders once installing settles, as an app's install changes /data/app several times.
    private func fixAppFoldersSoon() {
        fixingLock.lock()
        defer { fixingLock.unlock() }
        guard !fixingAppFolders else { return }
        fixingAppFolders = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.fixingLock.lock()
            self.fixingAppFolders = false
            self.fixingLock.unlock()
            self.fixAppFolders()
        }
    }

    /// How far the sound leads the picture on the Mac, for Android's sound driver to make up
    /// (PictureSoundSync).
    func setSoundLead(ms: Int) {
        _ = try? shell("su 0 setprop vendor.inquiline.audio.lead_ms \(min(max(ms, -200), 200))")
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
        guard package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return false }
        // Ended by Inquiline so it starts again trusting the ad blocker (trustAdBlockAuthority).
        if (try? shell("su 0 rm \(Self.restartMarks)/\(package) 2>/dev/null && echo restart"))?.contains("restart") == true {
            return true
        }
        guard let output = try? shell("dumpsys activity exit-info \(package) | grep -E 'timestamp=|process='")
        else { return false }
        // Updated while open, whatever ended it: an app that updates itself, as Google Play does,
        // ends on its own first.
        if let updated = try? shell("dumpsys package \(package) | grep -m1 lastUpdateTime="),
           let range = updated.range(of: "lastUpdateTime=") {
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let time = format.date(from: String(updated[range.upperBound...].prefix(19))), time > since {
                return true
            }
        }
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
            // Inquiline's own helpers inside Android, which the user never sees.
            .filter { $0 != NotificationBridge.agent && $0 != KDEConnect.package }
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

    /// The whole VM starts again: Android's shared storage (9p) and Google's files are
    /// mounted before Android starts. Restarting Android's container alone left it unable to
    /// start again with the storage on the Mac.
    private func restart(status: @escaping (String) -> Void) throws {
        status("Restarting Android…")
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

    /// The device's Google Services Framework ID, in decimal as Google's registration page
    /// takes it; nil before Play Store has been signed in to.
    func googleServicesID() -> String? {
        // Play Services keeps it now; the framework itself did before. Read-only, and only a
        // file that's there, so nothing is made in Google's folders.
        let query = "\\\"select value from main where name='android_id'\\\""
        let output = try? shell("su 0 sh -c \"for d in /data/data/com.google.android.gms/databases/gservices.db "
                                + "/data/data/com.google.android.gsf/databases/gservices.db; do "
                                + "[ -f \\$d ] && sqlite3 -readonly \\$d \(query) && break; done\"")
        let id = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.range(of: "^[0-9]+$", options: .regularExpression) != nil ? id : nil
    }

    private func shell(_ command: String) throws -> String {
        try AdbClient.shell(command)
    }
}
