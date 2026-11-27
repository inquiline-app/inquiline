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

    /// What a controller's motion does in this app.
    enum Motion: String, CaseIterable {
        case off
        /// The controller is the phone, lying face up and looked down on: tilt games roll and steer by it.
        case phoneTilt
        /// The controller is a steering wheel, held flat or upright: turned, it moves the left stick
        /// side to side, as Steam Input's gyro steering does, so racing games keep every button.
        case steering

        var title: String {
            switch self {
            case .off: "Off"
            case .phoneTilt: "Phone Tilt"
            case .steering: "Steering"
            }
        }
    }

    var motion: Motion = .off {
        didSet {
            guard motion != oldValue else { return }
            // Out of Phone Tilt, the phone lies still and flat again, not tilted as it was left;
            // out of Steering, the stick goes back to the thumb alone.
            if oldValue == .phoneTilt { session.sendMotion(acceleration: [0, 0, 9.80665], rotation: [0, 0, 0]) }
            if oldValue == .steering {
                let turned = steering.keys
                steering = [:]
                for id in turned { if let state = pads.states[id] { changed(state, id: id) } }
            }
        }
    }

    /// A wrist turns a controller far more easily than hands tilt a phone: the phone Android
    /// sees leans this share of the controller's lean, the same way in every direction, as the
    /// player sets it (Sensitivity) for each app.
    var tiltShare: Float = 0.5

    /// Each controller's turn in Steering, -1 to 1, added to its left stick.
    private var steering: [UInt32: Double] = [:]

    /// The controller's turn from level, as its left stick: Sensitivity sets how far turns all
    /// the way, 35 degrees at the middle.
    private func steer(_ id: UInt32, up: [Float]) {
        // Turned right, its right side drops: up leans toward its left.
        let degrees = Double(atan2(-up[0], (up[1] * up[1] + up[2] * up[2]).squareRoot())) * 180 / .pi
        let lock = 17.5 / Double(tiltShare), dead = 1.5
        let turn = min(max(abs(degrees) - dead, 0) / (lock - dead), 1) * (degrees < 0 ? -1 : 1)
        let before = steering[id] ?? 0
        guard abs(turn - before) > 0.004 || (turn == 0) != (before == 0) else { return }
        steering[id] = turn
        if let state = pads.states[id] { changed(state, id: id) }
    }

    /// Up as the controller's accelerometer read it last, in the phone's axes.
    private var lastUp: [Float]?
    /// Up when the player chose level (Calibrate): the phone lies flat whenever the controller is
    /// held so, as a game's own calibration does.
    var level: [Float]? {
        didSet { leveling = level.map(Self.turn(from:)) }
    }
    private var leveling: [[Float]]?

    /// Takes the controller's pose now as level, and gives it to keep.
    func calibrate() -> [Float]? {
        level = lastUp
        return level
    }

    private func leveled(_ v: [Float]) -> [Float] {
        guard let m = leveling else { return v }
        return (0..<3).map { m[$0][0] * v[0] + m[$0][1] * v[1] + m[$0][2] * v[2] }
    }

    /// The shortest turn that brings `up` to straight up (Rodrigues' formula).
    private static func turn(from up: [Float]) -> [[Float]] {
        let length = (up[0] * up[0] + up[1] * up[1] + up[2] * up[2]).squareRoot()
        let identity: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        guard length > 0.001 else { return identity }
        let a = up.map { $0 / length }
        // Axis a × z and the angle between them.
        let (x, y) = (a[1], -a[0])
        let s = (x * x + y * y).squareRoot(), c = a[2]
        guard s > 1e-6 else { return c > 0 ? identity : [[1, 0, 0], [0, -1, 0], [0, 0, -1]] }
        let (kx, ky) = (x / s, y / s), t = 1 - c
        return [[c + kx * kx * t, kx * ky * t, ky * s],
                [kx * ky * t, c + ky * ky * t, -kx * s],
                [-ky * s, kx * s, c]]
    }

    /// Up as the accelerometer reads it, leaned `share` as far from lying flat.
    private static func gentler(_ up: [Float], share tiltShare: Float) -> [Float] {
        let length = (up[0] * up[0] + up[1] * up[1] + up[2] * up[2]).squareRoot()
        guard length > 0.001 else { return up }
        let lean = acos(max(min(up[2] / length, 1), -1)) * tiltShare
        let toward = atan2(up[1], up[0])
        return [length * sin(lean) * cos(toward), length * sin(lean) * sin(toward), length * cos(lean)]
    }

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
        // A controller's motion, while the app is in front: in Phone Tilt it moves the phone Android
        // thinks it is, about 100 times a second; in Steering it turns the left stick.
        var lastMotion = 0.0
        pads.onMotion = { [weak self] id, acceleration, rotation in
            guard let self, self.motion != .off, NSApp.isActive else { return }
            // Held as usual and looked down on, a controller is a phone lying face up: its far end
            // is the phone's top, its face the phone's screen.
            func phone(_ v: [Float]) -> [Float] { [v[0], -v[2], v[1]] }
            self.lastUp = phone(acceleration)
            if self.motion == .steering {
                self.steer(id, up: self.leveled(phone(acceleration)))
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastMotion >= 0.009 else { return }
            lastMotion = now
            let up = Self.gentler(self.leveled(phone(acceleration)), share: self.tiltShare)
            self.session.sendMotion(acceleration: up, rotation: self.leveled(phone(rotation)).map { $0 * self.tiltShare })
        }
        // A game's rumble, as hid-microsoft sends it to the Xbox controller Android has: report 3,
        // its strong and weak motors from 0 to 100. It reaches the controller in the player's hands.
        session.onHIDOutput = { [weak self] hid, report in
            guard report.count >= 9, report[0] == 0x03 else { return }
            let strong = Double(report[4]) / 100, weak = Double(report[5]) / 100
            DispatchQueue.main.async {
                guard let self, NSApp.isActive, let id = self.plugged.first(where: { $0.value == hid })?.key else { return }
                // Until the next report says otherwise: Android stops it with one of nothing.
                self.pads.rumble(id, low: strong, high: weak, ms: strong == 0 && weak == 0 ? 0 : 10_000)
                self.rumbling.insert(id)
            }
        }
        pads.start()
        update()
    }

    /// Controllers rumbling for this app, stopped when it goes to the back or closes.
    private var rumbling = Set<UInt32>()

    private func stopRumble() {
        for id in rumbling { pads.rumble(id, low: 0, high: 0, ms: 0) }
        rumbling = []
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
            session.sendHIDInput(id: hid, report: report.map(Self.current) ?? own)
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
        session.onHIDOutput = nil
        stopRumble()
    }

    /// Called again when the controls change, as they decide who gets the controller.
    func update() {
        if !NSApp.isActive { stopRumble() }
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
                Self.open(hid, on: session)
            }
            // Going to the back lets go of everything held; coming to the front picks up the pad as it is.
            let state = pads.states[id] ?? SDLGamepads.State()
            if let hid = plugged[id] { session.sendHIDInput(id: hid, report: NSApp.isActive ? Self.report(state) : Self.atRest) }
            if !NSApp.isActive { release(id) }
        }
    }

    private func changed(_ state: SDLGamepads.State, id: UInt32) {
        var state = state
        if let turn = steering[id] { state.leftX = min(max(state.leftX + turn, -1), 1) }
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
    private static let atRest = report(leftX: 0, leftY: 0, rightX: 0, rightY: 0, leftTrigger: 0, rightTrigger: 0, buttons: 0, hat: 0)

    /// Plugs the controller Android gets: an Xbox Wireless Controller on Bluetooth, as a phone
    /// has one. Android knows its buttons (Vendor_045e_Product_02fd.kl) and Linux's driver for
    /// it (hid-microsoft) gives Android its rumble, which comes back as output report 3.
    static func open(_ id: UInt16, on session: ScrcpySession) {
        session.sendHIDOpen(id: id, vendor: 0x045E, product: 0x02FD, name: "Xbox Wireless Controller",
                            descriptor: descriptor, bus: 0x05)
    }

    /// Its report 1, laid out as Android's key layout for it reads it: sticks X, Y, Z and Rz,
    /// triggers as brake and accelerator, a hat for the d-pad, 15 buttons and Back. Report 3 is
    /// rumble out: enable, four motors (triggers, strong, weak), duration, delay, loops.
    static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x01,
        0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
        0x15, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00, 0x75, 0x10, 0x95, 0x04, 0x81, 0x02,
        0x05, 0x02, 0x09, 0xC5, 0x09, 0xC4, 0x15, 0x00, 0x26, 0xFF, 0x03, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08, 0x35, 0x00, 0x46, 0x3B, 0x01, 0x66, 0x14, 0x00,
        0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
        0x15, 0x00, 0x25, 0x00, 0x35, 0x00, 0x45, 0x00, 0x65, 0x00, 0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x0F, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0F, 0x81, 0x02,
        0x75, 0x01, 0x95, 0x01, 0x81, 0x03,
        0x05, 0x0C, 0x0A, 0x24, 0x02, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,
        0x75, 0x07, 0x95, 0x01, 0x81, 0x03,
        0x85, 0x03, 0x06, 0x00, 0xFF, 0x09, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x08, 0x91, 0x02,
        0xC0,
    ]

    /// A report from values: sticks from -1 to 1 with down positive, triggers from 0 to 1, and
    /// buttons as Xbox's HID usages less one for bits (A 0, B 1, X 3, Y 4, LB 6, RB 7, Back 10,
    /// Menu 11, Guide 12, LS 13, RS 14); the hat clockwise from 1 at the top, 0 centered.
    static func report(leftX: Double, leftY: Double, rightX: Double, rightY: Double,
                       leftTrigger: Double, rightTrigger: Double, buttons: UInt16, hat: UInt8) -> [UInt8] {
        func stick(_ value: Double) -> UInt16 { UInt16(clamping: Int(32768 + min(max(value, -1), 1) * 32767)) }
        func trigger(_ value: Double) -> UInt16 { UInt16(clamping: Int(min(max(value, 0), 1) * 1023)) }
        var report: [UInt8] = [0x01]
        for value in [stick(leftX), stick(leftY), stick(rightX), stick(rightY), trigger(leftTrigger), trigger(rightTrigger)] {
            report += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        report.append(min(hat, 8))
        // Back is the consumer page's AC Back on this controller, not a button.
        let held = buttons & ~0x0400
        report += [UInt8(held & 0xFF), UInt8(held >> 8), buttons & 0x0400 != 0 ? 1 : 0]
        return report
    }

    /// A report macros recorded before, for the Xbox 360 pad Android got then, in today's.
    private static func current(_ report: [UInt8]) -> [UInt8] {
        guard report.count == 15 else { return report }
        func value(_ at: Int) -> Double { Double(UInt16(report[at]) | UInt16(report[at + 1]) << 8) }
        func stick(_ at: Int) -> Double { (value(at) - 32768) / 32767 }
        return Self.report(leftX: stick(0), leftY: stick(2), rightX: stick(4), rightY: stick(6),
                           leftTrigger: value(8) / 32767, rightTrigger: value(10) / 32767,
                           buttons: UInt16(report[12]) | UInt16(report[13]) << 8, hat: report[14])
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
