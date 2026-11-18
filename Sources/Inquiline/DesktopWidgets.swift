import AppKit

/// Android's widgets on the Mac's desktop, each as Android draws it, in a window of its own
/// that sits on the desktop below every other window: as a phone's home screen has them, not
/// fitted to the Mac's own widgets, at the size its app gives it. A click is a tap, a scroll
/// scrolls its lists, a drag moves it as a window, and widgets never overlap. A right-click gives
/// what a long press gives on a phone.
///
/// Inquiline keeps where they are (desktop-widgets.json) and their last pictures, so they show
/// at once when Inquiline starts; the helper inside Android hosts them (WidgetHost) and sends a
/// new picture whenever one changes. An app's window adds and removes its widgets
/// (inquiline://widget), from its settings.
final class DesktopWidgets {
    static let shared = DesktopWidgets()

    struct Widget: Codable {
        let key: String
        let package: String
        let provider: String
        let label: String
        /// In the Mac's screen coordinates, in points, which are Android's dp.
        var frame: CGRect
        /// Its id in Android, so it keeps what it was set up with when Android starts again.
        var androidID: Int?
    }

    /// Sends a message to the helper inside Android.
    var send: (([String: Any]) -> Void)?

    private var widgets: [Widget] = []
    private var windows: [String: WidgetWindow] = [:]

    static var folder: URL {
        AndroidRuntime.shared.home.appendingPathComponent("desktop-widgets")
    }

    private static var listFile: URL { folder.appendingPathComponent("widgets.json") }

    /// The widgets on the desktop, by provider, for an app's settings: read from the file, as
    /// the app's own process asks.
    static func placed(package: String) -> [String: String] {
        guard let data = try? Data(contentsOf: listFile),
              let list = try? JSONDecoder().decode([Widget].self, from: data) else { return [:] }
        return Dictionary(list.filter { $0.package == package }.map { ($0.provider, $0.key) }, uniquingKeysWith: { a, _ in a })
    }

    /// At launch: the widgets where they were, with their last pictures.
    func start() {
        if let data = try? Data(contentsOf: Self.listFile),
           let list = try? JSONDecoder().decode([Widget].self, from: data) {
            widgets = list
        }
        for widget in widgets { show(widget) }
    }

    /// The helper connected: Android hosts each widget again, at the size its app gives it now.
    func connected() {
        let packages = Set(widgets.map(\.package))
        DispatchQueue.global().async {
            var sizes: [String: CGSize] = [:]
            for package in packages {
                for info in AndroidRuntime.shared.widgetList(package: package) ?? [] {
                    if let provider = info["provider"] as? String { sizes[provider] = Self.size(of: info) }
                }
            }
            DispatchQueue.main.async {
                for index in self.widgets.indices {
                    guard let size = sizes[self.widgets[index].provider], size != self.widgets[index].frame.size else { continue }
                    // Its top left stays where it is.
                    let old = self.widgets[index].frame
                    self.widgets[index].frame = CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
                    self.windows[self.widgets[index].key]?.setFrame(self.widgets[index].frame, display: true)
                }
                self.save()
                for widget in self.widgets { self.place(widget) }
                // Any widget the helper still holds that the Mac no longer shows goes.
                self.send?(["pruneWidgets": true])
            }
        }
    }

