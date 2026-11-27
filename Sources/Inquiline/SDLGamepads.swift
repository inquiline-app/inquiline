import CSDL
import Foundation

/// Every game controller on the Mac, read through SDL (Scripts/build-sdl.sh), as Steam and most
/// emulators read them: its own drivers speak PlayStation, Xbox and Switch controllers and their
/// copies (a copy's broken calibration included), its database maps thousands of others, and
/// every one comes out as the same gamepad. So a game in Android sees one kind of controller,
/// whatever is in the player's hands, made or certified by anyone or no one.
///
/// Only Inquiline itself opens them (`startHub`), as Steam does for every game: two programs
/// talking to one controller at once undo each other's setup and rumble, and its gyro is
/// calibrated once. The apps' windows (`start`) get its controllers, their states and motion over
/// a socket in the controllers folder, and send it their rumble.
final class SDLGamepads {
    static let shared = SDLGamepads()
    /// Posted on the main thread when a controller comes or goes.
    static let didChange = Notification.Name("InquilineSDLGamepadsChanged")

    /// A controller's state, as SDL normalizes it.
    struct State: Equatable {
        /// Sticks from -1 to 1, down positive; triggers from 0 to 1.
        var leftX = 0.0, leftY = 0.0, rightX = 0.0, rightY = 0.0, leftTrigger = 0.0, rightTrigger = 0.0
        var south = false, east = false, west = false, north = false
        var leftShoulder = false, rightShoulder = false, leftStick = false, rightStick = false
        var back = false, start = false, guide = false
        var up = false, down = false, left = false, right = false

        init() {}

        private var flags: [Bool] {
            [south, east, west, north, leftShoulder, rightShoulder, leftStick, rightStick, back, start, guide, up, down, left, right]
        }

        /// The buttons, one bit each, in `flags`' order.
        var buttons: UInt32 {
            flags.enumerated().reduce(0) { $1.element ? $0 | 1 << UInt32($1.offset) : $0 }
        }

        init(axes: [Double], buttons: UInt32) {
            (leftX, leftY, rightX, rightY, leftTrigger, rightTrigger) = (axes[0], axes[1], axes[2], axes[3], axes[4], axes[5])
            func bit(_ n: UInt32) -> Bool { buttons & 1 << n != 0 }
            (south, east, west, north) = (bit(0), bit(1), bit(2), bit(3))
            (leftShoulder, rightShoulder, leftStick, rightStick) = (bit(4), bit(5), bit(6), bit(7))
            (back, start, guide) = (bit(8), bit(9), bit(10))
            (up, down, left, right) = (bit(11), bit(12), bit(13), bit(14))
        }
    }

    /// Called on the main thread, in a window, with a controller whose state changed.
    var onState: ((_ id: UInt32, _ state: State) -> Void)?
    /// Called on the main thread, in a window, with a controller's motion, as Android's sensors report it:
    /// gravity in m/s², up as an accelerometer at rest reads it, followed by the gyro and the
    /// accelerometer together so a hand's shake and jolts don't move it, and rotation in rad/s
    /// with its gyro's bias taken away (GamepadMotionHelpers), in SDL's axes.
    var onMotion: ((_ id: UInt32, _ acceleration: [Float], _ rotation: [Float]) -> Void)?
    /// Each controller with motion sensors: its calibration, latest acceleration and last time.
    private var motion: [UInt32: (calibration: OpaquePointer, acceleration: [Float], time: UInt64)] = [:]
    private(set) var states: [UInt32: State] = [:]
    private var pads: [UInt32: OpaquePointer] = [:]
    private var timer: Timer?

    private init() {}

    var ids: [UInt32] { states.keys.sorted() }

    // MARK: The socket between Inquiline and the windows

