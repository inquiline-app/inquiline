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
    var screenRect: NSRect {
        // A picture that fills the window (FrameRenderer.keepPixelSize).
        if renderer?.keepsPixelSize == true { return bounds }
        return AVMakeRect(aspectRatio: displaySize, insideRect: bounds)
    }

    func sendFinger(_ action: ScrcpySession.TouchAction, x: Int, y: Int, finger: Int64) {
        let x = min(max(x, 0), Int(displaySize.width) - 1), y = min(max(y, 0), Int(displaySize.height) - 1)
        session?.sendTouch(action, x: x, y: y, width: Int(displaySize.width), height: Int(displaySize.height), finger: finger)
        touchObserver?(action, Double(x) / displaySize.width, Double(y) / displaySize.height, finger)
    }

    func showCaughtNote(_ on: Bool) { onCaught?(on) }

    /// A phone's fingers on its touchpad (PhoneRemote), shown where they touch the app, as a
    /// phone's "show taps" does, so that watching the Mac one sees where the finger is.
    private var phoneFingers: [Int: CALayer] = [:]

    func showPhoneFinger(_ action: ScrcpySession.TouchAction, x: Double, y: Double, finger: Int) {
        let rect = screenRect
        let center = CGPoint(x: rect.minX + x * rect.width, y: rect.maxY - y * rect.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if action == .up {
            guard let dot = phoneFingers.removeValue(forKey: finger) else { return }
            CATransaction.setDisableActions(false)
            CATransaction.setCompletionBlock { dot.removeFromSuperlayer() }
            dot.opacity = 0
            return
        }
        let dot = phoneFingers[finger] ?? {
            let dot = CALayer()
            let size: CGFloat = 40
            dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
            dot.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            dot.borderWidth = 2
            dot.shadowOpacity = 0.4
            dot.shadowRadius = 3
            dot.shadowOffset = .zero
            dot.zPosition = 10
            layer?.addSublayer(dot)
            phoneFingers[finger] = dot
            return dot
        }()
        dot.opacity = 1
        dot.position = center
    }

    override func resignFirstResponder() -> Bool {
        releaseAllKeys()
        return true
    }

    /// Lets go of every key and control held down, as when the window stops taking keys.
    func releaseAllKeys() {
        controls.releaseAll()
        keyboard?.releaseAll()
        for key in heldKeys.values { session?.sendKey(.up, keycode: key.keycode, metaState: key.metaState) }
        heldKeys.removeAll()
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
        let rect = screenRect
        let x = (point.x - rect.minX) / rect.width * displaySize.width
        // AppKit's origin is bottom-left, Android's is top-left.
        let y = (rect.maxY - point.y) / rect.height * displaySize.height
        return (
            Int(min(max(x, 0), displaySize.width - 1)),
            Int(min(max(y, 0), displaySize.height - 1))
        )
    }

    /// Told of every touch that goes to the app, from the pointer or a control (keys, a
    /// controller, mouse aim), each finger apart, as fractions of the screen, while a macro
    /// records (ControlsOverlay).
    var touchObserver: ((ScrcpySession.TouchAction, Double, Double, Int64) -> Void)?
    /// Esc while a macro records, unless it lets go of a caught pointer.
    var onEscapeWhileRecording: (() -> Void)?

    private func sendTouch(_ action: ScrcpySession.TouchAction, _ event: NSEvent) {
        let point = androidPoint(for: event)
        session?.sendTouch(action, x: point.x, y: point.y, width: Int(displaySize.width), height: Int(displaySize.height))
        touchObserver?(action, Double(point.x) / displaySize.width, Double(point.y) / displaySize.height, ScrcpySession.mouseFinger)
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

    @objc func copy(_ sender: Any?) { copyOrCut(.copy) }
    @objc func cut(_ sender: Any?) { copyOrCut(.cut) }

    /// The app copies its selection as on a keyboard's Copy key, and the text comes to the Mac.
    private func copyOrCut(_ key: ScrcpySession.CopyKey) {
        guard let session else { return }
        session.sendCopy(key)
        // The server presses the key and waits for the app to take it; then the clipboard is read.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            if let text = ScrcpyServer.clipboardText() { session.onClipboard?(text) }
        }
    }

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

    /// Letters, digits and space go as keys pressed and let go, as a phone's keyboard sends
    /// them, so a game that asks which keys are down sees them held. As text they would
    /// come and go at once. A key whose character Android's own layout wouldn't give, as
    /// ş, İ or a shifted digit's symbol, still goes as text.
    private var heldKeys: [UInt16: (keycode: Int32, metaState: UInt32)] = [:]

    private static func androidKey(for event: NSEvent) -> (keycode: Int32, metaState: UInt32)? {
        let flags = event.modifierFlags
        guard !flags.contains(.option), !flags.contains(.control),
              let base = event.charactersIgnoringModifiers?.lowercased(), base.count == 1,
              let scalar = base.unicodeScalars.first, scalar.isASCII else { return nil }
        let keycode: Int32
        switch Character(scalar) {
        case "a"..."z": keycode = 29 + Int32(scalar.value - 97) // KEYCODE_A
        case "0"..."9": keycode = 7 + Int32(scalar.value - 48)  // KEYCODE_0
        case " ": keycode = 62                                  // KEYCODE_SPACE
        default: return nil
        }
        let shift = flags.contains(.shift), capsLock = flags.contains(.capsLock)
        let upper = shift != capsLock && scalar.properties.isAlphabetic
        let expected = upper ? base.uppercased() : (shift && !scalar.properties.isAlphabetic ? nil : base)
        guard let expected, event.characters == expected else { return nil }
        // META_SHIFT_ON | META_SHIFT_LEFT_ON, META_CAPS_LOCK_ON
        return (keycode, (shift ? 0x41 : 0) | (capsLock ? 0x100000 : 0))
    }

    /// The Mac's keyboard plugged into Android, once the app shows; most keys go through it.
    var keyboard: KeyboardBridge?

    override func keyDown(with event: NSEvent) {
        // Esc lets go of a caught pointer, as in Mac games, instead of going back.
        if controls.isCaught && event.keyCode == 53 { controls.releasePointer(); return }
        if touchObserver != nil && event.keyCode == 53 { onEscapeWhileRecording?(); return }
        if controls.key(Int(event.keyCode), down: true) { return }
        keyObserver?(Self.stroke(event), true)
        sendKeyDown(event)
    }

    /// Told of each key that goes to the app, while a macro records (ControlsOverlay).
    var keyObserver: ((KeyControl.KeyStroke, Bool) -> Void)?

    private static func stroke(_ event: NSEvent) -> KeyControl.KeyStroke {
        KeyControl.KeyStroke(code: Int(event.keyCode), flags: event.modifierFlags.rawValue,
                             characters: event.characters, plain: event.charactersIgnoringModifiers)
    }

    /// A key a macro recorded, played to the app as it was pressed.
    func replayKey(_ stroke: KeyControl.KeyStroke, down: Bool) {
        guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: stroke.flags),
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                                           context: nil, characters: stroke.characters ?? "", charactersIgnoringModifiers: stroke.plain ?? "",
                                           isARepeat: false, keyCode: UInt16(stroke.code))
        else { return }
        if down { sendKeyDown(event) } else { sendKeyUp(event) }
    }

    private func sendKeyDown(_ event: NSEvent) {
        // Esc stays Android's Back, as Android's keyboards give it nothing else to do. A
        // character made with Option goes as text, unless the layout's Option is a PC's AltGr.
        if event.keyCode != 53, !event.modifierFlags.contains(.option) || keyboard?.optionIsAltGr == true,
           keyboard?.key(event.keyCode, down: true, flags: event.modifierFlags) == true { return }
        if let keycode = Self.specialKeys[event.keyCode] {
            heldKeys[event.keyCode] = (keycode, 0)
            session?.sendKey(.down, keycode: keycode)
        } else if let key = heldKeys[event.keyCode] ?? Self.androidKey(for: event) {
            heldKeys[event.keyCode] = key
            session?.sendKey(.down, keycode: key.keycode, metaState: key.metaState)
        } else if let text = event.characters, !text.isEmpty, !event.modifierFlags.contains(.control),
                  !text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
            // Android types only the characters of its own virtual keyboard from text, so others,
            // as €, é or ş without a keyboard of that layout, are pasted.
            if text.unicodeScalars.allSatisfy(\.isASCII) { session?.sendText(text) } else { session?.sendPaste(text) }
        }
    }

    override func keyUp(with event: NSEvent) {
        if controls.key(Int(event.keyCode), down: false) { return }
        keyObserver?(Self.stroke(event), false)
        sendKeyUp(event)
    }

    private func sendKeyUp(_ event: NSEvent) {
        // Let go even with Option now held: a key pressed through the keyboard is let go there.
        if event.keyCode != 53, keyboard?.key(event.keyCode, down: false) == true { return }
        // Only keys pressed in this window: Esc that cancels a screenshot comes up here alone, and
        // Android acts on Back's letting go.
        if let key = heldKeys.removeValue(forKey: event.keyCode) {
            session?.sendKey(.up, keycode: key.keycode, metaState: key.metaState)
        }
    }

    /// Shift, Control and Option come alone, without a key, and can be controls too.
    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 56, 60: flag = .shift
        case 59, 62: flag = .control
        case 58, 61: flag = .option
        case 57:
            keyboard?.modifiersChanged(event)
            return
        default: return
        }
        if controls.key(Int(event.keyCode), down: event.modifierFlags.contains(flag)) { return }
        keyboard?.modifiersChanged(event)
    }
}
