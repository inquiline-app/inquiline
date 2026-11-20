import AppKit

/// The window of one running Android app.
final class AppWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSPopoverDelegate {
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
    private var displaySize: NSSize {
        didSet {
            if displaySize != oldValue { shareScreen() }
            phoneInput.update(size: displaySize)
        }
    }
    private let resolution: ScrcpySession.Resolution
    private var watch: Timer?
    private let launchScreen = LaunchScreen()
    /// Covers a flexible app while its window's size isn't Android's yet, as Android's own
    /// desktop windows do: the app's background colour with its icon, until the app has drawn
    /// for the new size.
    private let veil = NSView()
    /// The Android screen this window shows, once the app has appeared on it.
    private var watchedDisplay: String?
    /// The app's task on that screen.
    private var watchedTask: Int? {
        didSet { phoneInput.update(task: watchedTask) }
    }
    /// When the app was started in this window, last.
    private var appStarted = Date()
    /// Screens of sessions before a restart: a slow app can stay on one a while as it ends.
    private var oldDisplays: Set<String> = []
    /// Plugged in once the session can take input, with the app's first picture.
    private var gamepads: GamepadBridge?

    /// The app's Android screen follows the window, as on a desktop Android or a Mac app: a
    /// bigger window shows more of the app, at the same size, not a bigger picture. For apps
    /// that turn freely and aren't games; games and apps held one way are scaled, as their
    /// screens are drawn for a phone's.
    private let isFlexible: Bool

    init(package: String, label: String, orientation: AppOrientation, landscape: Bool, flexible: Bool = false,
         fromNotification: Bool = false) {
        self.package = package
        self.orientation = orientation
        isFlexible = flexible
        isLandscape = landscape
        resolution = ScrcpySession.Resolution.forThisMac
        let androidScreen = resolution.screen(landscape: landscape)
        let points = Self.smallest(landscape: landscape)
        session = ScrcpySession(package: package, screen: androidScreen)
        session.startsApp = !fromNotification
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
        if flexible {
            veil.frame = screen.bounds
            veil.autoresizingMask = [.width, .height]
            veil.wantsLayer = true
            let icon = NSImageView(image: NSApp.applicationIconImage)
            icon.frame = NSRect(x: (veil.bounds.width - 96) / 2, y: (veil.bounds.height - 96) / 2, width: 96, height: 96)
            icon.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            veil.addSubview(icon)
            veil.isHidden = true
            screen.addSubview(veil)
        }
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
        if flexible {
            // Any shape, and Android's screen starts as the window is, where it was left.
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            window.contentMinSize = Self.smallestFlexible
        }
        window.setFrameAutosaveName("Window")
        if flexible {
            displayView.renderer?.keepPixelSize()
            displayView.renderer?.onContent = { [weak self] in
                guard let self, !self.resizing, self.matchesAndroid else { return }
                self.veil.isHidden = true
            }
            let screen = flexibleScreen()
            session = ScrcpySession(package: package, screen: screen, flexible: true)
            session.startsApp = !fromNotification
            displaySize = NSSize(width: screen.width, height: screen.height)
        }
        AppLog.write("Screen of \(Int(displaySize.width)) by \(Int(displaySize.height)) pixels")
        connect(session)
        shareScreen()
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
            gamepads?.update()
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
                + "Add a stick for W, A, S and D, Mouse Aim to look around with the mouse (click the game to aim, Esc to stop), "
                + "and macros that tap several buttons in turn with one key.\n\n"
                + "Online games such as shooters may not allow playing with a keyboard, a mouse or macros against touch players, "
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
        gamepads?.update()
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
        displayView.releaseAllKeys()
    }
    /// Pictures Android drew in the last second: Android sends one only when the app's screen
    /// changes, so this is the app's own frame rate.
    private let fpsLabel = NSTextField(labelWithString: "")
    private let frameCount = FrameCounter()
    private var fpsTimer: Timer?

