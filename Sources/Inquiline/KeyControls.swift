import AppKit
import Carbon

/// Keyboard, mouse and controller controls for a game made for touch, as Apple's Touch
/// Alternatives are for iPhone games on a Mac: each control stands for a button or stick on the
/// game's screen, and a key, the mouse or a controller works it by touching there. Positions are fractions of the app's screen,
/// so they stay put however large the window is. Saved for each app.
struct KeyControl: Codable, Equatable {
    enum Kind: String, Codable {
        /// A key, or a mouse button while aiming, holds a finger on one spot.
        case tap
        /// W, A, S and D push a finger around the middle of an on-screen stick.
        case stick
        /// While the pointer is caught, the mouse drags a finger here, as a thumb turns the
        /// camera in a shooter.
        case aim
        /// A key plays back touches recorded on the game: taps, holds and swipes, with the
        /// pauses they were recorded with.
        case macro
    }

    /// One finger's touch in a macro: where it lands, and, recorded as played, how long it stays
    /// down and where it slides meanwhile.
    struct Step: Codable, Equatable {
        var x: Double
        var y: Double
        /// Milliseconds after the step before touched down.
        var delay: Int
        /// Milliseconds the finger stays down; none for a quick tap.
        var hold: Int?
        /// Where the finger slides while down, each point a time after it touched down.
        var path: [PathPoint]?
        /// A key pressed to the app instead of a touch, as arrow keys in a game that takes the
        /// keyboard: held for `hold`. Its x and y mean nothing.
        var key: KeyStroke?
        /// A controller's whole state (an Xbox 360 report) sent to a game that takes
        /// controllers, instead of a touch. Its x and y mean nothing.
        var pad: [UInt8]?

        var isTouch: Bool { key == nil && pad == nil }

        func moved(dx: Double, dy: Double) -> Step {
            var step = self
            step.x += dx
            step.y += dy
            step.path = path?.map { PathPoint(x: $0.x + dx, y: $0.y + dy, t: $0.t) }
            return step
        }
    }

    /// A Mac key as the app got it.
    struct KeyStroke: Codable, Equatable {
        var code: Int
        var flags: UInt
        var characters: String?
        var plain: String?
    }

    struct PathPoint: Codable, Equatable {
        var x: Double
        var y: Double
        /// Milliseconds after the finger touched down.
        var t: Int
    }

    var kind: Kind
    var x: Double
    var y: Double
    /// A stick's reach, as a fraction of the screen's height.
    var size: Double = 0.12
    /// A tap's key: a Mac key code, or one of the mouse buttons below.
    var key: Int?
    var label: String?
    /// A macro's taps; its first is where the control is.
    var steps: [Step]?
    /// How a macro plays: once a press, over and over while held, or until pressed again.
    var repeats: Repeat?
    /// A macro's pause between taps in milliseconds, or nil for the pauses it was recorded with.
    /// Set by earlier versions; a macro now has a speed instead.
    var interval: Int?
    /// How fast a macro plays against how it was recorded: 2 is twice as fast.
    var speed: Double?

    enum Repeat: String, Codable {
        case once, whileHeld, untilPressedAgain
    }

    static let leftClick = 1000
    static let rightClick = 1001

    /// A controller's buttons, after the mouse's. Its left stick works the stick control and
    /// its right stick the aim control, as WASD and the mouse do.
    enum Pad: Int, CaseIterable {
        case a = 2000, b, x, y, leftShoulder, rightShoulder, leftTrigger, rightTrigger,
             leftStickButton, rightStickButton, menu, options, up, down, left, right

        var name: String {
            switch self {
            case .a: return "Ⓐ"
            case .b: return "Ⓑ"
            case .x: return "Ⓧ"
            case .y: return "Ⓨ"
            case .leftShoulder: return "LB"
            case .rightShoulder: return "RB"
            case .leftTrigger: return "LT"
            case .rightTrigger: return "RT"
            case .leftStickButton: return "L3"
            case .rightStickButton: return "R3"
            case .menu: return "☰"
            case .options: return "⧉"
            case .up: return "D-pad ↑"
            case .down: return "D-pad ↓"
            case .left: return "D-pad ←"
            case .right: return "D-pad →"
            }
        }
    }

