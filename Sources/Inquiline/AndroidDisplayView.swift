import AppKit
import AVFoundation

/// Shows the app's Android frames (see FrameRenderer) and turns mouse, trackpad and
/// keyboard events into Android input.
final class AndroidDisplayView: NSView {
    var session: ScrcpySession?

    /// Current Android display size in pixels; touches must be reported against it.
    private var displaySize = CGSize(width: 1, height: 1)
    let renderer: FrameRenderer?

    override init(frame: NSRect) {
        renderer = FrameRenderer()
        super.init(frame: frame)
        layer = renderer?.layer ?? CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

    override func mouseDown(with event: NSEvent) { sendTouch(.down, event) }
    override func mouseDragged(with event: NSEvent) { sendTouch(.move, event) }
    override func mouseUp(with event: NSEvent) { sendTouch(.up, event) }

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
        if let keycode = Self.specialKeys[event.keyCode] {
            session?.sendKey(.down, keycode: keycode)
        } else if let text = event.characters, !text.isEmpty, !event.modifierFlags.contains(.control) {
            session?.sendText(text)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let keycode = Self.specialKeys[event.keyCode] {
            session?.sendKey(.up, keycode: keycode)
        }
    }
}