    private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    /// In full screen the toolbar hides with the menu bar and comes down with it.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.autoHideToolbar, .autoHideMenuBar, .fullScreen])
    }

    private func connect(_ session: ScrcpySession) {
        displayView.session = session
        phoneInput.update(session: session)
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
                // A flexible screen follows the window, not the window it.
                guard !self.isFlexible else {
                    self.displaySize = NSSize(width: width, height: height)
                    // Android has its new size: the window's latest, if it changed meanwhile, goes next.
                    self.resizing = false
                    self.resizeAndroid()
                    return
                }
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
                self.loadSettings()
                self.launchScreen.removeFromSuperview()
                if self.gamepads == nil {
                    let gamepads = GamepadBridge(session: session, controls: self.displayView.controls)
                    gamepads.onEditPress = { [weak self] code in self?.overlay.padPressed(code) ?? false }
                    self.gamepads = gamepads
                }
                if self.displayView.keyboard == nil { self.displayView.keyboard = KeyboardBridge(session: session) }
                self.startPhoneRemote()
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
        appStarted = Date()
        resizing = false
        gamepads?.stop()
        gamepads = nil
        displayView.keyboard?.stop()
        displayView.keyboard = nil
        session.stop()
        session = isFlexible ? ScrcpySession(package: package, screen: flexibleScreen(), restartsApp: true, flexible: true)
            : ScrcpySession(package: package, screen: resolution.screen(landscape: isLandscape), restartsApp: true)
        if let old = watchedDisplay { oldDisplays.insert(old) }
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
        // Opened by a notification, whose screen Inquiline starts here: if none comes, the
        // app's first screen does.
        if !session.startsApp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.watchedDisplay == nil else { return }
                AppLog.write("The notification's screen didn't open, so the app's first one does")
                self.session.sendStartApp()
            }
        }
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
                    self.watchedDisplay = self.watchedDisplay ?? screens.first {
                        $0.activity.contains(" \(package)/") && !self.oldDisplays.contains($0.display)
                    }?.display
                    guard let display = self.watchedDisplay else { return }
                    // The app's task there, which closing the window removes.
                    if let top = screens.first(where: { $0.display == display && $0.activity.contains(" \(package)/") }),
                       let word = top.activity.split(separator: " ").last(where: { $0.hasPrefix("t") }),
                       let task = Int(word.dropFirst().prefix(while: \.isNumber)) {
                        self.watchedTask = task
                    }
                    // A restart for a new screen shape leaves it empty for a moment.
                    if screens.contains(where: { $0.display == display }) {
                        missing = 0
                        return
                    }
                    missing += 1
                    guard missing == 2 else { return }
                    let since = self.appStarted
                    DispatchQueue.global().async {
                        let restart = AndroidRuntime.shared.wasEndedBySystem(package: package, since: since)
                        DispatchQueue.main.async {
                            if restart {
                                AppLog.write("Android ended the app, so it starts again in its window")
                                missing = 0
                                self.restartApp()
                            } else {
                                AppLog.write("The app's screen is gone, so its window closes")
                                self.window.close()
                            }
                        }
                    }
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
        guard !isFlexible else { return }
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

    /// The smallest a flexible app's window gets: a small phone's screen, which every app lays out for.
    private static let smallestFlexible = NSSize(width: 360, height: 400)

    /// A flexible app's Android screen: the window's pixels, at a density that makes one point of
    /// the window one dp of Android's, as Mac apps lay out in points.
    private func flexibleScreen() -> ScrcpySession.Screen {
        let scale = max(window.backingScaleFactor, NSScreen.main?.backingScaleFactor ?? Self.pixelsPerPoint)
        let size = screen.bounds.size
        // Multiples of 4, as Android's display server takes them, so it shows exactly this size.
        func even(_ value: CGFloat) -> Int { max(4, Int(value * scale / 4) * 4) }
        return ScrcpySession.Screen(width: even(size.width), height: even(size.height), density: Int(160 * scale))
    }

    /// As the window takes a new size, Android's screen does; Android lays the app out again once
    /// the sizes stop changing, and the picture is scaled meanwhile.
    /// One way for every size change: once the window's size isn't Android's, the veil covers
    /// the app; Android gets the new size when it's settled (let go, or at once for full screen),
    /// and the veil goes when the app has drawn for it. An Android app needs 50 to 200 ms to lay
    /// out for a size, so anything shown meanwhile would be stretched or half drawn.
    func windowDidResize(_ notification: Notification) {
        guard isFlexible else { return }
        if !matchesAndroid { showVeil() }
        if !window.inLiveResize { resizeAndroid() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard isFlexible else { return }
        resizeAndroid()
        if !resizing, matchesAndroid { veil.isHidden = true }
    }

    private var matchesAndroid: Bool {
        let screen = flexibleScreen()
        return CGFloat(screen.width) == displaySize.width && CGFloat(screen.height) == displaySize.height
    }

    private func showVeil() {
        guard veil.isHidden else { return }
        veil.layer?.backgroundColor = displayView.renderer?.layer.backgroundColor
        veil.isHidden = false
    }

    /// A size sent to Android that it hasn't shown yet: one at a time, so Android lays out each
    /// size it gets, as fast as it can, and the window's newest size always comes next.
    private var resizing = false

    private func resizeAndroid() {
        guard !resizing else { return }
        let screen = flexibleScreen()
        guard CGFloat(screen.width) != displaySize.width || CGFloat(screen.height) != displaySize.height else { return }
        resizing = true
        session.sendResize(width: screen.width, height: screen.height)
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

    /// In full screen the app's screen takes the whole display and the toolbar comes down over
    /// it with the menu bar, as Safari's does: pushed down for it instead, the picture was drawn
    /// again at each reveal, flickered, and left the toolbar's place black once it went.
    func windowWillEnterFullScreen(_ notification: Notification) {
        window.styleMask.insert(.fullSizeContentView)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window.styleMask.remove(.fullSizeContentView)
    }

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
    private static let settingsItem = NSToolbarItem.Identifier("settings")
    private static let assistantItem = NSToolbarItem.Identifier("assistant")
    private static let phoneItem = NSToolbarItem.Identifier("phone")
    private static let captureItem = NSToolbarItem.Identifier("capture")

    /// The frame rate, sound and orientation, in the Mac's own toolbar.
    private func addToolbar() {
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        fpsLabel.textColor = .secondaryLabelColor
        // As wide as a toolbar button, so it sits as far from the window's edge as one.
        fpsLabel.alignment = .center
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        // A click shows how the app runs: its frame rate over time, and the CPU, GPU and memory.
        fpsLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showMonitor(_:))))
        fpsLabel.toolTip = "Frames per second. Click for more."
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
            let cores = engine.cores()
            let busy = cores >= 3
            self.updateMonitor(fps: fps, cores: cores)
            busyFor = busy ? busyFor + 1 : 0
            idleFor = busy ? 0 : idleFor + 1
            if self.loading {
                if moving >= 2 || idleFor >= 5 { self.showLoading(false) }
            } else if still >= 8 && busyFor >= 8 && self.launchScreen.superview == nil {
                // Before the app's first picture, the launch screen already says it's starting.
                self.showLoading(true)
            }
        }
        let toolbar = NSToolbar(identifier: "AppWindowToolbar7")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The space keeps the buttons clear of the window's rounded corner. Android's Settings
        // is no app to set up or clear.
        package == AppShortcuts.settingsPackage ? [.flexibleSpace, Self.rotateItem, .space]
            : [.flexibleSpace, Self.fpsItem, Self.assistantItem, Self.captureItem, Self.phoneItem, Self.controlsItem, Self.muteItem, Self.rotateItem,
               Self.settingsItem, .space]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Clearing is in App Settings and the app's menu; these are there for those who want
        // them at hand.
        package == AppShortcuts.settingsPackage ? [.flexibleSpace, .space, Self.rotateItem]
            : [.flexibleSpace, .space, Self.fpsItem, Self.assistantItem, Self.captureItem, Self.phoneItem, Self.controlsItem, Self.muteItem, Self.rotateItem,
               Self.settingsItem, Self.clearCacheItem, Self.clearDataItem]
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
            menu.delegate = self
            Self.addControlsItems(to: menu, target: self)
            item.menu = menu
            return item
        }
        if identifier == Self.captureItem {
            // A click opens its menu: a screenshot, or recording.
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Screenshot"
            item.showsIndicator = false
            let menu = NSMenu()
            menu.delegate = self
            menu.addItem(withTitle: "Take Screenshot", action: #selector(takeScreenshot(_:)), keyEquivalent: "").target = self
            let record = menu.addItem(withTitle: "Record Screen", action: #selector(toggleRecording(_:)), keyEquivalent: "")
            record.target = self
            recordMenuItem = record
            item.menu = menu
            captureToolbarItem = item
            updateCaptureItem()
            return item
        }
        if identifier == Self.phoneItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Phone Remote"
            item.toolTip = "Use Your Phone as a Remote"
            // A button of its own, so its QR code can point at it.
            let button = NSButton(image: NSImage(systemSymbolName: "iphone", accessibilityDescription: "Phone Remote")!,
                                  target: self, action: #selector(showPhoneRemote(_:)))
            button.bezelStyle = .toolbar
            item.view = button
            return item
        }
        if identifier == Self.settingsItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "App Settings"
            item.toolTip = "App Settings"
            // A button of its own, so the settings can point at it.
            let button = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "App Settings")!,
                                  target: self, action: #selector(showSettings(_:)))
            button.bezelStyle = .toolbar
            settingsButton = button
            item.view = button
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.fpsItem:
            item.label = "FPS"
            item.view = fpsLabel
        case Self.muteItem:
            item.label = "Sound"
            // A button of its own, so the sound popover can point at it.
            let button = NSButton(image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Sound")!,
                                  target: self, action: #selector(showSound(_:)))
            button.bezelStyle = .toolbar
            item.view = button
            item.toolTip = "Sound"
        case Self.assistantItem:
            // Android's assistant (Gemini) over the app, as holding a phone's power button opens it.
            item.label = "Assistant"
            item.toolTip = "Ask Assistant"
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Ask Assistant")
            item.target = self
            item.action = #selector(askAssistant)
            item.isBordered = true
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

    /// Android's assistant (Gemini) over this app, reading what it shows.
    @objc func askAssistant() {
        guard let task = watchedTask else { return }
        DispatchQueue.global().async { [weak self] in
            let runtime = AndroidRuntime.shared
            let missing = runtime.missingAssistantApps()
            if missing?.isEmpty == true { return runtime.showAssistant(task: task) }
            DispatchQueue.main.async { self?.sayAssistantNeedsApps(missing: missing) }
        }
    }

    /// Gemini needs apps a phone comes with, which the user installs from Google Play.
    private func sayAssistantNeedsApps(missing: [(package: String, name: String)]?) {
        let alert = NSAlert()
        alert.messageText = "Gemini needs the Google and Gemini apps"
        alert.informativeText = missing == nil
            ? "Choose Install Google Play… from Inquiline in the menu bar, then install the Google and Gemini apps from Google Play."
            : "Install the Google and Gemini apps from Google Play, then click the Assistant button again."
        alert.beginSheetModal(for: window)
    }

    // MARK: - Performance

    private var fpsHistory: [Int] = []
    private weak var monitor: PerformanceMonitor?
    private var androidMemory: (used: Double, total: Double)?
    private var askingMemory = false

    /// The frame rate's click: the settings, with their Performance section open.
    @objc private func showMonitor(_ sender: Any?) {
        UserDefaults.standard.set(true, forKey: AppSettingsView.monitorKey)
        if let settings = settingsView, settings.window?.isVisible == true {
            settings.openMonitor()
            settings.window?.makeKeyAndOrderFront(nil)
        } else if let button = settingsButton {
            showSettings(button)
        }
    }

    /// Each second; the monitor shows it while it's open. Android's memory is asked of it then
    /// only, every other second, off the main queue.
    private func updateMonitor(fps: Int?, cores: Double) {
        if let fps {
            fpsHistory.append(fps)
            if fpsHistory.count > 30 { fpsHistory.removeFirst(fpsHistory.count - 30) }
        }
        guard let monitor, monitor.isShown else { return }
        if !askingMemory, fps == nil || fpsHistory.count % 2 == 0 {
            askingMemory = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let memory = PerformanceMonitor.androidMemory()
                DispatchQueue.main.async {
                    self?.androidMemory = memory
                    self?.askingMemory = false
                }
            }
        }
        monitor.update(history: fpsHistory, cores: fps == nil ? lastCores : cores,
                       gpu: PerformanceMonitor.gpuUtilization(), memory: androidMemory)
        if fps != nil { lastCores = cores }
    }

    private var lastCores = 0.0

    // MARK: - Screenshots and recordings

    private var recorder: ScreenRecorder?
    private var recordingTimer: Timer?
    private weak var captureToolbarItem: NSMenuToolbarItem?
    private weak var recordMenuItem: NSMenuItem?

    /// The app's screen alone, as Android drew it, where the Mac saves its screenshots, with
    /// the Mac's sound and a flash.
    @objc private func takeScreenshot(_ sender: Any?) {
        guard let picture = displayView.renderer?.picture() else { return NSSound.beep() }
        let url = ScreenCapture.file(app: window.title, kind: "png")
        ScreenCapture.playShutter()
        flash()
        DispatchQueue.global(qos: .userInitiated).async {
            if !ScreenCapture.save(picture, to: url) { AppLog.write("A screenshot couldn't be saved") }
        }
    }

    private func flash() {
        guard let content = window.contentView else { return }
        let veil = NSView(frame: displayView.frame)
        veil.wantsLayer = true
        veil.layer?.backgroundColor = .white
        veil.alphaValue = 0.8
        content.addSubview(veil, positioned: .above, relativeTo: displayView)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            veil.animator().alphaValue = 0
        }, completionHandler: { veil.removeFromSuperview() })
    }

    /// Starts recording the app's screen and Android's sound, or stops and saves it.
    @objc private func toggleRecording(_ sender: Any?) {
        if recorder != nil { return stopRecording() }
        guard let renderer = displayView.renderer, renderer.pictureSize.width > 0,
              let made = ScreenRecorder(url: ScreenCapture.file(app: window.title, kind: "mov"),
                                        size: renderer.pictureSize, device: renderer.device)
        else { return NSSound.beep() }
        recorder = made
        renderer.record(to: made)
        let started = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let seconds = Int(Date().timeIntervalSince(started))
            self?.captureToolbarItem?.toolTip = String(format: "Recording %d:%02d", seconds / 60, seconds % 60)
        }
        updateCaptureItem()
        AppLog.write("Recording the app's screen")
    }

    private func stopRecording(now: Bool = false) {
        guard let recorder else { return }
        self.recorder = nil
        displayView.renderer?.record(to: nil)
        recordingTimer?.invalidate()
        recordingTimer = nil
        updateCaptureItem()
        if now {
            recorder.finishNow()
        } else {
            recorder.finish { saved in AppLog.write(saved ? "A screen recording was saved" : "A screen recording was empty") }
        }
    }

    /// A camera; while recording, a red button that stops it.
    private func updateCaptureItem() {
        guard let item = captureToolbarItem else { return }
        if recorder != nil {
            let red = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            item.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")?
                .withSymbolConfiguration(red)
            item.toolTip = "Recording"
            recordMenuItem?.title = "Stop Recording"
        } else {
            item.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Screenshot")
            item.toolTip = "Screenshot or Recording"
            recordMenuItem?.title = "Record Screen"
        }
    }

    // MARK: - Phone remote

    private var phoneRemote: PhoneRemote?
    private let phoneInput = PhoneInput()
    private weak var phoneStatus: NSTextField?

    /// A QR code for the phone's camera, to pair it with Inquiline once; the page it opens works
    /// whichever app window is in front.
    @objc private func showPhoneRemote(_ sender: Any?) {
        startPhoneRemote()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = phoneRemoteView(url: PhoneRemote.pairingAddress())
        let anchor = (sender as? NSView) ?? window.contentView!
        present(popover, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Ready for a paired phone as soon as the app shows, as the phone follows the window in front.
    private func startPhoneRemote() {
        guard phoneRemote == nil, package != AppShortcuts.settingsPackage else { return }
        makePhoneRemote().start()
    }

    private func makePhoneRemote() -> PhoneRemote {
        let remote = PhoneRemote(title: window.title)
        let input = phoneInput
        input.update(session: session, size: displaySize, task: watchedTask)
        input.onAssistant = { [weak self] in self?.askAssistant() }
        input.onTouch = { [weak self] action, x, y, finger in
            self?.displayView.showPhoneFinger(action, x: x, y: y, finger: finger)
        }
        remote.onInput = { input.handle($0) }
        remote.onPhones = { [weak self] count in
            guard let self else { return }
            self.phoneStatus?.stringValue = Self.phoneStatusText(count)
            AppLog.write(count > 0 ? "A phone is connected as a remote" : "No phone is connected as a remote")
            if count == 0 { self.phoneInput.unplug() }
        }
        phoneRemote = remote
        return remote
    }

    private static func phoneStatusText(_ phones: Int) -> String {
        phones > 0 ? "Connected" : "Waiting for your phone"
    }

    private func phoneRemoteView(url: URL?) -> NSViewController {
        let title = NSTextField(labelWithString: "Use Your Phone as a Remote")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let views: [NSView]
        if let url, let code = PhoneRemote.code(for: url, size: 200) {
            let image = NSImageView(image: code)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 200).isActive = true
            image.heightAnchor.constraint(equalToConstant: 200).isActive = true
            let note = NSTextField(wrappingLabelWithString:
                "Scan this once with your phone's camera for a controller, a touchpad and Gemini. "
                + "Then add the page to your Home Screen: it works whichever app is in front. "
                + "Your phone must be on the same Wi-Fi as your Mac.")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            let status = NSTextField(labelWithString: Self.phoneStatusText(0))
            status.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            phoneStatus = status
            views = [title, image, note, status]
        } else {
            let note = NSTextField(wrappingLabelWithString: "Connect your Mac to Wi-Fi or a network, then try again. "
                + "If it is, quit Inquiline from the menu bar and open it again.")
            note.textColor = .secondaryLabelColor
            views = [title, note]
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.widthAnchor.constraint(equalToConstant: 260).isActive = true
        views.compactMap { $0 as? NSTextField }.forEach {
            $0.alignment = .center
            $0.preferredMaxLayoutWidth = 228
        }
        let controller = NSViewController()
        controller.view = stack
        return controller
    }

    /// The app's sound: Android's music volume, which all its apps share as on a phone, its
    /// effects, and this app's own mute, so a game can be quiet while music plays.
    @objc private func showSound(_ sender: Any?) {
        let popover = NSPopover()
        popover.behavior = .transient
        let mutedKey = mutedKey, package = package
        let view = SoundView(muted: UserDefaults.standard.bool(forKey: mutedKey))
        view.muteChanged = { muted in
            UserDefaults.standard.set(muted, forKey: mutedKey)
            DispatchQueue.global().async { AndroidRuntime.shared.setMuted(muted, package: package) }
        }
        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        // The bands show and hide with Custom: the popover takes the new size.
        view.onResize = { [weak popover] size in popover?.contentSize = size }
        guard let anchor = sender as? NSView else { return }
        present(popover, relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }

    /// The app's own settings, as Android's Settings > Apps shows them for one app, in a small
    /// popover so the toolbar stays short. More go here as they come.
    @objc private func showSettings(_ sender: NSButton) {
        if let open = settingsPopover, open.isShown { return open.close() }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        settingsPopover = popover
        popover.delegate = self
        // A new size at once: animated, the content slides inside the growing popover.
        popover.contentViewController = settingsController { [weak popover] size in
            guard let popover else { return }
            let animates = popover.animates
            popover.animates = false
            popover.contentSize = size
            popover.animates = animates
        }
        // Below the button: in a flipped view, as a button is, its bottom is maxY.
        present(popover, relativeTo: sender.bounds, of: sender, preferredEdge: sender.isFlipped ? .maxY : .minY)
    }

    /// The settings stay open while the app is used, until their button is clicked again.
    private var settingsPopover: NSPopover?

    /// One popover at a time in the toolbar: opening one closes the one open.
    fileprivate var shownPopover: NSPopover?

    private func present(_ popover: NSPopover, relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge) {
        if let shown = shownPopover, shown !== popover, shown.isShown { shown.close() }
        shownPopover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    /// What the app's settings show, read from Android when the window opens and again as the
    /// settings close, so they open at once with all of it.
    private var settingsSnapshot: AppSettingsView.Snapshot?

    private func loadSettings() {
        SoundView.prefetch()
        let package = package
        DispatchQueue.global().async { [weak self] in
            let snapshot = AppSettingsView.Snapshot.load(package: package)
            DispatchQueue.main.async { self?.settingsSnapshot = snapshot }
        }
    }

    /// The app's settings, sized to what is open in them as sections open and close.
    private func settingsController(resize: @escaping (NSSize) -> Void) -> NSViewController {
        let monitor = PerformanceMonitor()
        let settings = AppSettingsView(package: package, label: window.title, snapshot: settingsSnapshot, monitor: monitor)
        self.monitor = monitor
        settingsView = settings
        settings.monitorOpened = { [weak self] in self?.updateMonitor(fps: nil, cores: 0) }
        settings.loaded = { [weak self] in self?.settingsSnapshot = $0 }
        settings.clearCache = { [weak self] in self?.settingsPanel?.close(); self?.clearCache() }
        settings.clearData = { [weak self] in self?.settingsPanel?.close(); self?.clearData() }
        settings.onResize = resize
        let controller = NSViewController()
        controller.view = settings
        return controller
    }

    private weak var settingsView: AppSettingsView?
    private weak var settingsButton: NSButton?

    /// Dragged away from its button, as a Mac's own popovers can be, the settings stay as a small
    /// window of their own, in front of the app.
    private var settingsPanel: NSPanel?

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = window.title
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = settingsController { [weak panel] size in panel?.setContentSize(size) }
        settingsPanel?.close()
        settingsPanel = panel
        return panel
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
        // A flexible app's screen is the window's: turning it turns the window.
        if isFlexible {
            guard !isFullScreen else { return }
            let size = screen.bounds.size
            window.setContentSize(NSSize(width: max(size.height, Self.smallestFlexible.width),
                                         height: max(size.width, Self.smallestFlexible.height)))
            return
        }
        userTurned = true
        session.sendRotate()
    }

    // MARK: - Android's main screen

    private var activeObserver: NSObjectProtocol?

    /// Android's main screen takes the size and density of the app in front, as a phone's one
    /// screen is the app's own: code that asks Android for "the" screen, as ad libraries that
    /// lay out with the app's context rather than its window do, then gets this app's, and an
    /// ad fills the window instead of a corner of it. Only the main screen changes; no app is
    /// on it, so none starts again.
    private func shareScreen() {
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                self?.shareScreen()
            }
        }
        guard NSApp.isActive, displaySize.width > 0 else { return }
        let size = "\(Int(displaySize.width))x\(Int(displaySize.height))", density = session.screen.density
        DispatchQueue.global().async {
            _ = try? AdbClient.shell("wm size -d 0 | grep -q 'Override size: \(size)$' || wm size \(size) -d 0; "
                                     + "wm density -d 0 | grep -q 'Override density: \(density)$' || wm density \(density) -d 0",
                                     timeout: 5)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window is quitting the app, as swiping it away from a phone's recent apps:
        // its task is removed, so Android tells the app, which stops what it was doing (a video
        // playing on, say). Only removing its screen would leave its services running.
        if let task = watchedTask {
            _ = try? AdbClient.shell("am stack remove \(task)", timeout: 3)
        }
        displayView.controls.releaseAll()
        stopRecording(now: true)
        phoneRemote?.stop()
        phoneInput.unplug()
        watch?.invalidate()
        fpsTimer?.invalidate()
        gamepads?.stop()
        displayView.keyboard?.stop()
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

/// A toolbar menu opening closes the popover open, as opening another popover does.
extension AppWindowController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let shown = shownPopover, shown.isShown { shown.close() }
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

/// What App Settings shows: whether the app may send notifications, which reach the Mac's
/// Notification Center, and clearing its cache or data.
private final class AppSettingsView: NSView {
    var clearCache: (() -> Void)?
    var clearData: (() -> Void)?
    /// Called with the size the settings now need, as sections open and close.
    var onResize: ((NSSize) -> Void)? {
        // Its holder hears the size even if the snapshot already laid the settings out.
        didSet { fittedSize = nil; fitToContent() }
    }

    /// Tells the popover or window holding the settings their size, when it changes: resizing
    /// as the popover opens, with what loaded hidden in a closed section, made it flicker.
    func fitToContent() {
        layoutSubtreeIfNeeded()
        let size = fittingSize
        guard size != fittedSize else { return }
        fittedSize = size
        onResize?(size)
    }

    private var fittedSize: NSSize?
    private let package: String
    private let label: String
    private let notifications = NSSwitch()
    private let permissionRows = NSStackView()
    private let adRows = NSStackView()
    private let dataRows = NSStackView()
    private let widgetRows = NSStackView()
    private var widgetsHeader: NSView?
    private let appSize = NSTextField(labelWithString: "")
    private let dataSize = NSTextField(labelWithString: "")
    private let cacheSize = NSTextField(labelWithString: "")
    private var groups: [AndroidRuntime.PermissionGroup] = []
    private let level = NSSlider(value: 0, minValue: 0, maxValue: 3, target: nil, action: nil)
    private let levelText = NSTextField(wrappingLabelWithString: "")
    private let countRows = NSStackView()
    private let resetCounts = NSButton(title: "Reset Counts", target: nil, action: nil)
    private var countTimer: Timer?

    /// The names the counts show by, for the helper's categories.
    private static let countNames = [
        ("ads", "Ads"), ("privacy", "Trackers"), ("malware", "Malicious Sites"),
        ("cookies", "Cookie Notices"), ("social", "Social Widgets"), ("annoyances", "Annoyances"),
    ]

    /// How much the ad blocker takes away, as Firefox's tracking protection has levels: the
    /// helper's categories each level turns on, its name and what it blocks.
    private static let levels: [(categories: Set<String>, name: String, blocks: String)] = [
        ([], "Off", "Nothing is blocked."),
        (["ads"], "Light", "Ads."),
        (["ads", "privacy", "malware"], "Balanced", "Ads, trackers and malicious sites, as uBlock Origin by default."),
        (["ads", "privacy", "malware", "cookies", "social", "annoyances"], "Strong",
         "Also cookie notices, social media buttons and annoyances such as newsletter pop-ups."),
    ]

    /// All the settings show, as Android has it.
    struct Snapshot {
        var allowed: Bool?
        var blocking: Set<String>?
        var groups: [AndroidRuntime.PermissionGroup]
        var storage: (app: Int64, data: Int64, cache: Int64)?
        var widgets: [[String: Any]]
        var counts: [String: Int]

        /// Asked of Android all at once, so none waits for another: the storage takes a second.
        static func load(package: String) -> Snapshot {
            var snapshot = Snapshot(allowed: nil, blocking: nil, groups: [], storage: nil, widgets: [], counts: [:])
            let lock = NSLock()
            func set(_ change: (inout Snapshot) -> Void) { lock.lock(); change(&snapshot); lock.unlock() }
            DispatchQueue.concurrentPerform(iterations: 6) { part in
                let runtime = AndroidRuntime.shared
                switch part {
                case 0: let value = runtime.notificationsAllowed(package: package); set { $0.allowed = value }
                case 1: let value = runtime.adBlocking(package: package); set { $0.blocking = value }
                case 2: let value = runtime.permissions(package: package) ?? []; set { $0.groups = value }
                case 3: let value = runtime.storage(package: package); set { $0.storage = value }
                case 4:
                    let value = runtime.widgetList(package: package)
                    if let value { saveWidgets(value, package: package) }
                    set { $0.widgets = value ?? cachedWidgets(package: package) }
                default: let value = runtime.adCounts(package: package); set { $0.counts = value }
                }
            }
            return snapshot
        }

        /// What the app's widgets were when last read, which changes only with the app: shown
        /// at once even before Android answers.
        static func cached(package: String) -> Snapshot {
            Snapshot(allowed: nil, blocking: nil, groups: [], storage: nil, widgets: cachedWidgets(package: package), counts: [:])
        }

        private static func widgetsFile(_ package: String) -> URL {
            AndroidRuntime.shared.home.appendingPathComponent("widget-lists/\(package).json")
        }

        private static func cachedWidgets(package: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: widgetsFile(package)),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return list
        }

        private static func saveWidgets(_ list: [[String: Any]], package: String) {
            let file = widgetsFile(package)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: list) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// A fresh snapshot, for the next time the settings open.
    var loaded: ((Snapshot) -> Void)?

    /// Whether the Performance section is open, as last left.
    static let monitorKey = "AppSettingsMonitorOpen"
    private let monitor: PerformanceMonitor
    private let monitorRows = NSStackView()
    private let monitorTriangle: NSButton
    /// Called as the Performance section opens, for it to show at once.
    var monitorOpened: (() -> Void)?

    init(package: String, label: String, snapshot: Snapshot?, monitor: PerformanceMonitor) {
        self.package = package
        self.label = label
        self.monitor = monitor
        monitorTriangle = NSButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)
        // Until Android answers, nothing to switch.
        notifications.target = self
        notifications.action = #selector(notificationsChanged)
        notifications.isEnabled = false

        // Permissions, notifications first: the one most often changed.
        for rows in [monitorRows, permissionRows, adRows, dataRows, widgetRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 10
            rows.isHidden = true
            rows.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        }
        permissionRows.addArrangedSubview(Self.row("Notifications", notifications))
        // How much is blocked in this app.
        level.numberOfTickMarks = Self.levels.count
        level.allowsTickMarkValuesOnly = true
        // Android hears the level once it's let go, not at every step of a drag.
        level.isContinuous = false
        level.target = self
        level.action = #selector(levelChanged)
        level.isEnabled = false
        let names = NSStackView(views: Self.levels.map { level in
            let label = NSTextField(labelWithString: level.name)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            return label
        })
        names.orientation = .horizontal
        names.distribution = .equalSpacing
        levelText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // Wrapped at the settings' width, so its height is known before it shows.
        levelText.preferredMaxLayoutWidth = 220
        levelText.textColor = .secondaryLabelColor
        for view in [level, names, levelText] as [NSView] { adRows.addArrangedSubview(view) }
        // What has been blocked here, by kind, until reset: only kinds with any.
        countRows.orientation = .vertical
        countRows.alignment = .leading
        countRows.spacing = 6
        countRows.isHidden = true
        resetCounts.target = self
        resetCounts.action = #selector(resetClicked)
        resetCounts.controlSize = .small
        resetCounts.isHidden = true
        adRows.addArrangedSubview(countRows)
        adRows.addArrangedSubview(resetCounts)
        // How the app runs, first, as the frame rate's click opens it.
        monitorRows.addArrangedSubview(monitor.view)
        let monitorHeader = Self.header("Performance", rows: monitorRows, trailing: nil, triangle: monitorTriangle) { [weak self] open in
            UserDefaults.standard.set(open, forKey: Self.monitorKey)
            if open { self?.monitorOpened?() }
        }
        if UserDefaults.standard.bool(forKey: Self.monitorKey) {
            monitorTriangle.state = .on
            monitorRows.isHidden = false
        }
        let permissionsHeader = Self.header("Permissions", rows: permissionRows, trailing: nil)
        let adsHeader = Self.header("Ad Blocking", rows: adRows, trailing: nil)

        // The app's files and what it keeps, as Android's Settings > Apps > Storage has them.
        let folder = NSButton(title: "Show in Finder", target: self, action: #selector(showFolderClicked))
        let cache = NSButton(title: "Clear Cache", target: self, action: #selector(clearCacheClicked))
        let data = NSButton(title: "Clear Data…", target: self, action: #selector(clearDataClicked))
        // Red, as the Mac shows what can't be undone; it asks first. Clearing the cache loses
        // nothing the app can't fetch again, so it neither asks nor warns, as on Android.
        data.hasDestructiveAction = true
        data.attributedTitle = NSAttributedString(string: data.title, attributes: [
            .foregroundColor: NSColor.systemRed, .font: data.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        let clearing = NSStackView(views: [cache, data])
        clearing.orientation = .horizontal
        clearing.distribution = .fillEqually
        // What it takes, as Android's Settings shows it, once Android answers.
        for (name, value) in [("App", appSize), ("Data", dataSize), ("Cache", cacheSize)] {
            value.stringValue = "…"
            value.textColor = .secondaryLabelColor
            dataRows.addArrangedSubview(Self.row(name, value))
        }
        dataRows.addArrangedSubview(folder)
        dataRows.addArrangedSubview(clearing)
        let dataHeader = Self.header("Data", rows: dataRows, trailing: nil)
        // The app's widgets, for the desktop, once Android lists them; none, no section.
        let widgetsHeader = Self.header("Widgets", rows: widgetRows, trailing: nil)
        widgetsHeader.isHidden = true
        self.widgetsHeader = widgetsHeader
        let stack = NSStackView(views: [monitorHeader, monitorRows, permissionsHeader, permissionRows, adsHeader, adRows, widgetsHeader, widgetRows,
                                        dataHeader, dataRows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 270),
        ]
        for view in [monitorHeader, monitorRows, permissionsHeader, permissionRows, adsHeader, adRows, widgetsHeader, widgetRows,
                     dataHeader, dataRows] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32))
        }
        for view in [level, names, levelText, countRows] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalTo: adRows.widthAnchor, constant: -18))
        }
        constraints.append(monitor.view.widthAnchor.constraint(equalTo: monitorRows.widthAnchor, constant: -18))
        constraints.append(folder.widthAnchor.constraint(equalTo: clearing.widthAnchor))
        constraints.append(clearing.widthAnchor.constraint(equalTo: dataRows.widthAnchor, constant: -18))
        NSLayoutConstraint.activate(constraints)

        // What the window read when it opened, at once; then Android's answer now, which
        // changes only what changed meanwhile.
        apply(snapshot ?? .cached(package: package))
        DispatchQueue.global().async { [weak self] in
            let fresh = Snapshot.load(package: package)
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(fresh)
                self.loaded?(fresh)
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        showWidgets(snapshot.widgets)
        if let allowed = snapshot.allowed {
            notifications.state = allowed ? .on : .off
            notifications.isEnabled = true
        }
        if let blocking = snapshot.blocking { showCategories(blocking) }
        if let storage = snapshot.storage {
            let format = ByteCountFormatter()
            format.countStyle = .file
            appSize.stringValue = format.string(fromByteCount: storage.app)
            dataSize.stringValue = format.string(fromByteCount: storage.data)
            cacheSize.stringValue = format.string(fromByteCount: storage.cache)
        }
        show(snapshot.groups)
        showCounts(snapshot.counts)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A name on the left, its switch on the right.
    private static func row(_ name: String, _ control: NSView) -> NSStackView {
        let row = NSStackView(views: [NSTextField(labelWithString: name), NSView(), control])
        row.orientation = .horizontal
        return row
    }

    /// Opens the Performance section, for the frame rate's click.
    func openMonitor() {
        guard monitorTriangle.state == .off else { return }
        (objc_getAssociatedObject(monitorTriangle, "toggle") as? SectionToggle)?.labelClicked()
    }

    /// A section's title with the triangle that shows or hides its rows, as in a Mac's own lists.
    private static func header(_ title: String, rows: NSStackView, trailing: NSView?,
                               triangle: NSButton = NSButton(title: "", target: nil, action: nil),
                               changed: ((Bool) -> Void)? = nil) -> NSStackView {
        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.pushOnPushOff)
        triangle.state = .off
        let toggle = SectionToggle(rows: rows, triangle: triangle)
        toggle.changed = { [weak rows, weak triangle] in
            (rows?.superview?.superview as? AppSettingsView)?.fitToContent()
            changed?(triangle?.state == .on)
        }
        triangle.target = toggle
        triangle.action = #selector(SectionToggle.toggle)
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let click = NSClickGestureRecognizer(target: toggle, action: #selector(SectionToggle.labelClicked))
        label.addGestureRecognizer(click)
        objc_setAssociatedObject(triangle, "toggle", toggle, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [triangle, label, NSView()] + (trailing.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    /// The app's widgets, two to a row, each its picture and name, ticked when on the desktop:
    /// a click adds it there, another click takes it away.
    private var shownWidgets: [String]?

    private func showWidgets(_ widgets: [[String: Any]]) {
        let placed = DesktopWidgets.placed(package: package)
        let providers = widgets.compactMap { $0["provider"] as? String }
        guard providers + placed.keys.sorted() != shownWidgets else { return }
        shownWidgets = providers + placed.keys.sorted()
        widgetRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        widgetsHeader?.isHidden = widgets.isEmpty
        guard !widgets.isEmpty else { return fitToContent() }
        var row: NSStackView?
        for widget in widgets {
            guard let provider = widget["provider"] as? String else { continue }
            let preview = (widget["preview"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            let tile = WidgetTile(provider: provider, label: widget["label"] as? String ?? "", preview: preview,
                                  key: placed[provider], package: package)
            if row == nil || row!.arrangedSubviews.count == 2 {
                let next = NSStackView()
                next.orientation = .horizontal
                next.alignment = .top
                next.spacing = 8
                widgetRows.addArrangedSubview(next)
                row = next
            }
            row?.addArrangedSubview(tile)
        }
        fitToContent()
    }

    private func show(_ groups: [AndroidRuntime.PermissionGroup]) {
        let same = groups.map { "\($0.name)\($0.allowed)" } == self.groups.map { "\($0.name)\($0.allowed)" }
        guard !same || permissionRows.arrangedSubviews.count == 1 else { return }
        self.groups = groups
        // The notifications row stays; the groups are made again.
        permissionRows.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        for (index, group) in groups.enumerated() {
            let toggle = NSSwitch()
            toggle.tag = index
            toggle.state = group.allowed ? .on : .off
            toggle.target = self
            toggle.action = #selector(permissionChanged(_:))
            permissionRows.addArrangedSubview(Self.row(group.name, toggle))
        }
        fitToContent()
    }

    /// The counts, while the settings show: each newly blocked one appears as it's blocked.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        countTimer?.invalidate()
        countTimer = nil
        guard window != nil else {
            // Closed: read again for next time, as what was changed here is now Android's.
            let package = package, loaded = loaded
            DispatchQueue.global().async {
                let fresh = Snapshot.load(package: package)
                DispatchQueue.main.async { loaded?(fresh) }
            }
            return
        }
        refreshCounts()
        countTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshCounts() }
    }

    private var refreshing = false

    private func refreshCounts() {
        guard !refreshing else { return }
        refreshing = true
        let package = package
        DispatchQueue.global().async { [weak self] in
            let counts = AndroidRuntime.shared.adCounts(package: package)
            DispatchQueue.main.async { self?.showCounts(counts) }
        }
    }

    private var shownCounts: [String: Int]?

    private func showCounts(_ counts: [String: Int]) {
        refreshing = false
        guard counts != shownCounts else { return }
        shownCounts = counts
        countRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let format = NumberFormatter()
        format.numberStyle = .decimal
        for (id, name) in Self.countNames {
            guard let count = counts[id], count > 0 else { continue }
            let value = NSTextField(labelWithString: format.string(from: NSNumber(value: count)) ?? "\(count)")
            value.textColor = .secondaryLabelColor
            let row = Self.row(name + " blocked", value)
            countRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: countRows.widthAnchor).isActive = true
        }
        countRows.isHidden = countRows.arrangedSubviews.isEmpty
        resetCounts.isHidden = countRows.isHidden
        fitToContent()
    }

    @objc private func resetClicked() {
        let package = package
        showCounts([:])
        DispatchQueue.global().async { AndroidRuntime.shared.resetAdCounts(package: package) }
    }

    /// The level nearest what is on: the most it covers without turning on more.
    private func showCategories(_ on: Set<String>) {
        let index = Self.levels.lastIndex { $0.categories.isSubset(of: on) } ?? 0
        level.integerValue = index
        level.isEnabled = true
        levelText.stringValue = Self.levels[index].blocks
        fitToContent()
    }

    @objc private func permissionChanged(_ sender: NSSwitch) {
        guard groups.indices.contains(sender.tag) else { return }
        let group = groups[sender.tag], allowed = sender.state == .on, package = package
        DispatchQueue.global().async { AndroidRuntime.shared.setPermissions(group, allowed: allowed, package: package) }
    }

    @objc private func notificationsChanged() {
        let allowed = notifications.state == .on
        let package = package
        DispatchQueue.global().async { AndroidRuntime.shared.setNotificationsAllowed(allowed, package: package) }
    }

    @objc private func levelChanged() {
        let chosen = Self.levels[level.integerValue], package = package
        levelText.stringValue = chosen.blocks
        // The description takes one line or three: the settings fit it.
        fitToContent()
        DispatchQueue.global().async { AndroidRuntime.shared.setAdCategories(chosen.categories, package: package) }
    }

    /// Inquiline opens it, as it mounts Android's disk: an app's own process would need the
    /// user's leave to reach the local network.
    @objc private func showFolderClicked() {
        var address = URLComponents()
        address.scheme = "inquiline"
        address.host = "files"
        address.queryItems = [URLQueryItem(name: "label", value: label)]
        if let url = address.url { NSWorkspace.shared.open(url) }
    }
    @objc private func clearCacheClicked() { clearCache?() }
    @objc private func clearDataClicked() { clearData?() }
}

/// Shows or hides a section's rows from its triangle or its title.
private final class SectionToggle: NSObject {
    let rows: NSStackView
    let triangle: NSButton

    init(rows: NSStackView, triangle: NSButton) {
        self.rows = rows
        self.triangle = triangle
    }

    var changed: (() -> Void)?

    @objc func toggle() {
        rows.isHidden = triangle.state == .off
        changed?()
    }

    @objc func labelClicked() {
        triangle.state = triangle.state == .on ? .off : .on
        toggle()
    }
}

/// One of the app's widgets in its settings, as a phone's widget picker shows it: its picture,
/// whatever its shape, fitted in a tile of the same size as the others, its name below. On the
/// desktop, the tile has the accent's ring and a tick, as a chosen item on the Mac.
private final class WidgetTile: NSView {
    private let provider: String
    private let package: String
    private var key: String?
    private let well = NSView()
    private let tick = NSImageView()

    init(provider: String, label: String, preview: NSImage?, key: String?, package: String) {
        self.provider = provider
        self.package = package
        self.key = key
        super.init(frame: .zero)
        well.wantsLayer = true
        well.layer?.cornerRadius = 10
        well.layer?.cornerCurve = .continuous
        let picture = NSImageView()
        picture.image = preview ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil)
        picture.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = label
        tick.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "On the Desktop")
        tick.contentTintColor = .controlAccentColor
        tick.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        for view in [well, name] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [picture, tick] {
            view.translatesAutoresizingMaskIntoConstraints = false
            well.addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 106),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.heightAnchor.constraint(equalToConstant: 72),
            picture.topAnchor.constraint(equalTo: well.topAnchor, constant: 10),
            picture.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -10),
            picture.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 10),
            picture.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -10),
            tick.topAnchor.constraint(equalTo: well.topAnchor, constant: 5),
            tick.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -5),
            name.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 5),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showState()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showState() {
        let on = key != nil
        tick.isHidden = !on
        // A faint fill, as the Mac's own pickers have: lighter on dark, darker on light.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        well.layer?.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.07 : 0.05).cgColor
        well.layer?.borderWidth = on ? 2 : 0
        well.layer?.borderColor = NSColor.controlAccentColor.cgColor
        toolTip = on ? "Remove from the Desktop" : "Add to the Desktop"
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { showState() }
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        var components = URLComponents()
        components.scheme = "inquiline"
        components.host = "widget"
        if key != nil {
            // Added since the settings opened, Inquiline knows it by the key it gave it.
            guard let placed = DesktopWidgets.placed(package: package)[provider] else { return }
            components.queryItems = [URLQueryItem(name: "remove", value: placed)]
            self.key = nil
        } else {
            components.queryItems = [URLQueryItem(name: "add", value: provider), URLQueryItem(name: "package", value: package)]
            // Inquiline gives it its key; until the settings open again, any marks it as there.
            self.key = ""
        }
        showState()
        guard let url = components.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    override func mouseDown(with event: NSEvent) {}
}

