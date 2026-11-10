import AppKit

/// The window of one running Android app.
final class AppWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    /// A Retina Mac shows two pixels a point; the app's screen has the window's pixels.
    private static let pixelsPerPoint: CGFloat = 2

    let package: String
    let window: NSWindow

    private let displayView: AndroidDisplayView
    private var session: ScrcpySession

    private let orientation: AppOrientation
    private var isLandscape: Bool
    private var userTurned = false
    private var restarted = false
    /// The app's screen in pixels.
    private var displaySize: NSSize
    private let resolution: ScrcpySession.Resolution
    private var watch: Timer?
    private let launchScreen = LaunchScreen()
    /// The Android screen this window shows, once the app has appeared on it.
    private var watchedDisplay: String?
    /// Plugged in once the session can take input, with the app's first picture.
    private var gamepads: GamepadBridge?

    init(package: String, label: String, orientation: AppOrientation, landscape: Bool) {
        self.package = package
        self.orientation = orientation
        isLandscape = landscape
        resolution = ScrcpySession.Resolution.forThisMac
        let androidScreen = resolution.screen(landscape: landscape)
        let points = Self.smallest(landscape: landscape)
        session = ScrcpySession(package: package, screen: androidScreen)
        displaySize = NSSize(width: androidScreen.width, height: androidScreen.height)
        displayView = AndroidDisplayView(frame: NSRect(origin: .zero, size: points))
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: points),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = label
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        screen.frame = NSRect(origin: .zero, size: points)
        displayView.frame = screen.bounds
        displayView.autoresizingMask = [.width, .height]
        screen.addSubview(displayView)
        overlay.frame = screen.bounds
        overlay.autoresizingMask = [.width, .height]
        screen.addSubview(overlay)
        launchScreen.frame = screen.bounds
        launchScreen.autoresizingMask = [.width, .height]
        screen.addSubview(launchScreen)
        window.contentView = screen
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        setUpControls()
        // Resizing keeps the app's screen in its shape. It opens at its smallest, a phone's
        // size, the first time, then where and as large as it was last.
        window.contentAspectRatio = displaySize
        window.contentMinSize = points
        addToolbar()
        window.setContentSize(points)
        window.center()
        window.setFrameAutosaveName("Window")
        AppLog.write("Screen of \(Int(displaySize.width)) by \(Int(displaySize.height)) pixels")
        connect(session)
    }

    /// Holds the app's screen and, until its first picture, the launch screen.
    private let screen = NSView()
    private let overlay = ControlsOverlay()

    // MARK: - Keyboard controls

    private var controlsLabelsKey: String { "ShowControls.\(package)" }

    private func setUpControls() {
        let set = KeyControlSet.load(package: package)
        displayView.controls.set = set
        overlay.set = set
        overlay.showsLabels = UserDefaults.standard.bool(forKey: controlsLabelsKey)
        overlay.screenRect = { [unowned self] in displayView.screenRect }
        overlay.onDone = { [unowned self] set in
            displayView.controls.set = set
            set.save(package: package)
            AppLog.write("Keyboard controls: \(set.controls.count)")
            window.makeFirstResponder(displayView)
        }
        displayView.onCaught = { [unowned self] caught in
            note(caught ? "Press Esc to use the pointer again" : "")
        }
    }

    @objc func editControls() {
        displayView.controls.releaseAll()
        if !UserDefaults.standard.bool(forKey: "ControlsWarningShown") {
            UserDefaults.standard.set(true, forKey: "ControlsWarningShown")
            let alert = NSAlert()
            alert.messageText = "Keyboard controls"
            alert.informativeText = "Click a button in the game, then press the key that should press it. "
                + "Add a stick for W, A, S and D, and Mouse Aim to look around with the mouse; click the game to aim, Esc to stop.\n\n"
                + "Online games such as shooters may not allow playing with a keyboard and mouse against touch players, "
                + "and can ban accounts that do. Use controls in those at your own risk."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        overlay.set = displayView.controls.set
        overlay.beginEditing()
    }

    @objc func toggleControls() {
        displayView.controls.releaseAll()
        displayView.controls.set.isOn.toggle()
        overlay.set = displayView.controls.set
        displayView.controls.set.save(package: package)
    }

    @objc func toggleControlLabels() {
        overlay.showsLabels.toggle()
        UserDefaults.standard.set(overlay.showsLabels, forKey: controlsLabelsKey)
    }

    /// The controls' commands, in the View menu and the toolbar's Controls button.
    static func addControlsItems(to menu: NSMenu, target: AppWindowController) {
        menu.addItem(withTitle: "Edit Keyboard Controls…", action: #selector(editControls), keyEquivalent: "k").target = target
        menu.addItem(withTitle: "Use Keyboard Controls", action: #selector(toggleControls), keyEquivalent: "").target = target
        menu.addItem(withTitle: "Show Keyboard Controls", action: #selector(toggleControlLabels), keyEquivalent: "").target = target
    }

    func windowDidResignKey(_ notification: Notification) {
        displayView.controls.releaseAll()
    }
    /// Pictures Android drew in the last second: Android sends one only when the app's screen
    /// changes, so this is the app's own frame rate.
    private let fpsLabel = NSTextField(labelWithString: "")
    private let frameCount = FrameCounter()
    private var fpsTimer: Timer?
    private var isMuted = false

    private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    /// In full screen the toolbar hides with the menu bar and comes down with it.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.autoHideToolbar, .autoHideMenuBar, .fullScreen])
    }

    private func connect(_ session: ScrcpySession) {
        displayView.session = session
        session.onClipboard = { [weak self] text in
            DispatchQueue.main.async {
                // Background apps must not be able to write to the Mac's clipboard.
                guard let self, self.window.isKeyWindow else { return }
                let pasteboard = NSPasteboard.general
                if pasteboard.string(forType: .string) != text {
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
            }
        }
        session.onSessionSize = { [weak self] width, height in
            self?.displayView.setDisplaySize(width: width, height: height)
            DispatchQueue.main.async {
                guard let self else { return }
                self.followAndroid(landscape: width > height)
                self.displaySize = NSSize(width: width, height: height)
                self.fitWindow()
            }
        }
        // The Mac remembers whether the app is muted: Android saves its app ops only now and
        // then, and loses the latest when the engine stops.
        let package = package, mutedKey = mutedKey
        session.beforeLaunch = {
            AndroidRuntime.shared.setMuted(UserDefaults.standard.bool(forKey: mutedKey), package: package)
        }
        let renderer = displayView.renderer
        let frames = frameCount
        var shown = false
        session.onFrame = { [weak self] resource in
            renderer?.draw(resource: resource)
            frames.add()
            guard !shown else { return }
            shown = true
            AppLog.write(String(format: "First frame %.1f s after the app was started", frames.sinceStart()))
            DispatchQueue.main.async {
                guard let self else { return }
                self.launchScreen.removeFromSuperview()
                if self.gamepads == nil { self.gamepads = GamepadBridge(session: session) }
            }
        }
        session.onEnd = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window.close()
                AppLog.write(error.map { "The connection to the app ended: \($0.localizedDescription)" } ?? "Closed")
            }
        }
    }

    /// Starts the app again on a screen turned the way it now wants.
    private func restartApp() {
        restarted = true
        gamepads?.stop()
        gamepads = nil
        session.stop()
        session = ScrcpySession(package: package, screen: resolution.screen(landscape: isLandscape), restartsApp: true)
        watchedDisplay = nil // the new session brings a new Android screen
        connect(session)
        frameCount.markStart()
        session.start()
    }

    /// Call once the window is on screen.
    func start() {
        frameCount.markStart()
        session.start()
        window.makeFirstResponder(displayView)
        watchApp()
    }

    /// When an Android app closes itself, or Back leaves its first screen, a phone goes
    /// home; the Mac equivalent is the app quitting, so its window closes. What counts
    /// is its Android screen, which may show another app's screens for a while, as
    /// Google's sign-in or Android's settings.
    private func watchApp() {
        var missing = 0
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let package = package
            DispatchQueue.global().async {
                // A failed look says nothing either way.
                guard let output = try? AdbClient.shell("dumpsys activity activities | grep -E '^Display #|Hist  #'") else { return }
                var screens: [(display: String, activity: Substring)] = []
                var current = ""
                for line in output.split(whereSeparator: \.isNewline) {
                    if line.hasPrefix("Display #") {
                        current = String(line.split(separator: " ").prefix(2).joined(separator: " "))
                    } else {
                        screens.append((current, line))
                    }
                }
                DispatchQueue.main.async {
                    self.watchedDisplay = self.watchedDisplay ?? screens.first { $0.activity.contains(" \(package)/") }?.display
                    guard let display = self.watchedDisplay else { return }
                    // A restart for a new screen shape leaves it empty for a moment.
                    missing = screens.contains { $0.display == display } ? 0 : missing + 1
                    if missing >= 2 { self.window.close() }
                }
            }
        }
    }

    /// The window scales the picture and Android's screen keeps its size, as apps don't lay
    /// out again properly when it changes under them. So the window only follows Android,
    /// when an app rotates.
    /// A window already of this shape keeps the size it was given.
    /// When the app turns, the window turns with it, as large as it was.
    private func fitWindow() {
        let size = displaySize
        let landscape = size.width > size.height
        window.contentAspectRatio = size
        window.contentMinSize = Self.smallest(landscape: landscape)
        let current = screen.frame.size
        guard !isFullScreen, abs(current.width / current.height - size.width / size.height) > 0.01 else { return }
        // Turned, the window turns; otherwise it only takes the app's shape, as wide as it was.
        var turned = (current.width > current.height) != landscape ? NSSize(width: current.height, height: current.width) : current
        turned.height = (turned.width * size.height / size.width).rounded()
        if let visible = window.screen?.visibleFrame.size {
            let scale = min(1, visible.width / turned.width, (visible.height - 38) / turned.height)
            turned = NSSize(width: (turned.width * scale).rounded(), height: (turned.height * scale).rounded())
        }
        let smallest = Self.smallest(landscape: landscape)
        window.setContentSize(turned.width < smallest.width ? smallest : turned)
    }

    /// A phone's size, in the screen's shape: the smallest a window gets.
    static func smallest(landscape: Bool) -> NSSize {
        let short = (720 / ScrcpySession.screenShape).rounded()
        return landscape ? NSSize(width: 720, height: short) : NSSize(width: short, height: 720)
    }

    // MARK: - Full screen

    private var fullScreenKey: String { "FullScreen.\(package)" }

    /// An app closed in full screen opens in full screen, as Mac apps do.
    /// Only once the app is in front: macOS gives a game Game Mode as it goes full screen there.
    func restoreFullScreen() {
        guard UserDefaults.standard.bool(forKey: fullScreenKey) else { return }
        guard NSApp.isActive else {
            fullScreenWaiter = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                      object: nil, queue: .main) { [weak self] _ in
                guard let self, let waiter = fullScreenWaiter else { return }
                NotificationCenter.default.removeObserver(waiter)
                fullScreenWaiter = nil
                restoreFullScreen()
            }
            return
        }
        // After the window settles in front, as going full screen while it's being shown is ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if !isFullScreen { window.toggleFullScreen(nil) }
        }
    }

    private var fullScreenWaiter: NSObjectProtocol?

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: fullScreenKey)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: fullScreenKey)
    }

    /// An app that turned itself may be stuck at its first screen's size, and is then
    /// started again once.
    private func followAndroid(landscape: Bool) {
        guard landscape != isLandscape else { return }
        isLandscape = landscape
        guard !userTurned, !restarted else {
            userTurned = false
            return
        }
        let package = package
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard AndroidRuntime.shared.isInSizeCompatMode(package: package) else { return }
            DispatchQueue.main.async { self?.restartApp() }
        }
    }

    private static let fpsItem = NSToolbarItem.Identifier("fps")
    private static let muteItem = NSToolbarItem.Identifier("mute")
    private static let rotateItem = NSToolbarItem.Identifier("rotate")
    private static let controlsItem = NSToolbarItem.Identifier("controls")
    private static let clearCacheItem = NSToolbarItem.Identifier("clearCache")
    private static let clearDataItem = NSToolbarItem.Identifier("clearData")

    /// The frame rate, sound and orientation, in the Mac's own toolbar.
    private func addToolbar() {
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        fpsLabel.textColor = .secondaryLabelColor
        fpsLabel.toolTip = "Frames per second"
        // As wide as a toolbar button, so it sits as far from the window's edge as one.
        fpsLabel.alignment = .center
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let counter = frameCount
        let engine = EngineLoad()
        var still = 0, moving = 0, busyFor = 0, idleFor = 0
        var minute: [Int] = []
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fps = counter.take()
            self.fpsLabel.stringValue = "\(fps)"
            // Once a minute, how smooth the app was, for finding where a game stuttered. A
            // minute with no frames is a still screen, which says nothing.
            minute.append(fps)
            if minute.count == 60 {
                let shown = minute.filter { $0 > 0 }
                if !shown.isEmpty {
                    let below30 = minute.filter { $0 > 0 && $0 < 30 }.count
                    AppLog.write("Last minute: \(shown.reduce(0, +) / shown.count) fps on average, "
                        + "\(shown.min()!) at least, \(below30) s under 30 fps, \(60 - shown.count) s still")
                }
                minute.removeAll()
            }
            // A game's first launch can sit on one picture for minutes while its graphics are
            // prepared for the Mac's GPU, which keeps the engine busy all along. A still screen
            // that leaves the engine at rest, as a sign-in or a store page, is just still. Both
            // must last, so a lone frame or a short burst of work doesn't make the note flicker.
            still = fps > 0 ? 0 : still + 1
            moving = fps > 0 ? moving + 1 : 0
            let busy = engine.cores() >= 3
            busyFor = busy ? busyFor + 1 : 0
            idleFor = busy ? 0 : idleFor + 1
            if self.loading {
                if moving >= 2 || idleFor >= 5 { self.showLoading(false) }
            } else if still >= 8 && busyFor >= 8 && self.launchScreen.superview == nil {
                // Before the app's first picture, the launch screen already says it's starting.
                self.showLoading(true)
            }
        }
        let toolbar = NSToolbar(identifier: "AppWindowToolbar3")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        showMuted(UserDefaults.standard.bool(forKey: mutedKey))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The space keeps the buttons clear of the window's rounded corner.
        [.flexibleSpace, Self.fpsItem, Self.controlsItem, Self.muteItem, Self.rotateItem, .space]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Clearing is in the app's menu; these are there for those who want them at hand.
        [.flexibleSpace, .space, Self.fpsItem, Self.controlsItem, Self.muteItem, Self.rotateItem, Self.clearCacheItem, Self.clearDataItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.controlsItem {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Keyboard Controls"
            item.toolTip = "Keyboard Controls"
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard Controls")
            item.showsIndicator = false
            let menu = NSMenu()
            Self.addControlsItems(to: menu, target: self)
            item.menu = menu
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.fpsItem:
            item.label = "FPS"
            item.view = fpsLabel
        case Self.muteItem:
            item.label = "Sound"
            item.target = self
            item.action = #selector(toggleMute)
            item.isBordered = true
            setMuteImage(of: item)
        case Self.rotateItem:
            item.label = "Rotate"
            item.toolTip = "Rotate"
            item.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: "Rotate")
            item.target = self
            item.action = #selector(rotate)
            item.isBordered = true
            // An app that only works one way can't be turned.
            item.autovalidates = false
            item.isEnabled = orientation == .both
        case Self.clearCacheItem:
            item.label = "Clear Cache"
            item.toolTip = "Clear Cache"
            item.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: "Clear Cache")
            item.target = self
            item.action = #selector(clearCache)
            item.isBordered = true
        case Self.clearDataItem:
            item.label = "Clear Data"
            item.toolTip = "Clear Data"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear Data")
            item.target = self
            item.action = #selector(clearData)
            item.isBordered = true
        default:
            return nil
        }
        return item
    }

    private var mutedKey: String { "Muted.\(package)" }

    private func showMuted(_ muted: Bool) {
        isMuted = muted
        // The toolbar's own item: Customize makes other copies for its palette.
        window.toolbar?.items.filter { $0.itemIdentifier == Self.muteItem }.forEach(setMuteImage(of:))
    }

    private func setMuteImage(of item: NSToolbarItem) {
        item.image = NSImage(systemSymbolName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             accessibilityDescription: isMuted ? "Unmute" : "Mute")
        item.toolTip = isMuted ? "Unmute" : "Mute"
    }

    @objc private func toggleMute() {
        let muted = !isMuted
        showMuted(muted)
        UserDefaults.standard.set(muted, forKey: mutedKey)
        let package = package
        DispatchQueue.global().async { AndroidRuntime.shared.setMuted(muted, package: package) }
    }

    @objc func clearCache() {
        let package = package
        DispatchQueue.global().async { [weak self] in
            AndroidRuntime.shared.clearCache(package: package)
            DispatchQueue.main.async { self?.note("Cache cleared") }
        }
    }

    /// The app starts again as if just installed: signed out, its saves and settings gone.
    @objc func clearData() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear \(window.title)'s data?"
        alert.informativeText = "This signs you out and deletes its saves and settings, as if it had just been installed. It can't be undone."
        alert.addButton(withTitle: "Clear Data").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let package = package
            DispatchQueue.global().async {
                AndroidRuntime.shared.clearData(package: package)
                DispatchQueue.main.async { self.restartApp() }
            }
        }
    }

    private var loading = false
    private static let loadingNote = "Loading… The first launch of a game can take a few minutes."

    private func showLoading(_ on: Bool) {
        guard on != loading else { return }
        loading = on
        AppLog.write(on ? "Showing the loading note" : "Hiding the loading note")
        if on { window.subtitle = Self.loadingNote }
        else if window.subtitle == Self.loadingNote { window.subtitle = "" }
    }

    /// A short note under the window's title, as Finder shows one while it works.
    private func note(_ text: String) {
        window.subtitle = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.window.subtitle == text { self?.window.subtitle = "" }
        }
    }

    @objc private func rotate() {
        guard orientation == .both else { return }
        userTurned = true
        session.sendRotate()
    }

    func windowWillClose(_ notification: Notification) {
        displayView.controls.releaseAll()
        watch?.invalidate()
        fpsTimer?.invalidate()
        gamepads?.stop()
        session.stop()
    }
}