    private static var folder: URL { AndroidRuntime.shared.home.appendingPathComponent("controllers") }
    private static var hubPath: String { folder.appendingPathComponent("hub").path }
    /// Messages, little-endian. Inquiline to a window: 1 the controllers (count, ids), 2 a state
    /// (id, six axes as floats, buttons as bits), 3 motion (id, up then rotation as six floats).
    /// A window to Inquiline: 5 hello, every two seconds while it runs, 4 rumble (id, low and
    /// high as floats, milliseconds).
    private enum Message: UInt8 { case controllers = 1, state, motion, rumble, hello }
    private var socket: Int32 = -1
    private var reader: DispatchSourceRead?
    private var isHub = false
    /// The windows that said hello, and when they last did.
    private var windows: [String: TimeInterval] = [:]
    private var keepAlive: Timer?

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// A datagram socket of this process's own at `path`, read on the main thread.
    private func listen(at path: String) -> Bool {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        guard var address = Self.address(path) else { return false }
        socket = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socket >= 0 else { return false }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(socket); socket = -1; return false }
        var size: Int32 = 1 << 18
        setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let reader = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        reader.setEventHandler { [weak self] in self?.receive() }
        reader.resume()
        self.reader = reader
        return true
    }

    /// Returns false once nothing listens at `path` any more.
    @discardableResult
    private func send(_ bytes: [UInt8], to path: String) -> Bool {
        guard socket >= 0, var address = Self.address(path) else { return false }
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        return sent >= 0 || (errno != ENOENT && errno != ECONNREFUSED)
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 256)
        var from = sockaddr_un()
        while true {
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socket, &buffer, buffer.count, MSG_DONTWAIT, $0, &length)
                }
            }
            guard count > 0 else { return }
            let message = Array(buffer[0..<count])
            if isHub {
                let path = withUnsafeBytes(of: &from.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                fromWindow(message, path: path)
            } else {
                fromHub(message)
            }
        }
    }

    private static func put(_ value: UInt32, _ bytes: inout [UInt8]) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    private static func put(_ value: Float, _ bytes: inout [UInt8]) { put(value.bitPattern, &bytes) }
    private static func uint(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
    private static func float(_ bytes: [UInt8], _ at: Int) -> Float { Float(bitPattern: uint(bytes, at)) }

    private var controllersMessage: [UInt8] {
        var bytes = [Message.controllers.rawValue, UInt8(min(states.count, 255))]
        for id in ids.prefix(255) { Self.put(id, &bytes) }
        return bytes
    }

    private static func stateMessage(_ id: UInt32, _ state: State) -> [UInt8] {
        var bytes = [Message.state.rawValue]
        put(id, &bytes)
        for value in [state.leftX, state.leftY, state.rightX, state.rightY, state.leftTrigger, state.rightTrigger] {
            put(Float(value), &bytes)
        }
        put(state.buttons, &bytes)
        return bytes
    }

    // MARK: Inquiline: the one reader

    /// Inquiline listens for its windows, and reads the controllers while any window wants them.
    func startHub() {
        guard socket < 0 else { return }
        isHub = true
        guard listen(at: Self.hubPath) else {
            AppLog.write("Game controllers couldn't be shared with the apps")
            return
        }
        // A window that quit or crashed stops saying hello.
        keepAlive = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.forgetSilentWindows() }
    }

    private func fromWindow(_ message: [UInt8], path: String) {
        guard let type = message.first.flatMap(Message.init), !path.isEmpty else { return }
        switch type {
        case .hello:
            let isNew = windows[path] == nil
            windows[path] = ProcessInfo.processInfo.systemUptime
            startReading()
            guard isNew else { return }
            send(controllersMessage, to: path)
            for (id, state) in states { send(Self.stateMessage(id, state), to: path) }
        case .rumble where message.count >= 17:
            rumble(Self.uint(message, 1), low: Double(Self.float(message, 5)), high: Double(Self.float(message, 9)),
                   ms: Self.uint(message, 13))
        default:
            break
        }
    }

    private func broadcast(_ bytes: [UInt8]) {
        for path in windows.keys where !send(bytes, to: path) { forget(path) }
    }

    private func forget(_ path: String) {
        windows[path] = nil
        unlink(path)
        // What a window started doesn't outlive it.
        for id in pads.keys { rumble(id, low: 0, high: 0, ms: 0) }
    }

    private func forgetSilentWindows() {
        let now = ProcessInfo.processInfo.systemUptime
        for (path, said) in windows where now - said > 6 { forget(path) }
        // With no app open, the controllers are left alone, for the Mac's own games.
        if windows.isEmpty, timer != nil { stopReading() }
    }

    /// Starts reading controllers, on the main thread, about 250 times a second.
    private func startReading() {
        guard timer == nil else { return }
        // Read while another app is in front: Inquiline is never in front, its windows are.
        SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1")
        guard SDL_Init(SDL_INIT_GAMEPAD | SDL_INIT_SENSOR | SDL_INIT_HAPTIC) else {
            AppLog.write("Game controllers couldn't be read")
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 250, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func stopReading() {
        timer?.invalidate()
        timer = nil
        for (_, pad) in pads { SDL_CloseGamepad(pad) }
        for (_, known) in motion { inquiline_motion_destroy(known.calibration) }
        pads = [:]
        motion = [:]
        states = [:]
        SDL_QuitSubSystem(SDL_INIT_GAMEPAD | SDL_INIT_SENSOR | SDL_INIT_HAPTIC)
    }

    // MARK: A window: Inquiline's controllers

    /// A window gets Inquiline's controllers, from now until it quits.
    func start() {
        guard socket < 0 else { return }
        let path = Self.folder.appendingPathComponent("window-\(getpid())").path
        guard listen(at: path) else {
            AppLog.write("Game controllers couldn't be reached")
            return
        }
        atexit { unlink(SDLGamepads.folder.appendingPathComponent("window-\(getpid())").path) }
        hello()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.hello() }
    }

    private func hello() { send([Message.hello.rawValue], to: Self.hubPath) }

    private func fromHub(_ message: [UInt8]) {
        guard let type = message.first.flatMap(Message.init) else { return }
        switch type {
        case .controllers where message.count >= 2:
            let count = Int(message[1])
            guard message.count >= 2 + count * 4 else { return }
            let now = Set((0..<count).map { Self.uint(message, 2 + $0 * 4) })
            for id in states.keys where !now.contains(id) { states[id] = nil }
            for id in now where states[id] == nil { states[id] = State() }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        case .state where message.count >= 33:
            let id = Self.uint(message, 1)
            guard states[id] != nil else { return }
            let axes = (0..<6).map { Double(Self.float(message, 5 + $0 * 4)) }
            let state = State(axes: axes, buttons: Self.uint(message, 29))
            guard state != states[id] else { return }
            states[id] = state
            onState?(id, state)
        case .motion where message.count >= 29:
            let values = (0..<6).map { Self.float(message, 5 + $0 * 4) }
            onMotion?(Self.uint(message, 1), Array(values[0..<3]), Array(values[3..<6]))
        default:
            break
        }
    }

    // MARK: Reading

    private func poll() {
        var event = SDL_Event()
        var changed = Set<UInt32>()
        var plugged = false
        while SDL_PollEvent(&event) {
            switch SDL_EventType(event.type) {
            case SDL_EVENT_GAMEPAD_ADDED:
                let id = event.gdevice.which
                if pads[id] == nil, let pad = SDL_OpenGamepad(id) {
                    pads[id] = pad
                    states[id] = State()
                    changed.insert(id)
                    plugged = true
                    if let name = SDL_GetGamepadName(pad) { AppLog.write("Game controller: \(String(cString: name))") }
                    // Its motion, when it has a gyro: Android gets it as the phone's own sensors.
                    if SDL_GamepadHasSensor(pad, SDL_SENSOR_GYRO), SDL_SetGamepadSensorEnabled(pad, SDL_SENSOR_GYRO, true) {
                        if SDL_GamepadHasSensor(pad, SDL_SENSOR_ACCEL) { SDL_SetGamepadSensorEnabled(pad, SDL_SENSOR_ACCEL, true) }
                        motion[id] = (inquiline_motion_create()!, [0, 9.80665, 0], 0)
                    }
                }
            case SDL_EVENT_GAMEPAD_REMOVED:
                let id = event.gdevice.which
                if let pad = pads.removeValue(forKey: id) { SDL_CloseGamepad(pad) }
                if let known = motion.removeValue(forKey: id) { inquiline_motion_destroy(known.calibration) }
                states[id] = nil
                plugged = true
            case SDL_EVENT_GAMEPAD_SENSOR_UPDATE:
                sensed(event.gsensor)
            case SDL_EVENT_GAMEPAD_AXIS_MOTION, SDL_EVENT_GAMEPAD_BUTTON_DOWN, SDL_EVENT_GAMEPAD_BUTTON_UP:
                changed.insert(event.gdevice.which)
            default:
                break
            }
        }
        if plugged { broadcast(controllersMessage) }
        for id in changed {
            guard let pad = pads[id] else { continue }
            let state = Self.read(pad)
            guard state != states[id] else { continue }
            states[id] = state
            broadcast(Self.stateMessage(id, state))
        }
    }

    /// A motion sample: acceleration is kept for the next rotation, which is calibrated and told.
    private func sensed(_ sample: SDL_GamepadSensorEvent) {
        guard var known = motion[sample.which] else { return }
        let values = [sample.data.0, sample.data.1, sample.data.2]
        if sample.sensor == SDL_SENSOR_ACCEL.rawValue {
            known.acceleration = values
            motion[sample.which] = known
            return
        }
        guard sample.sensor == SDL_SENSOR_GYRO.rawValue else { return }
        let seconds = known.time == 0 ? 0.005 : Float(min(sample.sensor_timestamp &- known.time, 100_000_000)) / 1e9
        known.time = sample.sensor_timestamp
        motion[sample.which] = known
        var calibrated: [Float] = [0, 0, 0]
        values.withUnsafeBufferPointer { rotation in
            known.acceleration.withUnsafeBufferPointer { acceleration in
                inquiline_motion_process(known.calibration, rotation.baseAddress, acceleration.baseAddress,
                                         seconds, &calibrated)
            }
        }
        var down: [Float] = [0, 0, 0]
        inquiline_motion_gravity(known.calibration, &down)
        // Until it has one, the reading itself.
        let up = down == [0, 0, 0] ? known.acceleration : down.map { -$0 * 9.80665 }
        var bytes = [Message.motion.rawValue]
        Self.put(sample.which, &bytes)
        for value in up + calibrated { Self.put(value, &bytes) }
        broadcast(bytes)
    }

    /// Rumbles a controller, its big (low) and small (high) motors from 0 to 1, for `ms`: in a
    /// window, through Inquiline.
    func rumble(_ id: UInt32, low: Double, high: Double, ms: UInt32) {
        guard isHub else {
            var bytes = [Message.rumble.rawValue]
            Self.put(id, &bytes)
            Self.put(Float(low), &bytes)
            Self.put(Float(high), &bytes)
            Self.put(ms, &bytes)
            send(bytes, to: Self.hubPath)
            return
        }
        guard let pad = pads[id] else { return }
        SDL_RumbleGamepad(pad, UInt16(min(max(low, 0), 1) * 65535), UInt16(min(max(high, 0), 1) * 65535), ms)
    }

    private static func read(_ pad: OpaquePointer) -> State {
        func axis(_ which: SDL_GamepadAxis) -> Double { Double(SDL_GetGamepadAxis(pad, which)) / 32767 }
        func button(_ which: SDL_GamepadButton) -> Bool { SDL_GetGamepadButton(pad, which) }
        var state = State()
        state.leftX = max(axis(SDL_GAMEPAD_AXIS_LEFTX), -1)
        state.leftY = max(axis(SDL_GAMEPAD_AXIS_LEFTY), -1)
        state.rightX = max(axis(SDL_GAMEPAD_AXIS_RIGHTX), -1)
        state.rightY = max(axis(SDL_GAMEPAD_AXIS_RIGHTY), -1)
        state.leftTrigger = max(axis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER), 0)
        state.rightTrigger = max(axis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER), 0)
        state.south = button(SDL_GAMEPAD_BUTTON_SOUTH)
        state.east = button(SDL_GAMEPAD_BUTTON_EAST)
        state.west = button(SDL_GAMEPAD_BUTTON_WEST)
        state.north = button(SDL_GAMEPAD_BUTTON_NORTH)
        state.leftShoulder = button(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER)
        state.rightShoulder = button(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER)
        state.leftStick = button(SDL_GAMEPAD_BUTTON_LEFT_STICK)
        state.rightStick = button(SDL_GAMEPAD_BUTTON_RIGHT_STICK)
        state.back = button(SDL_GAMEPAD_BUTTON_BACK)
        state.start = button(SDL_GAMEPAD_BUTTON_START)
        state.guide = button(SDL_GAMEPAD_BUTTON_GUIDE)
        state.up = button(SDL_GAMEPAD_BUTTON_DPAD_UP)
        state.down = button(SDL_GAMEPAD_BUTTON_DPAD_DOWN)
        state.left = button(SDL_GAMEPAD_BUTTON_DPAD_LEFT)
        state.right = button(SDL_GAMEPAD_BUTTON_DPAD_RIGHT)
        return state
    }
}