/// The sound popover: a volume slider, as a Mac's sound menu has; the app's own mute; and
/// Android's equalizer and loudness, as a phone's sound settings have them.
private final class SoundView: NSView {
    /// What was last read or set, so the popover opens as it is at once.
    private static var lastLevel: Int?
    private static var lastEqualizer: String?
    private static var lastLoudness: Int?

    /// Read when the window opens, as the app's settings are.
    static func prefetch() {
        DispatchQueue.global().async {
            let level = AndroidRuntime.shared.mediaVolume(), equalizer = AndroidRuntime.shared.equalizer()
            let loudness = AndroidRuntime.shared.loudness()
            DispatchQueue.main.async {
                if let level { lastLevel = level }
                lastEqualizer = equalizer
                lastLoudness = loudness
            }
        }
    }

    private let slider = NSSlider(value: Double(SoundView.lastLevel ?? AndroidRuntime.mediaVolumeSteps), minValue: 0,
                                  maxValue: Double(AndroidRuntime.mediaVolumeSteps), target: nil, action: nil)
    private let presets = NSPopUpButton()
    private let bandRow = NSStackView()
    private var bandSliders: [NSSlider] = []
    /// How much louder Android plays, for apps and videos that play quiet.
    private let loudness = NSSlider(value: Double(SoundView.lastLoudness ?? 0), minValue: 0, maxValue: 100, target: nil, action: nil)
    private static let customTag = 1000, offTag = -1
    var onResize: ((NSSize) -> Void)?
    var muteChanged: ((Bool) -> Void)?
    private let mute = NSSwitch()

