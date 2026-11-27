import CSDL
import Foundation

/// Every game controller on the Mac, read through SDL (Scripts/build-sdl.sh), as Steam and most
/// emulators read them: its own drivers speak PlayStation, Xbox and Switch controllers and their
/// copies (a copy's broken calibration included), its database maps thousands of others, and
/// every one comes out as the same gamepad. So a game in Android sees one kind of controller,
/// whatever is in the player's hands, made or certified by anyone or no one.
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
    }

    /// Called on the main thread with a controller whose state changed.
    var onState: ((_ id: UInt32, _ state: State) -> Void)?
    /// Called on the main thread with a controller's motion, as Android's sensors report it:
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

    /// Starts reading controllers, on the main thread, about 250 times a second.
    func start() {
        guard timer == nil else { return }
        // Read while another app is in front too: the window decides what Android gets then.
        SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1")
        guard SDL_Init(SDL_INIT_GAMEPAD | SDL_INIT_SENSOR | SDL_INIT_HAPTIC) else {
            AppLog.write("Game controllers couldn't be read")
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 250, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

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
        if plugged { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        for id in changed {
            guard let pad = pads[id] else { continue }
            let state = Self.read(pad)
            guard state != states[id] else { continue }
            states[id] = state
            onState?(id, state)
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
        onMotion?(sample.which, up, calibrated)
    }

    /// Rumbles a controller, its big (low) and small (high) motors from 0 to 1, for `ms`.
    func rumble(_ id: UInt32, low: Double, high: Double, ms: UInt32) {
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