/// What the window shows until the app's first picture arrives, as a Mac or iPhone app
/// shows while it opens: its icon and a spinner, while Android starts.
private final class LaunchScreen: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        for view in [icon, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // Clicks wait for the app.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
}

/// Counts frames on the receive thread for the window's frame rate.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var started = Date()

    /// When Android was asked to start the app, for how long its first frame took.
    func markStart() {
        lock.lock(); started = Date(); lock.unlock()
    }

    func sinceStart() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(started)
    }

    func add() {
        lock.lock(); count += 1; lock.unlock()
    }

    /// The count since the last call.
    func take() -> Int {
        lock.lock(); defer { count = 0; lock.unlock() }
        return count
    }
}

/// How many CPU cores the VM's engine used since the last call: Android's apps, and the
/// Mac-side work of preparing their graphics.
private final class EngineLoad {
    private var pid: pid_t = 0
    private var last: (cpu: UInt64, at: UInt64) = (0, 0)
    private static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

    func cores() -> Double {
        if pid == 0 || kill(pid, 0) != 0 { pid = Self.findEngine(); last = (0, 0) }
        guard pid > 0 else { return 0 }
        var info = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { return 0 }
        let cpu = (info.pti_total_user + info.pti_total_system) * UInt64(Self.timebase.numer) / UInt64(Self.timebase.denom)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { last = (cpu, now) }
        guard last.at > 0, now > last.at else { return 0 }
        return Double(cpu - min(cpu, last.cpu)) / Double(now - last.at)
    }

    private static func findEngine() -> pid_t {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).hasSuffix("/" + AndroidRuntime.engineName) {
                return pid
            }
        }
        return 0
    }
}

extension AppWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleControls):
            item.state = displayView.controls.set.isOn ? .on : .off
            return !displayView.controls.set.controls.isEmpty
        case #selector(toggleControlLabels):
            item.state = overlay.showsLabels ? .on : .off
            return !displayView.controls.set.controls.isEmpty
        default:
            return true
        }
    }
}
