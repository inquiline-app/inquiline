import AppKit
import GameController
import IOKit.hid

/// Game controllers connected to the Mac reach the Android app as they are: each one's own
/// reports, with its own name and ids, as if paired with the phone, so Android's own drivers
/// and layouts know it, the Mac's or not (RawPads). One the Mac can't hand over that way
/// reaches it as an Xbox 360 pad, made from what the Mac makes of it. As a keyboard does,
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
    private var held: [ObjectIdentifier: Set<Int>] = [:]
    /// The HID id each controller has in Android. scrcpy keeps 1 and 2 for a keyboard and mouse.
    private var plugged: [ObjectIdentifier: UInt16] = [:]
    private var observers: [NSObjectProtocol] = []
    private var raw: RawPads?

    init(session: ScrcpySession, controls: KeyControlPlayer) {
        self.session = session
        self.controls = controls
        raw = RawPads(session: session) { [weak self] in self?.update() }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.update() },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.update() },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.update() },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.update() },
        ]
        update()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Unplugs every controller, as when the app's window closes.
    func stop() {
        raw?.stop()
        raw = nil
        for (_, id) in plugged { session.sendHIDClose(id: id) }
        plugged = [:]
        for key in held.keys { release(key) }
        GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
    }

    /// Called again when the controls change, as they decide who gets the controller.
    func update() {
        let usesPad = controls?.set.usesPad == true
        // Handed over as they are, while the game takes controllers: then none is made up.
        let rawPads = !usesPad && raw?.hasPads == true
        raw?.forwarding = rawPads && NSApp.isActive
        raw?.plugged = rawPads
        let wanted = GCController.controllers().filter { $0.extendedGamepad != nil }
        let wantedKeys = Set(wanted.map(ObjectIdentifier.init))
        for (key, id) in plugged where !wantedKeys.contains(key) || usesPad || rawPads {
            session.sendHIDClose(id: id)
            plugged[key] = nil
        }
        for controller in wanted {
            let key = ObjectIdentifier(controller)
            guard let pad = controller.extendedGamepad else { continue }
            if !usesPad, !rawPads, plugged[key] == nil,
               let id = (3...10).map(UInt16.init).first(where: { !plugged.values.contains($0) }) {
                plugged[key] = id
                session.sendHIDOpen(id: id, vendor: 0x045E, product: 0x028E, name: "Microsoft X-Box 360 Pad",
                                    descriptor: Self.descriptor)
            }
            pad.valueChangedHandler = { [weak self] pad, _ in
                guard let self, NSApp.isActive else { return }
                self.changed(pad, key: key)
            }
            // Going to the back lets go of everything held; coming to the front picks up the pad as it is.
            if let id = plugged[key] { session.sendHIDInput(id: id, report: NSApp.isActive ? Self.report(pad) : Self.atRest) }
            if !NSApp.isActive { release(key) }
        }
    }

    private func changed(_ pad: GCExtendedGamepad, key: ObjectIdentifier) {
        let pressed = Self.pressed(pad)
        let before = held[key] ?? []
        held[key] = pressed
        // A button pressed while the controls are edited is given to the chosen control.
        if let onEditPress {
            for code in pressed.subtracting(before) where onEditPress(code) { return }
        }
        if let id = plugged[key] {
            session.sendHIDInput(id: id, report: Self.report(pad))
            return
        }
        guard let controls, controls.set.usesPad else { return }
        for code in pressed.subtracting(before) { _ = controls.key(code, down: true) }
        for code in before.subtracting(pressed) { _ = controls.key(code, down: false) }
        controls.padStick(x: Double(pad.leftThumbstick.xAxis.value), y: Double(-pad.leftThumbstick.yAxis.value))
        controls.padAim(x: Double(pad.rightThumbstick.xAxis.value), y: Double(-pad.rightThumbstick.yAxis.value))
    }

    private func release(_ key: ObjectIdentifier) {
        guard let controls, let before = held[key] else { return }
        held[key] = []
        for code in before { _ = controls.key(code, down: false) }
        controls.padStick(x: 0, y: 0)
        controls.padAim(x: 0, y: 0)
    }

    /// The controller's buttons held now, as control codes. A trigger counts once it's half in.
    private static func pressed(_ pad: GCExtendedGamepad) -> Set<Int> {
        typealias Pad = KeyControl.Pad
        var codes = Set<Int>()
        let buttons: [(GCControllerButtonInput?, Pad)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftThumbstickButton, .leftStickButton), (pad.rightThumbstickButton, .rightStickButton),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .options),
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right),
        ]
        for (button, code) in buttons where button?.isPressed == true { codes.insert(code.rawValue) }
        if pad.leftTrigger.value > 0.5 { codes.insert(Pad.leftTrigger.rawValue) }
        if pad.rightTrigger.value > 0.5 { codes.insert(Pad.rightTrigger.rawValue) }
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
    private static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0xA1, 0x00,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34,
        0x15, 0x00, 0x27, 0xFF, 0xFF, 0x00, 0x00, 0x75, 0x10, 0x95, 0x04, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01, 0x95, 0x10, 0x75, 0x01, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x39, 0x15, 0x01, 0x25, 0x08, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
        0xC0, 0xC0,
    ]

    private static func report(_ pad: GCExtendedGamepad) -> [UInt8] {
        // Sticks run from 0 to 65535 with the middle at 32768; down is positive, as in Android.
        func stick(_ value: Float) -> UInt16 { UInt16(clamping: Int(32768 + Double(value) * 32767)) }
        func trigger(_ value: Float) -> UInt16 { UInt16(clamping: Int(Double(value) * 32767)) }
        var buttons: UInt16 = 0
        let bits: [(GCControllerButtonInput?, UInt16)] = [
            (pad.buttonA, 0x0001), (pad.buttonB, 0x0002), (pad.buttonX, 0x0008), (pad.buttonY, 0x0010),
            (pad.leftShoulder, 0x0040), (pad.rightShoulder, 0x0080), (pad.buttonOptions, 0x0400),
            (pad.buttonMenu, 0x0800), (pad.buttonHome, 0x1000),
            (pad.leftThumbstickButton, 0x2000), (pad.rightThumbstickButton, 0x4000),
        ]
        for (button, bit) in bits where button?.isPressed == true { buttons |= bit }

        // The hat counts clockwise from 1 at the top; 0 is centered.
        let dpad = pad.dpad
        let up = dpad.up.isPressed, down = dpad.down.isPressed, left = dpad.left.isPressed, right = dpad.right.isPressed
        let hat: UInt8 = up ? (right ? 2 : left ? 8 : 1) : down ? (right ? 4 : left ? 6 : 5) : right ? 3 : left ? 7 : 0

        var report: [UInt8] = []
        for value in [stick(pad.leftThumbstick.xAxis.value), stick(-pad.leftThumbstick.yAxis.value),
                      stick(pad.rightThumbstick.xAxis.value), stick(-pad.rightThumbstick.yAxis.value),
                      trigger(pad.leftTrigger.value), trigger(pad.rightTrigger.value), buttons] {
            report += [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
        report.append(hat)
        return report
    }
}

/// The controllers the Mac sees, read as their own reports (IOKit's HID manager) and handed to
/// Android unchanged, under their own name and vendor and product ids: Android's kernel and its
/// controller layouts then know each one as when it's paired with a phone. Reports pass only
/// while the app is in front, as the Mac's other controls do.
private final class RawPads {
    private let session: ScrcpySession
    private let changed: () -> Void
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var pads: [IOHIDDevice: Pad] = [:]

    private final class Pad {
        let device: IOHIDDevice
        let vendor: UInt16, product: UInt16
        let name: String
        let descriptor: [UInt8]
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        var id: UInt16?

        init?(_ device: IOHIDDevice) {
            func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
            guard let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
                  !descriptor.isEmpty else { return nil }
            self.device = device
            vendor = UInt16(truncatingIfNeeded: number(kIOHIDVendorIDKey))
            product = UInt16(truncatingIfNeeded: number(kIOHIDProductIDKey))
            name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Gamepad"
            self.descriptor = [UInt8](descriptor)
            size = max(number(kIOHIDMaxInputReportSizeKey), 64)
            buffer = .allocate(capacity: size)
        }

        deinit { buffer.deallocate() }
    }

    /// Whether the game sees them: plugged into Android, each under an HID id of its own.
    var plugged = false {
        didSet { if plugged != oldValue { pads.values.forEach(plugged ? plug : unplug) } }
    }
    /// Whether their reports pass now.
    var forwarding = false
    var hasPads: Bool { !pads.isEmpty }

    init(session: ScrcpySession, changed: @escaping () -> Void) {
        self.session = session
        self.changed = changed
        let usages: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, usages as CFArray)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<RawPads>.fromOpaque(context).takeUnretainedValue().added(device)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<RawPads>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        plugged = false
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        pads = [:]
    }

    private func added(_ device: IOHIDDevice) {
        guard pads[device] == nil, let pad = Pad(device) else { return }
        pads[device] = pad
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, pad.buffer, pad.size, { context, _, sender, _, _, report, length in
            guard let context, let sender else { return }
            let pads = Unmanaged<RawPads>.fromOpaque(context).takeUnretainedValue()
            pads.report(from: Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue(), Array(UnsafeBufferPointer(start: report, count: length)))
        }, me)
        if plugged { plug(pad) }
        changed()
    }

    private func removed(_ device: IOHIDDevice) {
        guard let pad = pads.removeValue(forKey: device) else { return }
        unplug(pad)
        changed()
    }

    private func report(from device: IOHIDDevice, _ bytes: [UInt8]) {
        guard forwarding, let pad = pads[device], let id = pad.id else { return }
        // The report ID, where the controller uses them, leads the report as Android expects.
        session.sendHIDInput(id: id, report: bytes)
    }

    private func plug(_ pad: Pad) {
        guard pad.id == nil else { return }
        let used = Set(pads.values.compactMap(\.id))
        // scrcpy keeps 1 and 2 for a keyboard and mouse; the made-up pads use 3 to 10.
        guard let id = (11...20).map(UInt16.init).first(where: { !used.contains($0) }) else { return }
        pad.id = id
        session.sendHIDOpen(id: id, vendor: pad.vendor, product: pad.product, name: pad.name, descriptor: pad.descriptor)
    }

    private func unplug(_ pad: Pad) {
        guard let id = pad.id else { return }
        pad.id = nil
        session.sendHIDClose(id: id)
    }
}