    init(muted: Bool) {
        super.init(frame: .zero)
        slider.isEnabled = Self.lastLevel != nil
        slider.target = self
        slider.action = #selector(volumeChanged)
        func speaker(_ symbol: String) -> NSImageView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            return icon
        }
        let volume = NSStackView(views: [speaker("speaker.fill"), slider, speaker("speaker.wave.3.fill")])
        volume.orientation = .horizontal
        volume.spacing = 8

        // The equalizer: off, Android's presets, and the user's own bands.
        presets.addItem(withTitle: "Off")
        presets.lastItem?.tag = Self.offTag
        presets.menu?.addItem(.separator())
        // Tags from 1: a separator's tag is 0.
        for (index, name) in AndroidRuntime.equalizerPresets.enumerated() {
            presets.addItem(withTitle: name)
            presets.lastItem?.tag = index + 1
        }
        presets.menu?.addItem(.separator())
        presets.addItem(withTitle: "Custom")
        presets.lastItem?.tag = Self.customTag
        presets.target = self
        presets.action = #selector(presetChosen)
        let equalizerRow = NSStackView(views: [NSTextField(labelWithString: "Equalizer"), NSView(), presets])
        equalizerRow.orientation = .horizontal

        // Five bands, each from -15 to +15 dB, as Android's equalizer has them.
        bandRow.orientation = .horizontal
        bandRow.distribution = .fillEqually
        for name in AndroidRuntime.equalizerBands {
            let band = NSSlider(value: 0, minValue: -1500, maxValue: 1500, target: self, action: #selector(bandsChanged))
            band.isVertical = true
            band.isContinuous = false
            band.numberOfTickMarks = 3
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            let column = NSStackView(views: [band, label])
            column.orientation = .vertical
            column.spacing = 4
            band.heightAnchor.constraint(equalToConstant: 90).isActive = true
            bandSliders.append(band)
            bandRow.addArrangedSubview(column)
        }
        bandRow.isHidden = true

        loudness.target = self
        loudness.action = #selector(loudnessChanged)
        loudness.isContinuous = false
        let loudnessRow = NSStackView(views: [NSTextField(labelWithString: "Loudness"), loudness])
        loudnessRow.orientation = .horizontal

        mute.state = muted ? .on : .off
        mute.target = self
        mute.action = #selector(muteToggled)
        let muteRow = NSStackView(views: [NSTextField(labelWithString: "Mute This App"), NSView(), mute])
        muteRow.orientation = .horizontal

        let stack = NSStackView(views: [volume, muteRow, equalizerRow, bandRow, loudnessRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 18, bottom: 22, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 280),
            volume.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            equalizerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            bandRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            loudnessRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            muteRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        if let equalizer = Self.lastEqualizer { show(equalizer) }
        DispatchQueue.global().async { [weak self] in
            let level = AndroidRuntime.shared.mediaVolume(), equalizer = AndroidRuntime.shared.equalizer()
            let loud = AndroidRuntime.shared.loudness()
            DispatchQueue.main.async {
                guard let self else { return }
                Self.lastEqualizer = equalizer
                Self.lastLoudness = loud
                self.show(equalizer)
                self.loudness.integerValue = loud
                guard let level else { return }
                Self.lastLevel = level
                self.slider.integerValue = level
                self.slider.isEnabled = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func show(_ equalizer: String) {
        let parts = equalizer.split(separator: " ")
        switch parts.first {
        case "preset": presets.selectItem(withTag: (Int(parts.dropFirst().first ?? "") ?? -2) + 1)
        case "bands":
            presets.selectItem(withTag: Self.customTag)
            for (slider, value) in zip(bandSliders, parts.dropFirst()) { slider.doubleValue = Double(value) ?? 0 }
        default: presets.selectItem(withTag: Self.offTag)
        }
        bandRow.isHidden = parts.first != "bands"
        layoutSubtreeIfNeeded()
        onResize?(fittingSize)
    }

    @objc private func loudnessChanged() {
        let level = loudness.integerValue
        Self.lastLoudness = level
        DispatchQueue.global().async { AndroidRuntime.shared.setLoudness(level) }
    }

    @objc private func volumeChanged() { set(slider.integerValue) }
    @objc private func muteToggled() { muteChanged?(mute.state == .on) }

    private func set(_ level: Int) {
        slider.integerValue = level
        Self.lastLevel = level
        DispatchQueue.global().async { AndroidRuntime.shared.setMediaVolume(level) }
    }

    @objc private func presetChosen() {
        let tag = presets.selectedTag()
        let choice = tag == Self.offTag ? "off" : tag == Self.customTag ? bands() : "preset \(tag - 1)"
        apply(choice)
    }

    @objc private func bandsChanged() { apply(bands()) }

    private func bands() -> String { "bands " + bandSliders.map { String(Int($0.doubleValue)) }.joined(separator: " ") }

    private func apply(_ choice: String) {
        Self.lastEqualizer = choice
        show(choice)
        DispatchQueue.global().async { AndroidRuntime.shared.setEqualizer(choice) }
    }
}
