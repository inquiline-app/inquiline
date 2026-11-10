import AppKit

/// The window of one running Android app.
final class AppWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    /// A new window shows Android at half its pixels.
    private static let pixelsPerPoint: CGFloat = 2

    let package: String
    let window: NSWindow

    private let displayView: AndroidDisplayView
    private var session: ScrcpySession

    private let orientation: AppOrientation
    private var isLandscape: Bool
    private var userTurned = false
    private var restarted = false
    private var displaySize: NSSize
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
        session = ScrcpySession(package: package, landscape: landscape)
        let shortSide = CGFloat(ScrcpySession.shortSide) / Self.pixelsPerPoint
        let longSide = CGFloat(ScrcpySession.longSide) / Self.pixelsPerPoint
        let points = landscape ? NSSize(width: longSide, height: shortSide) : NSSize(width: shortSide, height: longSide)
        displaySize = points
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
        launchScreen.frame = screen.bounds
        launchScreen.autoresizingMask = [.width, .height]
        screen.addSubview(launchScreen)
        window.contentView = screen
        window.delegate = self
        // Resizing keeps the app's screen in its shape.
        window.contentAspectRatio = points
        window.contentMinSize = points
        window.setContentSize(points)
        window.center()
        // Back where it was last time, as Mac windows are.
        window.setFrameAutosaveName("Main")
        addToolbar()
        connect(session)
    }

    /// Holds the app's screen and, until its first picture, the launch screen.
    private let screen = NSView()
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
                self.displaySize = NSSize(width: CGFloat(width) / Self.pixelsPerPoint, height: CGFloat(height) / Self.pixelsPerPoint)
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
                if let error { NSLog("Inquiline session ended: \(error.localizedDescription)") }
            }
        }
    }

    /// Starts the app again on a screen turned the way it now wants.
    private func restartApp() {
        restarted = true
        gamepads?.stop()
        gamepads = nil
        session.stop()
        session = ScrcpySession(package: package, landscape: isLandscape, restartsApp: true)
        watchedDisplay = nil // the new session brings a new Android screen
        connect(session)
        session.start()
    }

    /// Call once the window is on screen.
    func start() {
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
    private func fitWindow() {
        let size = displaySize
        window.contentAspectRatio = size
        window.contentMinSize = size
        let current = screen.frame.size
        guard !isFullScreen,
              abs(current.width / current.height - size.width / size.height) > 0.01 || current.width < size.width - 0.5
        else { return }
        window.setContentSize(size)
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
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.fpsLabel.stringValue = "\(counter.take())"
        }
        let toolbar = NSToolbar(identifier: "AppWindowToolbar")
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
        [.flexibleSpace, Self.fpsItem, Self.muteItem, Self.rotateItem, .space]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Clearing is in the app's menu; these are there for those who want them at hand.
        [.flexibleSpace, .space, Self.fpsItem, Self.muteItem, Self.rotateItem, Self.clearCacheItem, Self.clearDataItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
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

    func add() {
        lock.lock(); count += 1; lock.unlock()
    }

    /// The count since the last call.
    func take() -> Int {
        lock.lock(); defer { count = 0; lock.unlock() }
        return count
    }
}
