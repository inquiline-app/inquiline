import AppKit
import AVFoundation

/// Shows the app's Android frames (see FrameRenderer) and turns mouse, trackpad and
/// keyboard events into Android input.
final class AndroidDisplayView: NSView {
    var session: ScrcpySession?

    /// Current Android display size in pixels; touches must be reported against it.
    private var displaySize = CGSize(width: 1, height: 1)
    var androidSize: CGSize { displaySize }
    let renderer: FrameRenderer?
    /// Keyboard controls for games made for touch (KeyControls).
    let controls = KeyControlPlayer()
    /// Says how to let go of the pointer while the mouse aims.
    var onCaught: ((Bool) -> Void)?

    override init(frame: NSRect) {
        renderer = FrameRenderer()
        super.init(frame: frame)
        layer = renderer?.layer ?? CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
        controls.view = self
    }

    /// Where the app's screen is drawn in the view: the window keeps its shape, but full
    /// screen can leave bars at its sides.
    var screenRect: NSRect { AVMakeRect(aspectRatio: displaySize, insideRect: bounds) }

    func sendFinger(_ action: ScrcpySession.TouchAction, x: Int, y: Int, finger: Int64) {
        let x = min(max(x, 0), Int(displaySize.width) - 1), y = min(max(y, 0), Int(displaySize.height) - 1)
        session?.sendTouch(action, x: x, y: y, width: Int(displaySize.width), height: Int(displaySize.height), finger: finger)
    }

    func showCaughtNote(_ on: Bool) { onCaught?(on) }

    override func resignFirstResponder() -> Bool {
        controls.releaseAll()
        return true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        updateWindowPixels()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateWindowPixels()
    }

