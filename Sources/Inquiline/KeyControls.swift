import AppKit

/// Keyboard and mouse controls for a game made for touch, as Apple's Touch Alternatives are for
/// iPhone games on a Mac: each control stands for a button or stick on the game's screen, and
/// a key or the mouse works it by touching there. Positions are fractions of the app's screen,
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
    }

    var kind: Kind
    var x: Double
    var y: Double
    /// A stick's reach, as a fraction of the screen's height.
    var size: Double = 0.12
    /// A tap's key: a Mac key code, or one of the mouse buttons below.
    var key: Int?
    var label: String?

    static let leftClick = 1000
    static let rightClick = 1001

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
        guard isStickKey || !taps.isEmpty else { return false }
        if down {
            guard heldKeys.insert(code).inserted else { return true } // a key repeating
        } else {
            heldKeys.remove(code)
        }
        for (index, control) in taps {
            touch(down ? .down : .up, point(control), finger: Self.firstTapFinger + Int64(index))
        }
        if isStickKey { moveStick() }
        return true
    }

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

    private var stickPoint = CGPoint.zero
    private var stickMoves = 0

    // MARK: - Aiming with the mouse

    /// The pointer is caught, as Mac games do, so the mouse turns the camera without leaving
    /// the window. Esc or switching away lets it go.
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

    /// The mouse moved by this many points while caught.
    func aim(dx: CGFloat, dy: CGFloat) {
        guard isCaught, let control = set.controls.first(where: { $0.kind == .aim }) else { return }
        let start = point(control)
        if aimPoint == nil {
            touch(.down, start, finger: Self.aimFinger)
            aimPoint = start
            aimStart = start
        }
        guard var p = aimPoint else { return }
        // A point of mouse movement is a pixel of finger movement on the app's screen.
        p.x += dx * 1.5
        p.y += dy * 1.5
        touch(.move, p, finger: Self.aimFinger)
        aimPoint = p
        // A thumb runs out of screen and lifts to start again; so does this one.
        let limit = size.height * 0.25
        if abs(p.x - aimStart.x) > limit || abs(p.y - aimStart.y) > limit { liftAim() }
        aimRest?.cancel()
        let rest = DispatchWorkItem { [weak self] in self?.liftAim() }
        aimRest = rest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: rest)
    }

    private func liftAim() {
        aimRest?.cancel()
        if let p = aimPoint { touch(.up, p, finger: Self.aimFinger) }
        aimPoint = nil
    }

    /// Lets go of everything, as when the window goes to the back.
    func releaseAll() {
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
        default: return names[UInt16(code)] ?? "?"
        }
    }
}
