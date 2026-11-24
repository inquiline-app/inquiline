import AppKit

/// A macro's settings, shown beside it while editing controls (ControlsOverlay): its key, how it
/// plays, how fast, and buttons to try it, record it again or delete it. Every change applies
/// at once, as in the rest of Inquiline's settings.
final class MacroSettings: NSViewController, NSPopoverDelegate {
    private var macro: KeyControl
    var changed: ((KeyControl) -> Void)?
    var tryIt: (() -> Void)?
    var recordAgain: (() -> Void)?
    var remove: (() -> Void)?
    var closed: (() -> Void)?

    private let keyButton = KeyButton()
    private let plays = NSPopUpButton()
    private let speed = NSSlider()
    private let speedLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")

    /// Speeds the slider stops at.
    private static let speeds: [Double] = [0.5, 0.75, 1, 1.5, 2, 3, 4]
    private static let modes: [(String, KeyControl.Repeat)] = [
        ("Once", .once), ("While Held", .whileHeld), ("Until Pressed Again", .untilPressedAgain),
    ]

    init(macro: KeyControl) {
        self.macro = macro
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isChoosingKey: Bool { keyButton.isChoosing }

    /// A key or controller button chosen for the macro.
    func choose(key: Int, label: String) {
        keyButton.isChoosing = false
        macro.key = key
        macro.label = label
        update()
        changed?(macro)
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Macro")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: 11)

        keyButton.bezelStyle = .rounded
        keyButton.onKey = { [weak self] code, label in self?.choose(key: code, label: label) }
        keyButton.onCancel = { [weak self] in self?.update() }

        for (title, _) in Self.modes { plays.addItem(withTitle: title) }
        plays.target = self
        plays.action = #selector(playsChanged)

        speed.minValue = 0
        speed.maxValue = Double(Self.speeds.count - 1)
        speed.numberOfTickMarks = Self.speeds.count
        speed.allowsTickMarkValuesOnly = true
        speed.target = self
        speed.action = #selector(speedChanged)
        speed.widthAnchor.constraint(equalToConstant: 150).isActive = true
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        speedLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        let grid = NSGridView(views: [
            [label("Key:"), keyButton],
            [label("Plays:"), plays],
            [label("Speed:"), NSStackView(views: [speed, speedLabel])],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                                  target: self, action: action)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            return button
        }
        let delete = button("Delete", "trash", #selector(deleteTapped))
        delete.contentTintColor = .systemRed
        let buttons = NSStackView(views: [button("Try", "play.fill", #selector(tryTapped)),
                                          button("Record Again", "record.circle", #selector(recordTapped)), delete])
        buttons.spacing = 8

        let stack = NSStackView(views: [NSStackView(views: [title, summary]), grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view = stack
        update()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // A new macro asks for its key first.
        if macro.key == nil { keyButton.beginChoosing() }
    }

    private func update() {
        keyButton.title = macro.key == nil ? "Choose a Key…" : (macro.label ?? "Key")
        plays.selectItem(at: Self.modes.firstIndex { $0.1 == (macro.repeats ?? .once) } ?? 0)
        let current = macro.speed ?? 1
        let stop = Self.speeds.indices.min { abs(Self.speeds[$0] - current) < abs(Self.speeds[$1] - current) } ?? 2
        speed.doubleValue = Double(stop)
        speedLabel.stringValue = Self.format(Self.speeds[stop])
        let steps = macro.steps ?? []
        let length = steps.reduce(0) { $0 + $1.delay } + (steps.last?.hold ?? 40)
        let seconds = Double(length) / 1000 / current
        let touches = steps.filter(\.isTouch).count, keys = steps.filter { $0.key != nil }.count
        let pad = steps.contains { $0.pad != nil }
        var parts: [String] = []
        if touches > 0 { parts.append("\(touches) touch\(touches == 1 ? "" : "es")") }
        if keys > 0 { parts.append("\(keys) key\(keys == 1 ? "" : "s")") }
        if pad { parts.append("controller") }
        parts.append(String(format: "%.1f s", seconds))
        summary.stringValue = parts.joined(separator: ", ")
    }

    private static func format(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
    }

    @objc private func playsChanged() {
        macro.repeats = Self.modes[plays.indexOfSelectedItem].1
        changed?(macro)
    }

    @objc private func speedChanged() {
        macro.speed = Self.speeds[Int(speed.doubleValue.rounded())]
        // A pause set by an earlier version gives way to the recorded timing at this speed.
        macro.interval = nil
        update()
        changed?(macro)
    }

    @objc private func tryTapped() { tryIt?() }
    @objc private func recordTapped() { recordAgain?() }
    @objc private func deleteTapped() { remove?() }

    func popoverDidClose(_ notification: Notification) {
        keyButton.isChoosing = false
        closed?()
    }
}

/// A button that takes the next key pressed, as macOS's keyboard shortcut fields do.
final class KeyButton: NSButton {
    var onKey: ((Int, String) -> Void)?
    var onCancel: (() -> Void)?
    var isChoosing = false

    override var acceptsFirstResponder: Bool { true }

    func beginChoosing() {
        isChoosing = true
        title = "Press a key or controller button…"
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        beginChoosing()
    }

    override func keyDown(with event: NSEvent) {
        guard isChoosing else { return super.keyDown(with: event) }
        if event.keyCode == 53 { // Esc: as it was
            isChoosing = false
            onCancel?()
            return
        }
        onKey?(Int(event.keyCode), KeyName.of(event))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isChoosing, [56, 60, 59, 62, 58, 61].contains(event.keyCode),
              !event.modifierFlags.intersection([.shift, .control, .option]).isEmpty else { return }
        onKey?(Int(event.keyCode), KeyName.of(event))
    }
}
