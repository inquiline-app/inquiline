import AppKit

/// Game controllers connected to the Mac reach the Android app as Xbox 360 pads plugged
/// into it, so games that support controllers use them as on a phone. As a keyboard does,
/// they stay plugged in while the app runs and drive the app in front: when another app is,
/// this one sees them at rest, with nothing pressed.
///
/// A game made only for touch gets its controller through the app's controls instead
/// (KeyControls): once they have an on-screen stick, aiming or a controller button, the
/// controller works them, and the game sees no controller.
final class GamepadBridge {
    private let session: ScrcpySession
    private weak var controls: KeyControlPlayer?
    /// While the controls are being edited, a button pressed is offered here; true takes it.
    var onEditPress: ((Int) -> Bool)?
    /// Told of each state a plugged controller sends the app, while a macro records.
    var reportObserver: (([UInt8]) -> Void)?
    private var held: [UInt32: Set<Int>] = [:]
    /// The HID id each controller has in Android, by its SDL id. scrcpy keeps 1 and 2 for a
    /// keyboard and mouse.
    private var plugged: [UInt32: UInt16] = [:]
    private var observers: [NSObjectProtocol] = []
    private let pads = SDLGamepads.shared

    init(session: ScrcpySession, controls: KeyControlPlayer) {
        self.session = session
        self.controls = controls
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: SDLGamepads.didChange, object: nil, queue: .main) { [weak self] _ in self?.update() },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.update() },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.update() },
        ]
        pads.onState = { [weak self] id, state in
            guard let self, NSApp.isActive else { return }
            self.changed(state, id: id)
        }
        // A controller's motion moves the phone Android thinks it is, while the app is in front:
        // games steer and aim by tilting, about 100 times a second.
        var lastMotion = 0.0
        pads.onMotion = { [weak self] _, acceleration, rotation in
            guard let self, NSApp.isActive else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastMotion >= 0.009 else { return }
            lastMotion = now
            self.session.sendMotion(acceleration: acceleration, rotation: rotation)
        }
        pads.start()
        update()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Plays a controller state a macro recorded on the plugged controllers, or with nil, puts
    /// back the controllers' own. Returns whether one is plugged to play it on.
    @discardableResult
    func replay(_ report: [UInt8]?) -> Bool {
        guard !plugged.isEmpty else { return false }
        for (id, hid) in plugged {
            let own = pads.states[id].map { NSApp.isActive ? Self.report($0) : Self.atRest } ?? Self.atRest
            session.sendHIDInput(id: hid, report: report ?? own)
        }
        return true
    }

    /// Unplugs every controller, as when the app's window closes.
    func stop() {
        for (_, hid) in plugged { session.sendHIDClose(id: hid) }
        plugged = [:]
        for id in held.keys { release(id) }
        pads.onState = nil
        pads.onMotion = nil
    }

    /// Called again when the controls change, as they decide who gets the controller.
    func update() {
        let wanted = pads.ids
        let usesPad = controls?.set.usesPad == true
        for (id, hid) in plugged where !wanted.contains(id) || usesPad {
            session.sendHIDClose(id: hid)
            plugged[id] = nil
        }
        for id in wanted {
            if !usesPad, plugged[id] == nil,
               let hid = (3...10).map(UInt16.init).first(where: { !plugged.values.contains($0) }) {
                plugged[id] = hid
                session.sendHIDOpen(id: hid, vendor: 0x045E, product: 0x028E, name: "Microsoft X-Box 360 Pad",
                                    descriptor: Self.descriptor)
            }
            // Going to the back lets go of everything held; coming to the front picks up the pad as it is.
            let state = pads.states[id] ?? SDLGamepads.State()
            if let hid = plugged[id] { session.sendHIDInput(id: hid, report: NSApp.isActive ? Self.report(state) : Self.atRest) }
            if !NSApp.isActive { release(id) }
        }
    }

    private func changed(_ state: SDLGamepads.State, id: UInt32) {
        let pressed = Self.pressed(state)
        let before = held[id] ?? []
        held[id] = pressed
        // A button pressed while the controls are edited is given to the chosen control.
        if let onEditPress {
            for code in pressed.subtracting(before) where onEditPress(code) { return }
        }
        if let hid = plugged[id] {
            let report = Self.report(state)
            session.sendHIDInput(id: hid, report: report)
            reportObserver?(report)
            return
        }
        guard let controls, controls.set.usesPad else { return }
        for code in pressed.subtracting(before) { _ = controls.key(code, down: true) }
        for code in before.subtracting(pressed) { _ = controls.key(code, down: false) }
        controls.padStick(x: state.leftX, y: state.leftY)
        controls.padAim(x: state.rightX, y: state.rightY)
    }

    private func release(_ id: UInt32) {
        guard let controls, let before = held[id] else { return }
        held[id] = []
        for code in before { _ = controls.key(code, down: false) }
        controls.padStick(x: 0, y: 0)
        controls.padAim(x: 0, y: 0)
    }

    /// The controller's buttons held now, as control codes. A trigger counts once it's half in.
    private static func pressed(_ state: SDLGamepads.State) -> Set<Int> {
        typealias Pad = KeyControl.Pad
        var codes = Set<Int>()
        let buttons: [(Bool, Pad)] = [
            (state.south, .a), (state.east, .b), (state.west, .x), (state.north, .y),
            (state.leftShoulder, .leftShoulder), (state.rightShoulder, .rightShoulder),
            (state.leftStick, .leftStickButton), (state.rightStick, .rightStickButton),
            (state.start, .menu), (state.back, .options),
            (state.up, .up), (state.down, .down), (state.left, .left), (state.right, .right),
        ]
        for (down, code) in buttons where down { codes.insert(code.rawValue) }
        if state.leftTrigger > 0.5 { codes.insert(Pad.leftTrigger.rawValue) }
        if state.rightTrigger > 0.5 { codes.insert(Pad.rightTrigger.rawValue) }
        return codes
    }

    /// A report with both sticks centered and nothing pressed.
    private static let atRest: [UInt8] = {
        var report: [UInt8] = []
        for value: UInt16 in [32768, 32768, 32768, 32768, 0, 0, 0] {
            report += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        report.append(0)
        return report
    }()

    /// scrcpy's gamepad report (app/src/hid/hid_gamepad.c): four 16-bit stick axes, two
    /// triggers, 16 buttons and a hat switch for the d-pad.
    static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0xA1, 0x00,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34,
        0x15, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00, 0x75, 0x10, 0x95, 0x04, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01, 0x95, 0x10, 0x75, 0x01, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
        0xC0, 0xC0,
    ]

    /// A report from values: sticks from -1 to 1 with down positive, triggers from 0 to 1.
    static func report(leftX: Double, leftY: Double, rightX: Double, rightY: Double,
                       leftTrigger: Double, rightTrigger: Double, buttons: UInt16, hat: UInt8) -> [UInt8] {
        func stick(_ value: Double) -> UInt16 { UInt16(clamping: Int(32768 + min(max(value, -1), 1) * 32767)) }
        func trigger(_ value: Double) -> UInt16 { UInt16(clamping: Int(min(max(value, 0), 1) * 32767)) }
        var report: [UInt8] = []
        for value in [stick(leftX), stick(leftY), stick(rightX), stick(rightY), trigger(leftTrigger), trigger(rightTrigger), buttons] {
            report += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        report.append(min(hat, 8))
        return report
    }

    private static func report(_ state: SDLGamepads.State) -> [UInt8] {
        var buttons: UInt16 = 0
        let bits: [(Bool, UInt16)] = [
            (state.south, 0x0001), (state.east, 0x0002), (state.west, 0x0008), (state.north, 0x0010),
            (state.leftShoulder, 0x0040), (state.rightShoulder, 0x0080), (state.back, 0x0400),
            (state.start, 0x0800), (state.guide, 0x1000),
            (state.leftStick, 0x2000), (state.rightStick, 0x4000),
        ]
        for (down, bit) in bits where down { buttons |= bit }
        // The hat counts clockwise from 1 at the top; 0 is centered.
        let hat: UInt8 = state.up ? (state.right ? 2 : state.left ? 8 : 1) : state.down ? (state.right ? 4 : state.left ? 6 : 5)
            : state.right ? 3 : state.left ? 7 : 0
        return report(leftX: state.leftX, leftY: state.leftY, rightX: state.rightX, rightY: state.rightY,
                      leftTrigger: state.leftTrigger, rightTrigger: state.rightTrigger, buttons: buttons, hat: hat)
    }
}
