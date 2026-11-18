import AppKit

/// Android's widgets on the Mac's desktop, each as Android draws it, in a window of its own
/// that sits on the desktop below every other window: as a phone's home screen has them, not
/// fitted to the Mac's own widgets. A click is a tap, a scroll scrolls its lists, a drag moves
/// it as a window, its edges resize it within the sizes the widget allows, and widgets never
/// overlap. A right-click gives what a long press gives on a phone.
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
        let minSize: CGSize
        let maxSize: CGSize
        /// Android's resize mode: 1 across, 2 down.
        let resizeMode: Int
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
        Self.setCursorInBackground()
        if let data = try? Data(contentsOf: Self.listFile),
           let list = try? JSONDecoder().decode([Widget].self, from: data) {
            widgets = list
        }
        for widget in widgets { show(widget) }
    }

    /// The Mac lets only the app in front set the cursor, and Inquiline never is while the
    /// mouse is over a widget on the desktop: it's let set it from behind, as desktop tools are,
    /// so a widget's edges show the resize cursor as a window's do.
    private static func setCursorInBackground() {
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let skyLight = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let connection = dlsym(skyLight, "_CGSDefaultConnection"),
              let setProperty = dlsym(skyLight, "CGSSetConnectionProperty") else { return }
        let id = unsafeBitCast(connection, to: Connection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// The helper connected: Android hosts each widget again at its size.
    func connected() {
        for widget in widgets { place(widget) }
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
        func number(_ key: String) -> Double { Double(info[key] as? Int ?? 0) }
        let minimum = CGSize(width: max(number("minResizeWidth") > 0 ? number("minResizeWidth") : number("minWidth"), 40),
                             height: max(number("minResizeHeight") > 0 ? number("minResizeHeight") : number("minHeight"), 40))
        let maximum = CGSize(width: number("maxResizeWidth") > 0 ? number("maxResizeWidth") : 1000,
                             height: number("maxResizeHeight") > 0 ? number("maxResizeHeight") : 1000)
        // Its size on a phone's home screen: the cells it asks for, or as many as its smallest
        // size takes, each a phone's cell of about 96 by 112 dp, less the space between them.
        func cells(_ asked: Double, smallest: Double, cell: Double) -> Double {
            asked > 0 ? asked : max(1, ((smallest + 8) / cell).rounded(.up))
        }
        let across = cells(number("targetCellWidth"), smallest: number("minWidth"), cell: 96)
        let down = cells(number("targetCellHeight"), smallest: number("minHeight"), cell: 112)
        let width = min(max(across * 96 - 8, number("minWidth"), minimum.width), maximum.width)
        let height = min(max(down * 112 - 8, number("minHeight"), minimum.height), maximum.height)
        let label = info["label"] as? String ?? ""
        let widget = Widget(key: UUID().uuidString, package: package, provider: provider, label: label,
                            frame: freePlace(for: CGSize(width: width.rounded(), height: height.rounded())),
                            minSize: minimum, maxSize: maximum, resizeMode: info["resizeMode"] as? Int ?? 0)
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

    /// A tap that opens the widget's app: its window opens, and the tap's action runs in it.
    func open(key: String, package: String) {
        guard key.range(of: "^[A-F0-9-]+$", options: .regularExpression) != nil else { return }
        NotificationBridge.shared.openWindow(package: package) { display in
            // Root, as only the helper itself may start its screen.
            _ = try? AdbClient.shell("su 0 am start --display \(display) -n \(NotificationBridge.agent)/.Launch --es key \(key)")
        }
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
        send?(["placeWidget": widget.key, "provider": widget.provider,
               "width": Int(widget.frame.width), "height": Int(widget.frame.height)])
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

    /// Moved or resized: kept, and a new size laid out again by Android.
    fileprivate func changed(_ key: String, frame: CGRect) {
        guard let index = widgets.firstIndex(where: { $0.key == key }) else { return }
        let resized = widgets[index].frame.size != frame.size
        widgets[index].frame = frame
        save()
        if resized {
            send?(["resizeWidget": key, "width": Int(frame.width), "height": Int(frame.height)])
        }
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
        acceptsMouseMovedEvents = true
        contentView = widgetView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WidgetView: NSView {
    let key: String
    weak var owner: DesktopWidgets?

    var picture: NSImage? {
        didSet { layer?.contents = picture?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    }

    private enum Gesture { case pending, moving, resizing(left: Bool, right: Bool, bottom: Bool, top: Bool) }

    /// Showing its frame and handles, as a long press does on a phone, until a click elsewhere.
    private var framed = false {
        didSet {
            frameLayer.isHidden = !framed
            needsLayout = true
            if framed {
                outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    self?.framed = false
                }
                // Inquiline's own windows, another widget among them, and Esc while it's in front.
                escape = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self else { return event }
                    if event.type == .keyDown {
                        if event.keyCode == 53 { self.framed = false; return nil }
                    } else if event.window !== self.window {
                        self.framed = false
                    }
                    return event
                }
            } else {
                outside.map(NSEvent.removeMonitor)
                escape.map(NSEvent.removeMonitor)
                outside = nil
                escape = nil
            }
            window?.invalidateCursorRects(for: self)
            if !framed { NSCursor.arrow.set() }
        }
    }
    private var outside: Any?
    private var escape: Any?
    private let frameLayer = CAShapeLayer()
    private var gesture: Gesture?
    private var start = CGPoint.zero
    private var startFrame = CGRect.zero
    private var scrolled: CGFloat = 0

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
        // The Mac passes clicks on a window's clear pixels through to what is behind it; widgets'
        // edges are often clear. A fill too faint to see makes all of the widget's box take them,
        // as its whole cell does on a phone, and its edges resize it as a window's do.
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.004).cgColor
        frameLayer.fillColor = nil
        frameLayer.isHidden = true
        layer?.addSublayer(frameLayer)
    }

    override func layout() {
        super.layout()
        guard framed, let widget = owner?.widget(key) else { return }
        // A rounded frame in the accent, with a round handle on each side it resizes along.
        let path = CGMutablePath()
        path.addRoundedRect(in: bounds.insetBy(dx: 9, dy: 9), cornerWidth: 12, cornerHeight: 12)
        var handles: [CGPoint] = []
        if widget.resizeMode & 1 != 0 { handles += [CGPoint(x: 9, y: bounds.midY), CGPoint(x: bounds.maxX - 9, y: bounds.midY)] }
        if widget.resizeMode & 2 != 0 { handles += [CGPoint(x: bounds.midX, y: 9), CGPoint(x: bounds.midX, y: bounds.maxY - 9)] }
        let dots = CGMutablePath()
        for handle in handles { dots.addEllipse(in: CGRect(x: handle.x - 7, y: handle.y - 7, width: 14, height: 14)) }
        frameLayer.frame = bounds
        frameLayer.path = path
        frameLayer.lineWidth = 2
        frameLayer.strokeColor = NSColor.controlAccentColor.cgColor
        let dotLayer = (frameLayer.sublayers?.first as? CAShapeLayer) ?? {
            let layer = CAShapeLayer()
            frameLayer.addSublayer(layer)
            return layer
        }()
        dotLayer.path = dots
        dotLayer.fillColor = NSColor.controlAccentColor.cgColor
        dotLayer.strokeColor = NSColor.white.cgColor
        dotLayer.lineWidth = 2
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The widget's window never comes to the front, where cursor rects work: the cursor follows
    // the mouse here, as a window's edge shows it can be resized.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard gesture == nil else { return }
        cursor(for: edges(at: convert(event.locationInWindow, from: nil))).set()
    }

    override func mouseExited(with event: NSEvent) {
        if gesture == nil { NSCursor.arrow.set() }
    }

    private func cursor(for at: (left: Bool, right: Bool, bottom: Bool, top: Bool)) -> NSCursor {
        let across = at.left || at.right, down = at.bottom || at.top
        if across && down, #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = at.top ? (at.left ? .topLeft : .topRight) : (at.left ? .bottomLeft : .bottomRight)
            return .frameResize(position: position, directions: .all)
        }
        return across ? .resizeLeftRight : down ? .resizeUpDown : .arrow
    }

    /// The point in the widget as Android has it: from the top left, in dp.
    private func androidPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private func edges(at point: CGPoint) -> (left: Bool, right: Bool, bottom: Bool, top: Bool) {
        guard let widget = owner?.widget(key) else { return (false, false, false, false) }
        // Only in its frame, as on a phone only after a long press.
        guard framed else { return (false, false, false, false) }
        let across = widget.resizeMode & 1 != 0, down = widget.resizeMode & 2 != 0
        let edge: CGFloat = 18
        return (across && point.x < edge, across && point.x > bounds.width - edge,
                down && point.y < edge, down && point.y > bounds.height - edge)
    }

    override func resetCursorRects() {
        guard framed, let widget = owner?.widget(key) else { return }
        let edge: CGFloat = 18
        if widget.resizeMode & 1 != 0 {
            addCursorRect(NSRect(x: 0, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.width - edge, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
        }
        if widget.resizeMode & 2 != 0 {
            addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: edge), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: 0, y: bounds.height - edge, width: bounds.width, height: edge), cursor: .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A control-click is a right-click, as everywhere on the Mac.
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        guard let window else { return }
        start = NSEvent.mouseLocation
        startFrame = window.frame
        let at = edges(at: convert(event.locationInWindow, from: nil))
        gesture = at.left || at.right || at.bottom || at.top
            ? .resizing(left: at.left, right: at.right, bottom: at.bottom, top: at.top) : .pending
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let owner, let widget = owner.widget(key), let gesture else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        switch gesture {
        case .pending:
            // A drag, not a tap: the widget moves, as a window does.
            if hypot(dx, dy) > 3 { self.gesture = .moving; mouseDragged(with: event) }
        case .moving:
            let current = window.frame
            var proposed = startFrame.offsetBy(dx: dx, dy: dy)
            // Blocked by another widget, it slides along it.
            if owner.overlaps(proposed, except: key) {
                let across = CGRect(origin: CGPoint(x: proposed.minX, y: current.minY), size: current.size)
                let down = CGRect(origin: CGPoint(x: current.minX, y: proposed.minY), size: current.size)
                proposed = !owner.overlaps(across, except: key) ? across : !owner.overlaps(down, except: key) ? down : current
            }
            window.setFrameOrigin(proposed.origin)
        case let .resizing(left, right, bottom, top):
            var frame = startFrame
            if right { frame.size.width = startFrame.width + dx }
            if left { frame.size.width = startFrame.width - dx }
            if top { frame.size.height = startFrame.height + dy }
            if bottom { frame.size.height = startFrame.height - dy }
            frame.size.width = min(max(frame.width, widget.minSize.width), widget.maxSize.width).rounded()
            frame.size.height = min(max(frame.height, widget.minSize.height), widget.maxSize.height).rounded()
            if left { frame.origin.x = startFrame.maxX - frame.width }
            if bottom { frame.origin.y = startFrame.maxY - frame.height }
            // Stops at a neighbour.
            if !owner.overlaps(frame, except: key) { window.setFrame(frame, display: true) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let window, let gesture else { return }
        self.gesture = nil
        switch gesture {
        case .pending where framed:
            // Inside its frame a click does nothing; outside, or Esc, ends it.
            break
        case .pending:
            let point = androidPoint(event)
            owner?.touch(key, "down", at: point)
            owner?.touch(key, "up", at: point)
        case .moving, .resizing:
            owner?.changed(key, frame: window.frame)
            window.invalidateCursorRects(for: self)
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
        if widget.resizeMode & 3 != 0 {
            menu.addItem(withTitle: "Resize Widget", action: #selector(resizeWidget), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove Widget", action: #selector(removeWidget), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openApp() { owner?.openApp(key) }
    @objc private func removeWidget() { owner?.remove(key: key) }
    @objc private func resizeWidget() { framed = true }
}
