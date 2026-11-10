import AppKit
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

/// Inquiline itself: an icon in the menu bar that runs Android for the apps in
/// the Applications folder, and adds APKs and Google Play. Android starts when an
/// app opens and stops a while after the last one quits, so it holds no memory unused.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUStandardUserDriverDelegate {
    private static let appPrefix = "io.github.inquiline-app.app."
    private static let idleLimit: TimeInterval = 5 * 60

    private var statusItem: NSStatusItem!
    /// Sparkle: checks GitHub for a new version once a day, and on "Check for Updates…".
    /// Installing one quits Inquiline, which stops its apps and Android first.
    private var updater: SPUStandardUpdaterController?
    private var library: Library!
    private let launchQueue = DispatchQueue(label: "inquiline.launch")
    private let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    private var busy = 0
    private var idleSince: Date?
    private var status: String? {
        didSet {
            updateStatusIcon()
            if let status { progress?.show(status) }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies would fight over one Android: a second one, such as another download
        // of Inquiline, passes what it was asked to open on to the first and leaves
        // without touching Android.
        running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0 != .current }
        if running != nil { return }
        // APKs opened from Finder can arrive before didFinishLaunching.
        library = Library(home: AndroidRuntime.shared.home)
        AndroidRuntime.shared.onPackagesChanged = { [weak self] in
            DispatchQueue.main.async { self?.packagesChanged() }
        }
        AppShortcuts.onRemoved = { [weak self] package in
            DispatchQueue.main.async { self?.removedFromApplications(package) }
        }
        library.onChange = { [weak self] in self?.updateShortcuts() }
    }

    private var running: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let running {
            running.activate()
            exit(0)
        }
        if offerToMoveToApplications() { return }
        watchForRemoval()
        AppLog.write("Started \(ProblemReport.version) on \(ProblemReport.mac), \(ProblemReport.macOS)")
        // A test copy (INQUILINE_HOME) never replaces itself.
        if AndroidRuntime.testHome == nil {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        }
        // Android's connections can drop at any time, which must not end the app.
        signal(SIGPIPE, SIG_IGN)
        // Without this, being killed would leave the VM running with no app to stop it.
        signal(SIGTERM, SIG_IGN)
        terminationSource.setEventHandler { NSApp.terminate(nil) }
        terminationSource.resume()
        // A disk left by a run that crashed points at an Android that isn't there.
        DispatchQueue.global().async { AndroidFiles.eject(gone: true) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        updateStatusIcon()
        updateShortcuts()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.stopAndroidIfIdle() }
        // A game loading for the first time reads gigabytes within a minute, so the cache is
        // looked at often; it costs a few milliseconds when there's nothing to drop.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            guard AndroidRuntime.shared.isRunning else { return }
            DispatchQueue.global(qos: .utility).async { AndroidRuntime.shared.trimFileCache() }
        }

        CommandLine.arguments.dropFirst().filter { $0.lowercased().hasSuffix(".apk") }
            .forEach { install(apk: URL(fileURLWithPath: $0)) }

        // The first time, show where Inquiline is, as it has no window.
        // A run loop timer, not the main queue: the open menu would hold the queue up.
        if library.apps.isEmpty {
            statusItem.button?.perform(#selector(NSButton.performClick(_:)), with: nil, afterDelay: 0.5)
        }
    }

    /// A downloaded Mac app belongs in the Applications folder; one opened from elsewhere, as
    /// Downloads or its disk image, offers to move itself there once, as many Mac apps do.
    /// Returns whether it's moving, and so about to start again from there.
    private func offerToMoveToApplications() -> Bool {
        let here = Bundle.main.bundleURL
        let key = "DontMoveToApplications"
        guard AndroidRuntime.testHome == nil, !here.path.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key),
              FileManager.default.isWritableFile(atPath: "/Applications")
        else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Inquiline to the Applications folder?"
        alert.informativeText = "Inquiline belongs there, next to the apps it adds."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: key) }
        guard response == .alertFirstButtonReturn else { return false }

        let files = FileManager.default
        let destination = URL(fileURLWithPath: "/Applications/Inquiline.app")
        do {
            if files.fileExists(atPath: destination.path) { try files.trashItem(at: destination, resultingItemURL: nil) }
            try files.copyItem(at: here, to: destination)
        } catch {
            showError("Couldn't move Inquiline", error)
            return false
        }
        // The copy it started from goes to the Trash, unless macOS ran it from a hidden,
        // read-only place (App Translocation, or the disk image), where it stays.
        if files.isDeletableFile(atPath: here.path) { try? files.trashItem(at: here, resultingItemURL: nil) }
        // Started again only once this one has quit: two at once would close the new one.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", destination.path]
        try? relaunch.run()
        exit(0)
    }

    /// APK files, and inquiline://start from an app that needs Android.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let running, let app = running.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
            return
        }
        for url in urls {
            if url.scheme == "inquiline", url.host == "open",
               let package = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "package" })?.value {
                reopenUpdated(package: package)
            } else if url.scheme == "inquiline", url.host == "restart",
                      let package = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "package" })?.value {
                // An app starting again for a new resolution, opened as from the Dock: macOS gives
                // Game Mode only to games opened that way, not to ones a quitting app's child opens.
                reopened[package] = nil
                reopenUpdated(package: package)
            } else if url.scheme == "inquiline" {
                run("Starting Android…") { try self.prepareAndroid() }
            } else {
                install(apk: url)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard running == nil else { return }
        AppLog.write("Quitting")
        runningApps.forEach { $0.terminate() }
        AndroidRuntime.shared.shutdown()
    }

    // MARK: - Menu bar

    private var pulse: Timer?

    /// Inquiline's icon; while it's at work its dot breathes, as Time Machine's icon turns
    /// while it backs up. With Reduce Motion on, the dot stays half lit instead.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.toolTip = status ?? "Inquiline"
        pulse?.invalidate()
        pulse = nil
        guard status != nil else {
            button.image = Self.menuBarIcon(dot: 1)
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            button.image = Self.menuBarIcon(dot: 0.5)
            return
        }
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak button] _ in
            let phase = Date().timeIntervalSince(start) * 2 * .pi / 1.6
            button?.image = Self.menuBarIcon(dot: 0.6 + 0.4 * cos(phase))
        }
        // Common modes: it keeps breathing while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        pulse = timer
    }

    /// Resources/Logo/MenuBarIcon.svg, drawn at the screen's scale: on a 1 pt unit, the dot
    /// and bars 2 units wide and 1 apart, the bars 12 and 8 long. A template image, so only
    /// its alpha counts and it takes the menu bar's color.
    private static func menuBarIcon(dot: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            for (from, to) in [(NSPoint(x: 5, y: 6), NSPoint(x: 5, y: 16)), (NSPoint(x: 8, y: 3), NSPoint(x: 14, y: 3))] {
                let bar = NSBezierPath()
                bar.move(to: from)
                bar.line(to: to)
                bar.lineWidth = 2
                bar.lineCapStyle = .round
                bar.stroke()
            }
            NSColor.black.withAlphaComponent(dot).set()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 2, width: 2, height: 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Inquiline"
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = status ?? (AndroidRuntime.shared.isRunning ? "Android is running" : "Android is stopped")
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add APK…", action: #selector(addAPK(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: hasGooglePlay ? "Remove Google Play…" : "Install Google Play…",
                     action: #selector(changeGooglePlay(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Apps in Finder", action: #selector(showApps(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Files in Finder", action: #selector(showFiles(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Report a Problem…", action: #selector(reportProblem(_:)), keyEquivalent: "").target = self
        if updater != nil {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Quit Inquiline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func reportProblem(_ sender: Any?) {
        var zip: URL?
        run("Gathering logs…", { zip = try ProblemReport.make() }, failure: "Couldn't make the report") { [self] in
            if let zip { reportReady(zip) }
        }
    }

    private func reportReady(_ zip: URL) {
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.activateFileViewerSelecting([zip])
        let alert = NSAlert()
        alert.messageText = "Your report is ready"
        alert.informativeText = "Finder shows it: a zip with the logs of Inquiline and Android, crash reports and your Mac's model. "
            + "Your name, e-mail addresses, web addresses and numbers that could identify you are left out. "
            + "In the form that opens, say what happened, then drag the zip into it.\n\n"
            + "The form is on GitHub, so it needs a GitHub account."
        alert.addButton(withTitle: "Open Form")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(ProblemReport.formURL()) }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates(sender)
    }

    /// A menu bar app has no Dock icon to badge, so Sparkle shows a found update's window
    /// in front instead of a reminder.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
    }

    @objc private func addAPK(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK {
            panel.urls.forEach { install(apk: $0) }
        }
    }

    @objc private func showApps(_ sender: Any?) {
        NSWorkspace.shared.open(AppShortcuts.folder)
    }

    @objc private func showFiles(_ sender: Any?) {
        run("Starting Android…") {
            try self.prepareAndroid()
            AndroidFiles.show()
        }
    }

    @objc private func toggleOpenAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Couldn't change Open at Login", error)
        }
    }

    // MARK: - Work

    /// Runs Android work in order, showing `message` in the menu bar meanwhile.
    private var progress: ProgressWindow?

    /// Runs Android work in order, showing `message` in the menu bar meanwhile, and for work
    /// that takes minutes, in a progress window with `detail`. `done` follows success.
    /// The log leaves out `hiding`, such as the name of the user's file.
    private func run(_ message: String, hiding: [String] = [], _ work: @escaping () throws -> Void, failure title: String? = nil,
                     progress detail: String? = nil, done: (() -> Void)? = nil) {
        func logged(_ text: String) -> String { hiding.reduce(text) { $0.replacingOccurrences(of: $1, with: "<file>") } }
        AppLog.write(logged(message))
        let start = Date()
        busy += 1
        if let detail {
            progress?.close()
            progress = ProgressWindow(detail: detail)
        }
        status = message
        launchQueue.async { [self] in
            var failed: Error?
            do { try work() } catch { failed = error }
            let seconds = Int(Date().timeIntervalSince(start))
            if let failed {
                AppLog.write(logged("Failed after \(seconds) s: \(message) \(failed.localizedDescription)"))
            } else {
                AppLog.write(logged("Done in \(seconds) s: \(message)"))
            }
            DispatchQueue.main.async { [self] in
                busy -= 1
                if busy == 0 { status = nil }
                if detail != nil {
                    progress?.close()
                    progress = nil
                }
                if let failed {
                    showError(title ?? "Couldn't start Android", failed)
                } else {
                    done?()
                }
            }
        }
    }

    private func setStatus(_ message: String) {
        DispatchQueue.main.async { self.status = message }
    }

    /// Boots Android, then brings the library in line with what it has installed.
    private func prepareAndroid() throws {
        try AndroidRuntime.shared.ensureReady { self.setStatus($0) }
        try syncLibrary()
    }

    private func install(apk: URL) {
        let name = apk.lastPathComponent
        run("Installing \(name)…", hiding: [name], { [self] in
            let runtime = AndroidRuntime.shared
            try prepareAndroid()
            setStatus("Installing \(name)…")
            let manifest = try runtime.install(apk: apk)
            let package = manifest.package
            AppLog.write("Installed \(package)")
            // The launcher caches a new app's icon and name shortly after installation.
            var icon = runtime.iconPNG(package: package)
            var label = runtime.label(package: package)
            for _ in 0..<10 where icon == nil || label == nil {
                Thread.sleep(forTimeInterval: 0.5)
                icon = runtime.iconPNG(package: package)
                label = runtime.label(package: package)
            }
            let info = ApkInfo(package: package, label: label ?? package, orientation: manifest.orientation,
                               isGame: runtime.isGame(package: package, manifest: manifest))
            DispatchQueue.main.sync {
                library.add(info)
                if let icon { library.setIcon(icon, package: package) }
                // As after any install, the new app is shown where it now is.
                updateShortcuts { locations in
                    if let app = locations[package] { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                }
            }
        }, failure: "Couldn't add \(name)",
           progress: "Android installs the app. A big game takes a minute or more; it then appears in Inquiline Apps.")
    }

    private func syncLibrary() throws {
        let runtime = AndroidRuntime.shared
        let installed = try runtime.installedPackages()
        let known = DispatchQueue.main.sync { library.apps }
        let missingIcons = DispatchQueue.main.sync { installed.filter { !library.hasIcon(package: $0) } }

        // Apps installed inside Android, from the Play Store for instance, start the way
        // their manifest says, as on a phone.
        // A name still missing means the launcher hadn't read the app yet when it was last looked at.
        let added = installed.filter { package in
            !known.contains { $0.package == package && $0.orientation != nil && $0.label != package && $0.isGame != nil }
        }.map { package in
            let manifest = runtime.manifest(package: package)
            return ApkInfo(package: package, label: runtime.label(package: package) ?? package, orientation: manifest?.orientation,
                           isGame: runtime.isGame(package: package, manifest: manifest))
        }
        let icons = missingIcons.compactMap { package in runtime.iconPNG(package: package).map { (package, $0) } }

        DispatchQueue.main.sync {
            known.filter { !installed.contains($0.package) }.forEach { library.remove(package: $0.package) }
            added.forEach { library.add($0) }
            icons.forEach { library.setIcon($0.1, package: $0.0) }
        }
        updateFiles()
    }

    private var filesBoot = 0
    private var filesApps: [AndroidFiles.App] = []

    /// Keeps the files disk in line with the library. The disk appears once each time
    /// Android starts, as a USB drive does when plugged in. Runs on launchQueue.
    private func updateFiles() {
        let apps = DispatchQueue.main.sync {
            library.apps.filter { $0.label != $0.package }.map { AndroidFiles.App(package: $0.package, label: $0.label) }
        }
        let boot = AndroidRuntime.shared.bootCount
        guard boot != filesBoot || apps != filesApps, (try? AndroidFiles.update(apps)) != nil else { return }
        if boot != filesBoot {
            AndroidFiles.mount()
            // What starting Android leaves behind: gathered at once, before a game starts
            // loading on top of it, and again once Android has settled.
            for delay in [0.0, 20.0] {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { AndroidRuntime.shared.compactMemory() }
            }
        }
        filesBoot = boot
        filesApps = apps
    }

    private var librarySync: DispatchWorkItem?

    /// An install sends several changes in a row, and the launcher reads the new app's name
    /// and icon shortly after, so the library is brought up to date once things have settled.
    private func packagesChanged() {
        librarySync?.cancel()
        let sync = DispatchWorkItem { [weak self] in
            self?.launchQueue.async { self?.syncUntilNamed(tries: 6) }
        }
        librarySync = sync
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: sync)
    }

    /// A busy launcher can take a while to read a new app, so this looks again until it has.
    private func syncUntilNamed(tries: Int) {
        try? syncLibrary()
        let unnamed = DispatchQueue.main.sync { library.apps.contains { $0.label == $0.package } }
        guard unnamed, tries > 1 else { return }
        launchQueue.asyncAfter(deadline: .now() + 5) { self.syncUntilNamed(tries: tries - 1) }
    }

    private func updateShortcuts(done: (([String: URL]) -> Void)? = nil) {
        // An app is only given a shortcut once its name is known.
        let apps = library.apps.filter { $0.label != $0.package }.map {
            AppShortcuts.App(package: $0.package, label: $0.label, orientation: $0.orientation ?? .both,
                             isGame: $0.isGame ?? false, icon: library.icon(package: $0.package))
        }
        AppShortcuts.sync(apps, done: done)
    }

    private var reopened: [String: Date] = [:]

    /// An app that was still on an older program has quit so it can be updated: once it's
    /// gone, it's brought up to date and opened again.
    private func reopenUpdated(package: String, tries: Int = 50) {
        // An update that failed would otherwise go round in a loop.
        if tries == 50 {
            guard Date().timeIntervalSince(reopened[package] ?? .distantPast) > 30 else { return }
            reopened[package] = Date()
        }
        let identifier = Self.appPrefix + package.replacingOccurrences(of: "_", with: "-")
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty || tries == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reopenUpdated(package: package, tries: tries - 1) }
            return
        }
        updateShortcuts { locations in
            guard let app = locations[package] else { return }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func showError(_ title: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Android's lifetime

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix(Self.appPrefix) == true }
    }

    /// Waits for the closed app to end, as it still holds its memory until then.
    @objc private func appTerminated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier?.hasPrefix(Self.appPrefix) == true else { return }
        // It may have stayed on an older program, being open when Inquiline was updated.
        updateShortcuts()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            guard runningApps.isEmpty, busy == 0, AndroidRuntime.shared.isRunning else { return }
            launchQueue.async { AndroidRuntime.shared.releaseMemory() }
        }
    }

    /// As on a Mac, nothing runs once its apps are closed: Android stops a few minutes
    /// after the last one, unless an app is still at work, as a download or music.
    private func stopAndroidIfIdle() {
        guard AndroidRuntime.shared.isRunning, runningApps.isEmpty, busy == 0 else {
            idleSince = nil
            return
        }
        let since = idleSince ?? Date()
        idleSince = since
        guard Date().timeIntervalSince(since) > Self.idleLimit else { return }
        idleSince = nil
        launchQueue.async {
            let runtime = AndroidRuntime.shared
            guard !runtime.isInstalling(), !runtime.hasForegroundWork() else { return }
            AppLog.write("Stopping Android: no app open for \(Int(Self.idleLimit / 60)) minutes")
            runtime.shutdown()
        }
    }

    // MARK: - Removing apps

    /// Moving an app to the Trash removes it as on a Mac. Its data stays inside Android,
    /// so adding it again brings back its saves.
    /// Moving an app to the Trash removes it with everything it kept, inside Android and on the
    /// Mac, as deleting an app on a phone does.
    private func removedFromApplications(_ package: String) {
        guard let app = library.app(package: package) else { return }
        AppShortcuts.forget(package: package)
        guard package != AndroidRuntime.playStorePackage else {
            changeGooglePlay(message: "Removing Google Play…",
                             detail: "Android starts again without Google's apps. This takes a minute or two.") { status in
                try AndroidRuntime.shared.removeGooglePlay(status: status)
            }
            return
        }
        run("Removing \(app.label)…", { [self] in
            try AndroidRuntime.shared.ensureReady { self.setStatus($0) }
            try AndroidRuntime.shared.uninstall(package: package)
            DispatchQueue.main.sync { library.remove(package: package) }
        }, failure: "Couldn't remove \(app.label)")
    }

    // MARK: - Removing Inquiline

    private var selfWatch: DispatchSourceFileSystemObject?
    private var selfBookmark: Data?

    /// Moving Inquiline to the Trash removes all it made, as uninstalling does on a phone: the
    /// apps added with it and their shortcuts, Android and everything in it, its settings,
    /// caches and logs. Inquiline sees it while it runs, which it does in the menu bar.
    private func watchForRemoval() {
        selfBookmark = try? Bundle.main.bundleURL.bookmarkData()
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.checkRemoved() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        selfWatch = source
    }

    private func checkRemoved() {
        guard let selfBookmark else { return }
        var stale = false
        let now = try? URL(resolvingBookmarkData: selfBookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
        guard now == nil || now!.path.contains("/.Trash/") else { return }
        // Another copy of Inquiline, as when a downloaded one was moved to Applications, keeps
        // everything.
        let others = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { !$0.path.contains("/.Trash/") && $0.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL }
        // A test copy only removes its own folder, so other copies don't matter to it.
        guard others.isEmpty || AndroidRuntime.testHome != nil else { return }
        removeEverything()
    }

    private func removeEverything() {
        selfWatch?.cancel()
        AppLog.write("Inquiline was moved to the Trash: removing everything it made")
        runningApps.forEach { $0.forceTerminate() }
        AndroidRuntime.shared.shutdown()
        AndroidFiles.eject(gone: true)
        AppShortcuts.removeAll()
        let files = FileManager.default
        if let test = AndroidRuntime.testHome {
            // A test copy only ever touches its own folder.
            try? files.removeItem(at: test)
        } else {
            try? SMAppService.mainApp.unregister()
            let home = files.homeDirectoryForCurrentUser
            let library = home.appendingPathComponent("Library")
            var gone = [AndroidRuntime.shared.home, library.appendingPathComponent("Logs/Inquiline")]
            let prefix = "io.github.inquiline-app."
            let cache = URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent().appendingPathComponent("C")
            for folder in ["Caches", "HTTPStorages", "Saved Application State", "Preferences", "WebKit"].map({ library.appendingPathComponent($0) }) + [cache] {
                for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
                    gone.append(folder.appendingPathComponent(name))
                }
            }
            gone.forEach { try? files.removeItem(at: $0) }
            // macOS keeps preferences in memory too.
            for name in (try? files.contentsOfDirectory(atPath: library.appendingPathComponent("Preferences").path)) ?? [] where name.hasPrefix(prefix) {
                CFPreferencesSynchronize(name.replacingOccurrences(of: ".plist", with: "") as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        }
        exit(0)
    }

    // MARK: - Google Play

    private var hasGooglePlay: Bool {
        library.apps.contains { $0.package == AndroidRuntime.playStorePackage }
    }

    @objc private func changeGooglePlay(_ sender: Any?) {
        if hasGooglePlay {
            confirmRemoveGooglePlay()
        } else {
            promptInstallGooglePlay()
        }
    }

    private func promptInstallGooglePlay() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Google Play"
        alert.informativeText = """
        Download MindTheGapps for Android 15 arm64, then choose its zip.

        If Safari opened the zip for you, the zip is in the Trash: Control-click it there and choose Put Back.
        """
        alert.addButton(withTitle: "Choose Zip…")
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.zip]
            panel.prompt = "Install"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let zip = panel.url else { return }
            changeGooglePlay(message: "Installing Google Play…",
                             detail: "Google's apps are added to Android, which then starts again. This takes a few minutes.",
                             done: { [self] in googlePlayReady() }) { status in
                try AndroidRuntime.shared.installGooglePlay(zip: zip, status: status)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/MindTheGapps/15.0.0-arm64/releases/latest")!)
        default:
            break
        }
    }

    private func confirmRemoveGooglePlay() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove Google Play?"
        alert.informativeText = "Android will restart. Apps installed from Google Play stay, but those that need Google may stop working."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        changeGooglePlay(message: "Removing Google Play…",
                         detail: "Android starts again without Google's apps. This takes a minute or two.") { status in
            try AndroidRuntime.shared.removeGooglePlay(status: status)
        }
    }

    /// Android restarts for this, so the apps that are open close first.
    private func changeGooglePlay(message: String, detail: String, done: (() -> Void)? = nil,
                                  _ work: @escaping (@escaping (String) -> Void) throws -> Void) {
        runningApps.forEach { $0.terminate() }
        run(message, { [self] in
            try prepareAndroid()
            setStatus(message)
            try work { self.setStatus($0) }
            try prepareAndroid()
        }, failure: "Couldn't change Google Play", progress: detail, done: done)
    }

    private func googlePlayReady() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Google Play is ready"
        alert.informativeText = "Open the Play Store and sign in with your Google account. Apps you get there appear in Inquiline Apps."
        alert.addButton(withTitle: "Open Play Store")
        alert.addButton(withTitle: "OK")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateShortcuts { locations in
            guard let store = locations[AndroidRuntime.playStorePackage] else { return }
            NSWorkspace.shared.openApplication(at: store, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