    private func updateWindowPixels() {
        let scale = window?.backingScaleFactor ?? 2
        renderer?.layer.contentsScale = scale
        renderer?.setWindowPixels(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Called on the session's receive thread.
    func setDisplaySize(width: Int, height: Int) {
        renderer?.setSize(width: width, height: height)
        DispatchQueue.main.async { self.displaySize = CGSize(width: width, height: height) }
    }

    // MARK: - Pointer input

    private func androidPoint(for event: NSEvent) -> (x: Int, y: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: displaySize, insideRect: bounds)
        let x = (point.x - rect.minX) / rect.width * displaySize.width
        // AppKit's origin is bottom-left, Android's is top-left.
        let y = (rect.maxY - point.y) / rect.height * displaySize.height
        return (
            Int(min(max(x, 0), displaySize.width - 1)),
            Int(min(max(y, 0), displaySize.height - 1))
        )
    }

    private func sendTouch(_ action: ScrcpySession.TouchAction, _ event: NSEvent) {
        let point = androidPoint(for: event)
        session?.sendTouch(action, x: point.x, y: point.y, width: Int(displaySize.width), height: Int(displaySize.height))
    }

    override func mouseDown(with event: NSEvent) {
        if controls.isCaught { _ = controls.key(KeyControl.leftClick, down: true); return }
        // With a mouse-aim control, a click catches the pointer, as a Mac game does.
        if controls.set.isActive && controls.set.hasAim { controls.catchPointer(); return }
        sendTouch(.down, event)
    }

    override func mouseDragged(with event: NSEvent) {
        if controls.isCaught { controls.aim(dx: event.deltaX, dy: event.deltaY); return }
        sendTouch(.move, event)
    }

    override func mouseUp(with event: NSEvent) {
        if controls.isCaught { _ = controls.key(KeyControl.leftClick, down: false); return }
        guard !(controls.set.isActive && controls.set.hasAim) else { return }
        sendTouch(.up, event)
    }

    override func mouseMoved(with event: NSEvent) {
        if controls.isCaught { controls.aim(dx: event.deltaX, dy: event.deltaY) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if controls.isCaught { _ = controls.key(KeyControl.rightClick, down: true) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if controls.isCaught { controls.aim(dx: event.deltaX, dy: event.deltaY) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if controls.isCaught { _ = controls.key(KeyControl.rightClick, down: false) }
    }

    // MARK: - Trackpad gestures

    /// A pinch or a turn on the trackpad is two fingers on the app's screen, around the
    /// pointer, as on a phone: maps zoom, photos turn.
    private var pinch: (center: CGPoint, spread: CGFloat, angle: CGFloat)?
    private static let pinchFingers: (Int64, Int64) = (0, 1)

    override func magnify(with event: NSEvent) {
        gesture(event) { $0.spread *= 1 + event.magnification }
    }

    override func rotate(with event: NSEvent) {
        // The Mac turns counterclockwise for positive; Android's y axis points down.
        gesture(event) { $0.angle -= CGFloat(event.rotation) * .pi / 180 }
    }

    private func gesture(_ event: NSEvent, change: (inout (center: CGPoint, spread: CGFloat, angle: CGFloat)) -> Void) {
        switch event.phase {
        case .began:
            guard pinch == nil else { break }
            let p = androidPoint(for: event)
            pinch = (CGPoint(x: p.x, y: p.y), displaySize.height * 0.15, 0)
            sendPinch(.down)
        case .changed:
            guard pinch != nil else { return }
            change(&pinch!)
            pinch!.spread = min(max(pinch!.spread, 20), displaySize.height * 0.45)
            sendPinch(.move)
        case .ended, .cancelled:
            guard pinch != nil else { return }
            sendPinch(.up)
            pinch = nil
        default:
            break
        }
    }

    private func sendPinch(_ action: ScrcpySession.TouchAction) {
        guard let pinch else { return }
        let dx = cos(pinch.angle) * pinch.spread, dy = sin(pinch.angle) * pinch.spread
        sendFinger(action, x: Int(pinch.center.x - dx), y: Int(pinch.center.y - dy), finger: Self.pinchFingers.0)
        sendFinger(action, x: Int(pinch.center.x + dx), y: Int(pinch.center.y + dy), finger: Self.pinchFingers.1)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = androidPoint(for: event)
        let scale = event.hasPreciseScrollingDeltas ? 0.05 : 1.0
        session?.sendScroll(
            x: point.x, y: point.y,
            width: Int(displaySize.width), height: Int(displaySize.height),
            horizontal: Double(event.scrollingDeltaX) * scale,
            vertical: Double(event.scrollingDeltaY) * scale
        )
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) { session?.sendCopy(.copy) }
    @objc func cut(_ sender: Any?) { session?.sendCopy(.cut) }

    /// Mac clipboard text only reaches Android on an explicit paste, so apps in
    /// the VM can't read whatever else gets copied on the Mac.
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            session?.sendPaste(text)
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        let keycodeA: Int32 = 29
        let metaCtrlOn: UInt32 = 0x3000
        session?.sendKey(.down, keycode: keycodeA, metaState: metaCtrlOn)
        session?.sendKey(.up, keycode: keycodeA, metaState: metaCtrlOn)
    }

    // MARK: - Keyboard

    /// macOS virtual key code → Android keycode.
    private static let specialKeys: [UInt16: Int32] = [
        36: 66,   // return
        76: 66,   // keypad enter
        48: 61,   // tab
        51: 67,   // backspace
        117: 112, // forward delete
        53: 4,    // escape → Android back
        123: 21,  // left
        124: 22,  // right
        125: 20,  // down
        126: 19,  // up
        115: 122, // home
        119: 123, // end
        116: 92,  // page up
        121: 93,  // page down
    ]

    override func keyDown(with event: NSEvent) {
        // Esc lets go of a caught pointer, as in Mac games, instead of going back.
        if controls.isCaught && event.keyCode == 53 { controls.releasePointer(); return }
        if controls.key(Int(event.keyCode), down: true) { return }
        if let keycode = Self.specialKeys[event.keyCode] {
            session?.sendKey(.down, keycode: keycode)
        } else if let text = event.characters, !text.isEmpty, !event.modifierFlags.contains(.control) {
            session?.sendText(text)
        }
    }

    override func keyUp(with event: NSEvent) {
        if controls.key(Int(event.keyCode), down: false) { return }
        if let keycode = Self.specialKeys[event.keyCode] {
            session?.sendKey(.up, keycode: keycode)
        }
    }

    /// Shift, Control and Option come alone, without a key, and can be controls too.
    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 56, 60: flag = .shift
        case 59, 62: flag = .control
        case 58, 61: flag = .option
        default: return
        }
        _ = controls.key(Int(event.keyCode), down: event.modifierFlags.contains(flag))
    }
}