    static func isPad(_ code: Int) -> Bool { Pad(rawValue: code) != nil }

    static let stickKeys: [(code: UInt16, dx: Double, dy: Double)] = [(13, 0, -1), (0, -1, 0), (1, 0, 1), (2, 1, 0)] // W A S D
}

struct KeyControlSet: Codable {
    var isOn = true
    var controls: [KeyControl] = []

    static func load(package: String) -> KeyControlSet {
        guard let data = UserDefaults.standard.data(forKey: key(package)),
              let set = try? JSONDecoder().decode(KeyControlSet.self, from: data) else { return KeyControlSet() }
        return set
    }

    func save(package: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(package)) }
    }

    private static func key(_ package: String) -> String { "KeyControls.\(package)" }

    var hasAim: Bool { controls.contains { $0.kind == .aim } }
    /// Controls made for a touch-only game, with an on-screen stick, aiming or a controller
    /// button, are what the controller works; the game then doesn't see it as a controller.
    var usesPad: Bool {
        isActive && controls.contains { $0.kind == .stick || $0.kind == .aim || $0.key.map(KeyControl.isPad) == true }
    }
    var isActive: Bool { isOn && !controls.isEmpty }
}

/// Plays the controls: turns keys and the mouse into fingers on the app's screen.
final class KeyControlPlayer {
    weak var view: AndroidDisplayView?
    var set = KeyControlSet()

    /// Fingers 0 and 1 are the trackpad's pinch; these follow.
    private static let stickFinger: Int64 = 2
    private static let aimFinger: Int64 = 3
    private static let firstTapFinger: Int64 = 4

    private var heldKeys = Set<Int>()
    private var stickDown = false
    private var aimPoint: CGPoint?
    private var aimStart = CGPoint.zero
    private var aimRest: DispatchWorkItem?
    /// When the aim's finger last landed, and the mouse's movement since, held back a frame.
    private var aimLanded: CFTimeInterval = 0
    private var aimPending = CGVector.zero
    private var aimFlush: DispatchWorkItem?
    private(set) var isCaught = false

    private var size: CGSize { view?.androidSize ?? CGSize(width: 1, height: 1) }

    private func point(_ control: KeyControl) -> CGPoint {
        CGPoint(x: control.x * size.width, y: control.y * size.height)
    }

    private func touch(_ action: ScrcpySession.TouchAction, _ p: CGPoint, finger: Int64) {
        view?.sendFinger(action, x: Int(p.x), y: Int(p.y), finger: finger)
    }

    /// Returns whether the key belongs to a control, which then keeps it from Android.
    func key(_ code: Int, down: Bool) -> Bool {
        guard set.isActive else { return false }
        let isStickKey = set.controls.contains { $0.kind == .stick } && KeyControl.stickKeys.contains { Int($0.code) == code }
        let taps = set.controls.enumerated().filter { $0.element.kind == .tap && $0.element.key == code }
        let macros = set.controls.filter { $0.kind == .macro && $0.key == code }
        guard isStickKey || !taps.isEmpty || !macros.isEmpty else { return false }
        if down {
            guard heldKeys.insert(code).inserted else { return true } // a key repeating
            for macro in macros {
                switch macro.repeats ?? .once {
                case .once: play(macro, round: nextRound(code), key: code)
                case .whileHeld: play(macro, round: nextRound(code), key: code, again: { [weak self] in self?.heldKeys.contains(code) == true })
                case .untilPressedAgain:
                    if looping.remove(code) != nil {
                        _ = nextRound(code) // ends the one playing
                    } else {
                        looping.insert(code)
                        play(macro, round: nextRound(code), key: code, again: { [weak self] in self?.looping.contains(code) == true })
                    }
                }
            }
        } else {
            heldKeys.remove(code)
        }
        for (index, control) in taps {
            touch(down ? .down : .up, point(control), finger: Self.firstTapFinger + Int64(index))
        }
        if isStickKey { moveStick() }
        return true
    }

    // MARK: - Controller