    /// Its size on a phone's home screen: the cells its app asks for, or as many as its smallest
    /// size takes, each a phone's cell of about 96 by 112 dp, less the space between them.
    private static func size(of info: [String: Any]) -> CGSize {
        func number(_ key: String) -> Double { Double(info[key] as? Int ?? 0) }
        func cells(_ asked: Double, smallest: Double, cell: Double) -> Double {
            asked > 0 ? asked : max(1, ((smallest + 8) / cell).rounded(.up))
        }
        let across = cells(number("targetCellWidth"), smallest: number("minWidth"), cell: 96)
        let down = cells(number("targetCellHeight"), smallest: number("minHeight"), cell: 112)
        var width = max(across * 96 - 8, number("minWidth")), height = max(down * 112 - 8, number("minHeight"))
        if number("maxResizeWidth") > 0 { width = min(width, number("maxResizeWidth")) }
        if number("maxResizeHeight") > 0 { height = min(height, number("maxResizeHeight")) }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// From an app's settings: one of its widgets onto the desktop, at its own default size, in
    /// the first free place.
    func add(package: String, provider: String) {
        DispatchQueue.global().async {
            guard let info = AndroidRuntime.shared.widgetList(package: package)?.first(where: { $0["provider"] as? String == provider })
            else { return }
            DispatchQueue.main.async { self.add(package: package, provider: provider, info: info) }
        }
    }

    private func add(package: String, provider: String, info: [String: Any]) {
        guard !widgets.contains(where: { $0.provider == provider }) else { return }
        let widget = Widget(key: UUID().uuidString, package: package, provider: provider,
                            label: info["label"] as? String ?? "", frame: freePlace(for: Self.size(of: info)))
        widgets.append(widget)
        save()
        show(widget)
        place(widget)
        AppLog.write("A widget was added to the desktop")
    }

    func remove(key: String) {
        guard let index = widgets.firstIndex(where: { $0.key == key }) else { return }
        widgets.remove(at: index)
        windows.removeValue(forKey: key)?.close()
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(key).png"))
        send?(["removeWidget": key])
        save()
    }

    /// An app was removed: its widgets go with it.
    func remove(package: String) {
        for widget in widgets where widget.package == package { remove(key: widget.key) }
        // The list of its widgets its settings kept.
        try? FileManager.default.removeItem(at: AndroidRuntime.shared.home.appendingPathComponent("widget-lists/\(package).json"))
    }

    /// A new picture from Android.
    func received(key: String, png: Data) {
        guard let window = windows[key] else {
            // Removed on the Mac meanwhile.
            send?(["removeWidget": key])
            return
        }
        window.widgetView.picture = NSImage(data: png)
        let file = Self.folder.appendingPathComponent("\(key).png")
        DispatchQueue.global(qos: .utility).async { try? png.write(to: file) }
    }

    /// Widgets whose tap woke Android's screen, to turn it off again once the tap has run.
    private var woke: Set<String> = []

    /// A tap's action, ready in the helper, runs from its Launch screen: one that opens the app on
    /// the app's window, which opens for it; any other, as play or a tick, on the widget's own
    /// screen, with Android's screen on for it as a phone's is when it's tapped.
    func tapped(key: String, package: String, opensApp: Bool, display: Int) {
        guard key.range(of: "^[A-F0-9-]+$", options: .regularExpression) != nil else { return }
        // Root, as only the helper itself may start its screen.
        func launch(on display: Int) {
            _ = try? AdbClient.shell("su 0 am start --display \(display) -n \(NotificationBridge.agent)/.Launch --es key \(key)")
        }
        if opensApp {
            NotificationBridge.shared.openWindow(package: package) { launch(on: $0) }
            return
        }
        DispatchQueue.global().async {
            let awake = (try? AdbClient.shell("dumpsys power | grep -m1 mWakefulness="))?.contains("Awake") ?? true
            if !awake {
                AndroidRuntime.shared.setScreenOn(true)
                DispatchQueue.main.async { self.woke.insert(key) }
            }
            launch(on: display)
        }
    }

    /// The tap ran: Android's screen goes back off if the tap turned it on, as a phone's does;
    /// what it started, as music, plays on.
    func tapDone(key: String) {
        guard woke.remove(key) != nil else { return }
        DispatchQueue.global().async { AndroidRuntime.shared.setScreenOn(false) }
    }

    // MARK: - Windows

    private func show(_ widget: Widget) {
        let window = WidgetWindow(widget: widget)
        window.widgetView.picture = NSImage(contentsOf: Self.folder.appendingPathComponent("\(widget.key).png"))
        window.widgetView.owner = self
        windows[widget.key] = window
        window.orderFront(nil)
    }

    private func place(_ widget: Widget) {
        send?(["placeWidget": widget.key, "provider": widget.provider, "id": widget.androidID ?? 0,
               "width": Int(widget.frame.width), "height": Int(widget.frame.height)])
    }

    /// Android gave the widget an id; one its app must set up first gets its setup screen, in
    /// the app's window, as a phone's home screen opens it when the widget is dropped there.
    func bound(key: String, id: Int, setup: String?, package: String?) {
        guard let index = widgets.firstIndex(where: { $0.key == key }) else { return }
        widgets[index].androidID = id
        save()
        guard let setup, let package,
              setup.range(of: "^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$", options: .regularExpression) != nil else { return }
        NotificationBridge.shared.openWindow(package: package) { display in
            _ = try? AdbClient.shell("su 0 am start --display \(display) -a android.appwidget.action.APPWIDGET_CONFIGURE "
                                     + "-n '\(setup)' --ei appWidgetId \(id)")
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(widgets) { try? data.write(to: Self.listFile, options: .atomic) }
    }

    /// The first place on the main screen, from its top left, where the size overlaps nothing.
    private func freePlace(for size: CGSize) -> CGRect {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.insetBy(dx: 20, dy: 20)
        var y = screen.maxY - size.height
        while y >= screen.minY {
            var x = screen.minX
            while x + size.width <= screen.maxX {
                let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
                if let blocking = widgets.first(where: { $0.frame.insetBy(dx: -8, dy: -8).intersects(frame) }) {
                    x = blocking.frame.maxX + 8
                } else {
                    return frame
                }
            }
            y -= 20
        }
        return CGRect(origin: CGPoint(x: screen.minX, y: screen.maxY - size.height), size: size)
    }

    /// Whether the frame would overlap another widget; touching is allowed.
    fileprivate func overlaps(_ frame: CGRect, except key: String) -> Bool {
        widgets.contains { $0.key != key && $0.frame.insetBy(dx: 0.5, dy: 0.5).intersects(frame.insetBy(dx: 0.5, dy: 0.5)) }
    }

    fileprivate func widget(_ key: String) -> Widget? { widgets.first { $0.key == key } }

    /// Moved: kept where it is.
    fileprivate func moved(_ key: String, to frame: CGRect) {
        guard let index = widgets.firstIndex(where: { $0.key == key }) else { return }
        widgets[index].frame = frame
        save()
    }

    fileprivate func touch(_ key: String, _ action: String, at point: CGPoint) {
        send?(["touchWidget": key, "action": action, "x": point.x, "y": point.y])
    }

    fileprivate func scroll(_ key: String, at point: CGPoint, lines: CGFloat) {
        send?(["scrollWidget": key, "x": point.x, "y": point.y, "lines": lines])
    }

    fileprivate func openApp(_ key: String) {
        guard let widget = widget(key), let bundle = AppShortcuts.bundle(of: widget.package) else { return }
        NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// A widget's window: borderless, on the desktop below every other window, on every Space.
private final class WidgetWindow: NSPanel {
    let widgetView: WidgetView

    init(widget: DesktopWidgets.Widget) {
        widgetView = WidgetView(key: widget.key)
        super.init(contentRect: widget.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = widgetView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The widget as Android draws it. Its clear parts are the desktop's: clicks there go through.
private final class WidgetView: NSView {
    let key: String
    weak var owner: DesktopWidgets?

    var picture: NSImage? {
        didSet { layer?.contents = picture?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    }

    private var pressed = false
    private var moving = false
    private var start = CGPoint.zero
    private var startFrame = CGRect.zero
    private var scrolled: CGFloat = 0

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The point in the widget as Android has it: from the top left, in dp.
    private func androidPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    override func mouseDown(with event: NSEvent) {
        // A control-click is a right-click, as everywhere on the Mac.
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        guard let window else { return }
        start = NSEvent.mouseLocation
        startFrame = window.frame
        pressed = true
        moving = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed, let window, let owner else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        // A drag, not a tap: the widget moves, as a window does.
        if !moving, hypot(dx, dy) <= 3 { return }
        moving = true
        let current = window.frame
        var proposed = Self.onScreen(startFrame.offsetBy(dx: dx, dy: dy), at: now)
        // Blocked by another widget, it slides along it.
        if owner.overlaps(proposed, except: key) {
            let across = CGRect(origin: CGPoint(x: proposed.minX, y: current.minY), size: current.size)
            let down = CGRect(origin: CGPoint(x: current.minX, y: proposed.minY), size: current.size)
            proposed = !owner.overlaps(across, except: key) ? across : !owner.overlaps(down, except: key) ? down : current
        }
        window.setFrameOrigin(proposed.origin)
    }

    /// Kept whole on the screen the mouse is on, below the menu bar and beside the Dock.
    private static func onScreen(_ frame: CGRect, at point: CGPoint) -> CGRect {
        guard let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        return frame
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed, let window else { return }
        pressed = false
        if moving {
            owner?.moved(key, to: window.frame)
        } else {
            let point = androidPoint(event)
            owner?.touch(key, "down", at: point)
            owner?.touch(key, "up", at: point)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // A trackpad's points or a wheel's lines, as Android's lines: up is a positive scroll.
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 24 : event.scrollingDeltaY
        guard abs(scrolled) >= 0.5 || event.phase == .ended else { return }
        owner?.scroll(key, at: androidPoint(event), lines: scrolled)
        scrolled = 0
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let widget = owner?.widget(key) else { return }
        let menu = NSMenu()
        let appName = AppShortcuts.bundle(of: widget.package).map { FileManager.default.displayName(atPath: $0.path) }
            .map { ($0 as NSString).deletingPathExtension } ?? widget.label
        menu.addItem(withTitle: "Open \(appName)", action: #selector(openApp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove Widget", action: #selector(removeWidget), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openApp() { owner?.openApp(key) }
    @objc private func removeWidget() { owner?.remove(key: key) }
}
