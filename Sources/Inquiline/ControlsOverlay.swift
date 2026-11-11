import AppKit

/// Drawn over the app's screen: the controls' keys, faintly while playing if asked, and in
/// full while editing them. Editing works as placing stickers: click where a button is and
/// press its key; drag one to move it; Delete removes it.
final class ControlsOverlay: NSView {
    var set = KeyControlSet() {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Where the app's screen is, in this view.
    var screenRect: () -> NSRect = { .zero }
    var onDone: ((KeyControlSet) -> Void)?

    private(set) var isEditing = false
    var showsLabels = false { didSet { needsDisplay = true } }
    private var selected: Int?
    private var dragging: (index: Int, offset: CGPoint)?
    /// The stick being made larger or smaller by its rim.
    private var resizing: Int?
    /// A macro being recorded: first its key, then its taps.
    private var recording: (index: Int, hasKey: Bool, last: Date?)?
    private let hint = NSTextField(labelWithString: "")
    private static let editHint = "Click a button in the game, then press its key."
    private let bar = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        buildBar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEditing }

    /// Lets clicks through to the app unless editing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditing ? super.hitTest(point) : nil
    }

    func beginEditing() {
        isEditing = true
        selected = nil
        bar.isHidden = false
        isHidden = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func endEditing() {
        finishRecording()
        isEditing = false
        selected = nil
        bar.isHidden = true
        set.controls.removeAll { $0.kind == .tap && $0.key == nil }
        needsDisplay = true
        onDone?(set)
    }

    // MARK: - Bar

    private func buildBar() {
        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                                  target: self, action: action)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            return button
        }
        let done = button("Done", "checkmark", #selector(done))
        done.keyEquivalent = "\r"
        hint.stringValue = Self.editHint
        hint.textColor = .secondaryLabelColor
        for view in [hint, button("Move Stick (WASD)", "dpad", #selector(addStick)),
                     button("Mouse Aim", "scope", #selector(addAim)),
                     button("Macro", "list.number", #selector(addMacro)),
                     button("Clear", "trash", #selector(clearAll)), done] as [NSView] {
            bar.addArrangedSubview(view)
        }
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        bar.layer?.cornerRadius = 12
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    @objc private func done() {
        if recording != nil { finishRecording() } else { endEditing() }
    }

    // MARK: - Macros

    @objc private func addMacro() {
        finishRecording()
        set.controls.append(KeyControl(kind: .macro, x: 0.5, y: 0.5, steps: []))
        recording = (set.controls.count - 1, false, nil)
        selected = recording!.index
        hint.stringValue = "Press the key for this macro."
        needsDisplay = true
    }

    private func finishRecording() {
        guard let recording else { return }
        self.recording = nil
        hint.stringValue = Self.editHint
        if recording.index < set.controls.count,
           set.controls[recording.index].key == nil || (set.controls[recording.index].steps ?? []).isEmpty {
            set.controls.remove(at: recording.index)
            selected = nil
        }
        needsDisplay = true
    }

    private func cancelRecording() {
        guard let recording else { return }
        if recording.index < set.controls.count { set.controls[recording.index].steps = [] }
        finishRecording()
    }

    @objc private func addStick() {
        if let index = set.controls.firstIndex(where: { $0.kind == .stick }) {
            selected = index
        } else {
            set.controls.append(KeyControl(kind: .stick, x: 0.18, y: 0.7))
            selected = set.controls.count - 1
        }
        needsDisplay = true
    }

    @objc private func addAim() {
        if let index = set.controls.firstIndex(where: { $0.kind == .aim }) {
            selected = index
        } else {
            set.controls.append(KeyControl(kind: .aim, x: 0.65, y: 0.45))
            selected = set.controls.count - 1
        }
        needsDisplay = true
    }

    @objc private func clearAll() {
        set.controls.removeAll()
        selected = nil
        needsDisplay = true
    }

    // MARK: - Geometry

    private func viewPoint(_ control: KeyControl) -> CGPoint {
        let rect = screenRect()
        // The screen rect is in the display view's bottom-left coordinates; this view is flipped.
        return CGPoint(x: rect.minX + control.x * rect.width, y: bounds.height - rect.maxY + control.y * rect.height)
    }

    private func fraction(_ point: CGPoint) -> (Double, Double) {
        let rect = screenRect()
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - (bounds.height - rect.maxY)) / rect.height
        return (min(max(x, 0.02), 0.98), min(max(y, 0.02), 0.98))
    }

    private func radius(_ control: KeyControl) -> CGFloat {
        switch control.kind {
        case .tap: return 22
        case .aim: return 30
        case .stick: return max(30, control.size * screenRect().height)
        case .macro: return 14
        }
    }

    private func control(at point: CGPoint) -> Int? {
        if let index = set.controls.indices.reversed().first(where: { index in
            set.controls[index].kind == .macro && (set.controls[index].steps ?? []).contains { step in
                let c = viewPoint(KeyControl(kind: .macro, x: step.x, y: step.y))
                return hypot(point.x - c.x, point.y - c.y) <= 14
            }
        }) { return index }
        return set.controls.indices.reversed().first {
            let c = viewPoint(set.controls[$0])
            return hypot(point.x - c.x, point.y - c.y) <= radius(set.controls[$0])
        }
    }

    // MARK: - Editing

    /// The stick whose rim is under the pointer, where it's taken to resize it.
    private func stickRim(at point: CGPoint) -> Int? {
        set.controls.indices.first { index in
            guard set.controls[index].kind == .stick else { return false }
            let c = viewPoint(set.controls[index])
            return abs(hypot(point.x - c.x, point.y - c.y) - radius(set.controls[index])) <= 8
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let current = recording {
            guard current.hasKey, screenRect().contains(CGPoint(x: point.x, y: bounds.height - point.y)) else { return }
            let now = Date()
            let delay = current.last.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
            let (x, y) = fraction(point)
            set.controls[current.index].steps?.append(KeyControl.Step(x: x, y: y, delay: min(delay, 5000)))
            if set.controls[current.index].steps?.count == 1 {
                set.controls[current.index].x = x
                set.controls[current.index].y = y
            }
            recording = (current.index, true, now)
            needsDisplay = true
            return
        }
        if let index = stickRim(at: point) {
            selected = index
            resizing = index
        } else if let index = control(at: point) {
            selected = index
            let c = viewPoint(set.controls[index])
            dragging = (index, CGPoint(x: point.x - c.x, y: point.y - c.y))
        } else if screenRect().contains(CGPoint(x: point.x, y: bounds.height - point.y)) {
            set.controls.removeAll { $0.kind == .tap && $0.key == nil }
            let (x, y) = fraction(point)
            set.controls.append(KeyControl(kind: .tap, x: x, y: y))
            selected = set.controls.count - 1
            dragging = (selected!, .zero)
        } else {
            selected = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let resizing, resizing < set.controls.count {
            let c = viewPoint(set.controls[resizing])
            set.controls[resizing].size = min(max(hypot(point.x - c.x, point.y - c.y) / screenRect().height, 0.05), 0.4)
            needsDisplay = true
            return
        }
        guard let dragging, dragging.index < set.controls.count else { return }
        let (x, y) = fraction(CGPoint(x: point.x - dragging.offset.x, y: point.y - dragging.offset.y))
        if set.controls[dragging.index].kind == .macro, let steps = set.controls[dragging.index].steps {
            // A macro moves whole.
            let dx = x - set.controls[dragging.index].x, dy = y - set.controls[dragging.index].y
            set.controls[dragging.index].steps = steps.map { KeyControl.Step(x: $0.x + dx, y: $0.y + dy, delay: $0.delay) }
        }
        set.controls[dragging.index].x = x
        set.controls[dragging.index].y = y
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        resizing = nil
    }

    /// The rim of a stick shows it can be resized, as a window's edge does.
    override func resetCursorRects() {
        guard isEditing else { return }
        for control in set.controls where control.kind == .stick {
            let c = viewPoint(control), r = radius(control)
            addCursorRect(NSRect(x: c.x + r - 8, y: c.y - 8, width: 16, height: 16), cursor: .resizeLeftRight)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = control(at: point) else { return }
        selected = index
        needsDisplay = true
        let menu = NSMenu()
        if set.controls[index].kind == .tap {
            menu.addItem(withTitle: "Use Click (While Aiming)", action: #selector(useClick), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Use Right Click (While Aiming)", action: #selector(useRightClick), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Remove", action: #selector(removeSelected), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func useClick() { assign(KeyControl.leftClick, KeyName.of(code: KeyControl.leftClick)) }
    @objc private func useRightClick() { assign(KeyControl.rightClick, KeyName.of(code: KeyControl.rightClick)) }

    @objc private func removeSelected() {
        guard let selected, selected < set.controls.count else { return }
        set.controls.remove(at: selected)
        self.selected = nil
        needsDisplay = true
    }

    private func assign(_ code: Int, _ label: String) {
        guard let selected, selected < set.controls.count, set.controls[selected].kind == .tap else { return }
        // A key works one button; giving it to another takes it from the first.
        for index in set.controls.indices where index != selected && set.controls[index].key == code {
            set.controls[index].key = nil
        }
        set.controls[selected].key = code
        set.controls[selected].label = label
        set.controls.removeAll { $0.kind == .tap && $0.key == nil }
        self.selected = set.controls.firstIndex { $0.key == code }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if let current = recording {
            switch event.keyCode {
            case 53: cancelRecording() // Esc
            case 36, 76: finishRecording() // Return
            default:
                guard !current.hasKey else { return }
                let code = Int(event.keyCode)
                // A key works one control; giving it to the macro takes it from the others.
                for index in set.controls.indices where index != current.index && set.controls[index].key == code {
                    set.controls[index].key = nil
                }
                set.controls[current.index].key = code
                set.controls[current.index].label = KeyName.of(event)
                recording = (current.index, true, nil)
                hint.stringValue = "Click where it taps, in order. Return when done."
                needsDisplay = true
            }
            return
        }
        switch event.keyCode {
        case 53: endEditing() // Esc
        case 51, 117: // Delete
            if let selected, set.controls[selected].kind != .tap || set.controls[selected].key != nil { removeSelected() }
            else { assign(Int(event.keyCode), KeyName.of(event)) }
        default:
            assign(Int(event.keyCode), KeyName.of(event))
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard [56, 60, 59, 62, 58, 61].contains(event.keyCode), !event.modifierFlags.intersection([.shift, .control, .option]).isEmpty
        else { return }
        assign(Int(event.keyCode), KeyName.of(event))
    }

    /// A pinch or scroll over the stick changes how far it reaches.
    override func scrollWheel(with event: NSEvent) {
        guard let selected, selected < set.controls.count, set.controls[selected].kind == .stick else { return }
        set.controls[selected].size = min(max(set.controls[selected].size - Double(event.scrollingDeltaY) * 0.002, 0.05), 0.3)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let selected, selected < set.controls.count, set.controls[selected].kind == .stick else { return }
        set.controls[selected].size = min(max(set.controls[selected].size * (1 + event.magnification), 0.05), 0.3)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isEditing || showsLabels else { return }
        if isEditing {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
        }
        let alpha: CGFloat = isEditing ? 1 : 0.55
        for (index, control) in set.controls.enumerated() {
            let c = viewPoint(control), r = radius(control)
            let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            NSColor.black.withAlphaComponent(0.45 * alpha).setFill()
            circle.fill()
            (index == selected && isEditing ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.8 * alpha)).setStroke()
            circle.lineWidth = index == selected && isEditing ? 3 : 1.5
            circle.stroke()
            switch control.kind {
            case .tap:
                text(control.label ?? "Press a key", at: c, size: control.label == nil ? 10 : 13, alpha: alpha)
            case .aim:
                text("Mouse", at: c, size: 11, alpha: alpha)
            case .macro:
                // Numbered dots joined in their order; the key on the first.
                let points = (control.steps ?? []).map { viewPoint(KeyControl(kind: .macro, x: $0.x, y: $0.y)) }
                let path = NSBezierPath()
                for (n, p) in points.enumerated() { if n == 0 { path.move(to: p) } else { path.line(to: p) } }
                NSColor.white.withAlphaComponent(0.6 * alpha).setStroke()
                path.lineWidth = 2
                path.setLineDash([4, 3], count: 2, phase: 0)
                path.stroke()
                for (n, p) in points.enumerated() where n > 0 {
                    let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
                    NSColor.black.withAlphaComponent(0.45 * alpha).setFill()
                    dot.fill()
                    NSColor.white.withAlphaComponent(0.8 * alpha).setStroke()
                    dot.lineWidth = 1.5
                    dot.stroke()
                    text("\(n + 1)", at: p, size: 11, alpha: alpha)
                }
                text(control.label.map { points.isEmpty ? $0 : $0 + " 1" } ?? "Key?", at: c, size: 11, alpha: alpha)
            case .stick:
                text("W", at: CGPoint(x: c.x, y: c.y - r + 12), size: 13, alpha: alpha)
                text("S", at: CGPoint(x: c.x, y: c.y + r - 12), size: 13, alpha: alpha)
                text("A", at: CGPoint(x: c.x - r + 12, y: c.y), size: 13, alpha: alpha)
                text("D", at: CGPoint(x: c.x + r - 12, y: c.y), size: 13, alpha: alpha)
                if isEditing {
                    // A knob on its rim, to pull it larger or smaller.
                    let knob = NSBezierPath(ovalIn: NSRect(x: c.x + r - 6, y: c.y - 6, width: 12, height: 12))
                    NSColor.controlAccentColor.setFill()
                    knob.fill()
                    NSColor.white.setStroke()
                    knob.lineWidth = 2
                    knob.stroke()
                }
            }
        }
    }

    private func text(_ string: String, at point: CGPoint, size: CGFloat, alpha: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let text = NSAttributedString(string: string, attributes: attributes)
        let s = text.size()
        text.draw(at: CGPoint(x: point.x - s.width / 2, y: point.y - s.height / 2))
    }
}