    /// The left stick, from -1 to 1 with down positive, pushes the stick control's finger as far
    /// as the stick is pushed.
    func padStick(x: Double, y: Double) {
        guard set.usesPad, let stick = set.controls.first(where: { $0.kind == .stick }) else { return }
        let center = point(stick)
        // A worn stick rests a little off the middle; within that, it's let go.
        guard (x * x + y * y).squareRoot() > Self.padRest else {
            if stickDown { touch(.up, stickPoint, finger: Self.stickFinger) }
            stickDown = false
            return
        }
        if !stickDown {
            touch(.down, center, finger: Self.stickFinger)
            stickDown = true
        }
        let reach = stick.size * size.height
        stickPoint = CGPoint(x: center.x + x * reach, y: center.y + y * reach)
        stickMoves += 1
        touch(.move, stickPoint, finger: Self.stickFinger)
    }

    /// The right stick turns the camera as a thumb drags across the screen, faster the further
    /// it's pushed, as in a console shooter.
    func padAim(x: Double, y: Double) {
        guard set.usesPad, set.hasAim else { return }
        padAimVector = (x * x + y * y).squareRoot() > Self.padRest ? CGPoint(x: x, y: y) : .zero
        guard padAimVector != .zero, padAimTimer == nil else { return }
        // Moves with the display's frames, as a thumb does.
        padAimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard padAimVector != .zero else {
                timer.invalidate()
                padAimTimer = nil
                liftAim()
                return
            }
            // At full tilt, six tenths of the screen's height a second.
            let speed = size.height * 0.6 / 60
            drag(dx: padAimVector.x * speed, dy: padAimVector.y * speed)
        }
    }

    /// How far from the middle a controller's stick counts as pushed.
    private static let padRest = 0.15
    private var padAimVector = CGPoint.zero
    private var padAimTimer: Timer?

    private func moveStick() {
        guard let stick = set.controls.first(where: { $0.kind == .stick }) else { return }
        var dx = 0.0, dy = 0.0
        for key in KeyControl.stickKeys where heldKeys.contains(Int(key.code)) {
            dx += key.dx
            dy += key.dy
        }
        let center = point(stick)
        stickMoves += 1
        guard dx != 0 || dy != 0 else {
            if stickDown { touch(.up, stickPoint, finger: Self.stickFinger) }
            stickDown = false
            return
        }
        let length = (dx * dx + dy * dy).squareRoot()
        let reach = stick.size * size.height
        let target = CGPoint(x: center.x + dx / length * reach, y: center.y + dy / length * reach)
        if !stickDown {
            // Down in the middle first, as a thumb lands on a stick before pushing it.
            touch(.down, center, finger: Self.stickFinger)
            stickDown = true
            stickPoint = center
        }
        // A thumb slides to where it pushes; games that ignore a finger jumping across their
        // stick follow a slide. Four steps, 8 ms apart.
        let from = stickPoint, move = stickMoves
        for step in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8 * step)) { [weak self] in
                guard let self, self.stickMoves == move, self.stickDown else { return }
                let t = CGFloat(step) / 4
                let p = CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)
                self.stickPoint = p
                self.touch(.move, p, finger: Self.stickFinger)
            }
        }
    }

    /// Plays a macro's touches as they were recorded, at its speed, and starts over while
    /// `again` says so. A newer round for the same key ends this one.
    private func play(_ macro: KeyControl, round: Int, key: Int, again: (() -> Bool)? = nil) {
        guard let steps = macro.steps, !steps.isEmpty else { return }
        let speed = max(min(macro.speed ?? 1, 8), 0.1)
        func later(_ ms: Double) -> DispatchTime { .now() + .milliseconds(Int(ms / speed)) }
        var at = 0.0, end = 0.0, usesPad = false
        defer {
            // The controller is put back as it is once the macro's last state has played.
            if usesPad, again == nil {
                DispatchQueue.main.asyncAfter(deadline: later(end + 20)) { [weak self] in
                    guard let self, rounds[key] == round else { return }
                    playPad?(nil)
                }
            }
        }
        for (index, step) in steps.enumerated() {
            if index > 0 { at += Double(macro.interval ?? step.delay) }
            let start = at
            if let report = step.pad {
                DispatchQueue.main.asyncAfter(deadline: later(start)) { [weak self] in
                    guard let self, rounds[key] == round else { return }
                    playPad?(report)
                }
                end = max(end, start)
                usesPad = true
                continue
            }
            if let stroke = step.key {
                let up = start + max(Double(step.hold ?? 0), 40 * speed)
                end = max(end, up)
                DispatchQueue.main.asyncAfter(deadline: later(start)) { [weak self] in
                    guard let self, rounds[key] == round else { return }
                    view?.replayKey(stroke, down: true)
                }
                DispatchQueue.main.asyncAfter(deadline: later(up)) { [weak self] in
                    self?.view?.replayKey(stroke, down: false)
                }
                continue
            }
            // Fingers in turn, so a quick touch can land before the last one lifts.
            let finger = Self.macroFinger + Int64(index % 4)
            let down = CGPoint(x: step.x * size.width, y: step.y * size.height)
            DispatchQueue.main.asyncAfter(deadline: later(start)) { [weak self] in
                guard let self, rounds[key] == round else { return }
                touch(.down, down, finger: finger)
            }
            var last = down
            for point in step.path ?? [] {
                let p = CGPoint(x: point.x * size.width, y: point.y * size.height)
                last = p
                DispatchQueue.main.asyncAfter(deadline: later(start + Double(point.t))) { [weak self] in
                    guard let self, rounds[key] == round else { return }
                    touch(.move, p, finger: finger)
                }
            }
            // A quick tap is held 40 ms, as a finger's is, whatever the speed.
            let up = start + max(Double(step.hold ?? 0), 40 * speed)
            end = max(end, up)
            let lift = last
            DispatchQueue.main.asyncAfter(deadline: later(up)) { [weak self] in
                self?.touch(.up, lift, finger: finger)
            }
        }
        guard let again else { return }
        // The next round once this one is done, after the same pause as between its touches.
        let pause = max(Double(macro.interval ?? steps.last?.delay ?? 100), 50)
        let restore = usesPad
        DispatchQueue.main.asyncAfter(deadline: later(end + pause)) { [weak self] in
            guard let self, rounds[key] == round else { return }
            guard again() else {
                if restore { playPad?(nil) }
                return
            }
            play(macro, round: round, key: key, again: again)
        }
    }

    /// Plays a recorded controller state on the plugged controllers (GamepadBridge), nil to put
    /// back their own.
    var playPad: (([UInt8]?) -> Void)?

    /// Plays a macro once from its settings, to try it while editing.
    func preview(_ macro: KeyControl) {
        let key = Self.previewKey
        play(macro, round: nextRound(key), key: key)
    }

    /// Stops a macro being tried.
    func stopPreview() {
        _ = nextRound(Self.previewKey)
    }

    private static let previewKey = -1

    private var rounds: [Int: Int] = [:]
    private var looping = Set<Int>()

    private func nextRound(_ key: Int) -> Int {
        let round = (rounds[key] ?? 0) + 1
        rounds[key] = round
        return round
    }

    private static let macroFinger: Int64 = 20
    private var stickPoint = CGPoint.zero
    private var stickMoves = 0

    // MARK: - Aiming with the mouse

    /// The key that starts and stops aiming, as Android emulators have one (BlueStacks' F1,
    /// Gameloop's ~): the aim control's own, or the key left of 1 (§ on ISO keyboards, ` on
    /// ANSI ones), which games rarely use. Not aiming, the mouse works the game's menus.
    var aimKey: Int {
        self.set.controls.first { $0.kind == .aim }?.key ?? Self.keyLeftOfOne
    }

    static var keyLeftOfOne: Int {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO ? kVK_ISO_Section : kVK_ANSI_Grave
    }

    func toggleAim() {
        freed = false
        if isCaught { releasePointer() } else { catchPointer() }
    }

    /// Option held while aiming frees the pointer for a moment, for a button on the game's
    /// screen, as Alt does in PC shooters; let go, aiming goes on.
    private var freed = false

    func freePointer(_ held: Bool) {
        if held, isCaught {
            freed = true
            releasePointer()
        } else if !held, freed {
            freed = false
            catchPointer()
        }
    }

    /// Whether Option frees the pointer now, so it isn't a key for the game.
    var isFreeingPointer: Bool { isCaught || freed }

    /// The pointer is caught, as Mac games do, so the mouse turns the camera without leaving
    /// the window. The aim key, Esc or switching away lets it go.
    func catchPointer() {
        guard set.isActive, set.hasAim, !isCaught else { return }
        isCaught = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        view?.showCaughtNote(true)
    }

    func releasePointer() {
        guard isCaught else { return }
        isCaught = false
        liftAim()
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        view?.showCaughtNote(false)
    }

    /// The mouse moved by this many points while caught. QtScrcpy's mouse look (Apache-2.0,
    /// inputconvertgame.cpp), with the Mac's own pointer lock rather than its cursor warping:
    /// a finger on the aim control follows the mouse, as far as the screen's edge, where it
    /// lifts and lands again; it lifts when the mouse rests. The same move turns as far in any
    /// window size, times the control's sensitivity (its speed).
    func aim(dx: CGFloat, dy: CGFloat) {
        guard isCaught, let control = set.controls.first(where: { $0.kind == .aim }) else { return }
        let scale = 1.5 * max(size.width, size.height) / 1600 * (control.speed ?? 1)
        drag(dx: dx * scale, dy: dy * scale)
    }

    /// Drags the aim control's finger by this many pixels of the app's screen.
    private func drag(dx: CGFloat, dy: CGFloat) {
        guard let control = set.controls.first(where: { $0.kind == .aim }) else { return }
        let now = CACurrentMediaTime()
        if aimPoint == nil {
            let start = point(control)
            touch(.down, start, finger: Self.aimFinger)
            aimPoint = start
            aimStart = start
            aimLanded = now
        }
        aimPending.dx += dx
        aimPending.dy += dy
        scheduleAimRest()
        // A finger that just landed waits a frame before it moves, so the game sees it land and
        // not a flick it might take for a tap (QtScrcpy skips the first moves).
        let settled = aimLanded + 0.034
        guard now >= settled else {
            if aimFlush == nil {
                let flush = DispatchWorkItem { [weak self] in
                    self?.aimFlush = nil
                    self?.drag(dx: 0, dy: 0)
                }
                aimFlush = flush
                DispatchQueue.main.asyncAfter(deadline: .now() + (settled - now), execute: flush)
            }
            return
        }
        guard var p = aimPoint else { return }
        p.x += aimPending.dx
        p.y += aimPending.dy
        aimPending = .zero
        // At the screen's edge the thumb lifts and starts again from the control.
        let margin = 0.05
        let edge = p.x < size.width * margin || p.x > size.width * (1 - margin)
            || p.y < size.height * margin || p.y > size.height * (1 - margin)
        p.x = min(max(p.x, 0), size.width - 1)
        p.y = min(max(p.y, 0), size.height - 1)
        touch(.move, p, finger: Self.aimFinger)
        aimPoint = p
        if edge { liftAim() }
    }

    /// The finger lifts once the mouse rests, so the control is free for the game's own use.
    private func scheduleAimRest() {
        aimRest?.cancel()
        let rest = DispatchWorkItem { [weak self] in self?.liftAim() }
        aimRest = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: rest)
    }

    private func liftAim() {
        aimRest?.cancel()
        aimFlush?.cancel()
        aimFlush = nil
        aimPending = .zero
        if let p = aimPoint { touch(.up, p, finger: Self.aimFinger) }
        aimPoint = nil
    }

    /// Lets go of everything, as when the window goes to the back.
    func releaseAll() {
        freed = false
        padAimVector = .zero
        padStick(x: 0, y: 0)
        looping.removeAll()
        rounds = rounds.mapValues { $0 + 1 }
        for code in heldKeys { _ = key(code, down: false) }
        heldKeys.removeAll()
        releasePointer()
    }
}

// MARK: - Key names

enum KeyName {
    static func of(_ event: NSEvent) -> String {
        if let name = names[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    static let names: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
        56: "⇧", 60: "⇧", 59: "⌃", 62: "⌃", 58: "⌥", 61: "⌥",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
    ]

    static func of(code: Int) -> String {
        switch code {
        case KeyControl.leftClick: return "Click"
        case KeyControl.rightClick: return "Right Click"
        default: return KeyControl.Pad(rawValue: code)?.name ?? names[UInt16(code)] ?? "?"
        }
    }
}
