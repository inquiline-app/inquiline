import Foundation
import IOKit.hid

/// Game controllers handed to Android whole, as a phone's Bluetooth stack hands them to its
/// kernel (Android's HID host, which creates them through uhid): their own name, report
/// descriptor and reports go in, and what Android's drivers send back (rumble, lights, the
/// requests that read a controller's calibration or turn on its motion sensors) goes back to
/// the controller. Android then runs it with Linux's own drivers (hid-playstation,
/// hid-nintendo, hid-microsoft, hid-sony, hid-steam, or the generic one with Android's key
/// layouts), so it works as on a phone, rumble and motion included.
///
/// Controllers macOS doesn't show as HID devices (Xbox pads on a cable, which Apple's own
/// driver runs) aren't here; GamepadBridge plugs those in as Xbox 360 pads, as before.
final class RawGamepads {
    static let shared = RawGamepads()
    /// Posted on the main thread when a controller comes or goes.
    static let didChange = Notification.Name("InquilineRawGamepadsChanged")

    final class Device {
        let handle: IOHIDDevice
        let vendor: UInt16
        let product: UInt16
        let name: String
        let descriptor: [UInt8]
        /// Linux's bus for it: BUS_USB (3) or BUS_BLUETOOTH (5), which its driver matches.
        let bus: UInt8
        /// Whether its reports carry an ID (the descriptor has Report ID items): then the kernel's
        /// reports start with it, and macOS takes it as the report's ID.
        let numbered: Bool
        fileprivate var buffer: UnsafeMutablePointer<UInt8>
        fileprivate let bufferSize: Int
        /// Called with each input report, on the main thread.
        var onReport: (([UInt8]) -> Void)?

        fileprivate init?(_ handle: IOHIDDevice) {
            func number(_ key: String) -> Int? { IOHIDDeviceGetProperty(handle, key as CFString) as? Int }
            guard let data = IOHIDDeviceGetProperty(handle, kIOHIDReportDescriptorKey as CFString) as? Data,
                  !data.isEmpty, data.count <= 4096
            else { return nil }
            self.handle = handle
            vendor = UInt16(truncatingIfNeeded: number(kIOHIDVendorIDKey) ?? 0)
            product = UInt16(truncatingIfNeeded: number(kIOHIDProductIDKey) ?? 0)
            name = (IOHIDDeviceGetProperty(handle, kIOHIDProductKey as CFString) as? String) ?? "Game Controller"
            descriptor = [UInt8](data)
            numbered = Self.hasReportIDs(descriptor)
            let transport = (IOHIDDeviceGetProperty(handle, kIOHIDTransportKey as CFString) as? String) ?? ""
            bus = transport.localizedCaseInsensitiveContains("bluetooth") ? 5 : 3
            bufferSize = max(number(kIOHIDMaxInputReportSizeKey) ?? 64, 64)
            buffer = .allocate(capacity: bufferSize)
        }

        deinit { buffer.deallocate() }

        /// Walks the descriptor's short items for a Report ID (global item, tag 8: 0x85).
        private static func hasReportIDs(_ descriptor: [UInt8]) -> Bool {
            var at = 0
            while at < descriptor.count {
                let prefix = descriptor[at]
                if prefix == 0xFE { // long item
                    guard at + 1 < descriptor.count else { return false }
                    at += 3 + Int(descriptor[at + 1])
                    continue
                }
                if prefix & 0xFC == 0x84 { return true }
                let size = [0, 1, 2, 4][Int(prefix & 0x03)]
                at += 1 + size
            }
            return false
        }

        /// An output report from Android's driver, as the kernel hands it over: report ID first
        /// when the device numbers its reports.
        func output(_ report: [UInt8]) {
            guard !report.isEmpty else { return }
            report.withUnsafeBufferPointer { bytes in
                _ = IOHIDDeviceSetReport(handle, kIOHIDReportTypeOutput, CFIndex(numbered ? report[0] : 0), bytes.baseAddress!, report.count)
            }
        }

        /// A report the kernel asks for (kind 0, GET) or sets (kind 1): its answer, and errno.
        func report(kind: Int, number: UInt8, type: UInt8, data: [UInt8]) -> (Int32, [UInt8]) {
            // Linux's rtype: 0 feature, 1 output, 2 input.
            let reportType: IOHIDReportType = type == 1 ? kIOHIDReportTypeOutput : type == 2 ? kIOHIDReportTypeInput : kIOHIDReportTypeFeature
            if kind == 1 {
                let result = data.withUnsafeBufferPointer { bytes in
                    IOHIDDeviceSetReport(handle, reportType, CFIndex(numbered ? number : 0), bytes.baseAddress ?? UnsafePointer(buffer), data.count)
                }
                return (result == kIOReturnSuccess ? 0 : EIO, [])
            }
            var answer = [UInt8](repeating: 0, count: 4096)
            var length = CFIndex(answer.count)
            if number != 0 { answer[0] = number }
            let result = IOHIDDeviceGetReport(handle, reportType, CFIndex(numbered ? number : 0), &answer, &length)
            guard result == kIOReturnSuccess else { return (EIO, []) }
            var reply = Array(answer.prefix(length))
            // The kernel expects the report ID first; macOS leaves it out of some devices' reports.
            if numbered, reply.first != number { reply.insert(number, at: 0) }
            return (0, reply)
        }
    }

    private(set) var devices: [Device] = []
    private var manager: IOHIDManager?

    private init() {}

    /// Starts watching for controllers; Linux drives these, so they're handed over whole.
    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let page = kHIDPage_GenericDesktop
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDDeviceUsagePageKey: page, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: page, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: page, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, handle in
            Unmanaged<RawGamepads>.fromOpaque(context!).takeUnretainedValue().added(handle)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, handle in
            Unmanaged<RawGamepads>.fromOpaque(context!).takeUnretainedValue().removed(handle)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Taken from Apple's own driver while Inquiline runs, as a phone's kernel has its
        // controller to itself: two drivers sending a controller their own commands (report
        // modes, calibration reads) leave it in neither's. Without that, it's shared.
        if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) != kIOReturnSuccess {
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        self.manager = manager
    }

    /// The controller Apple's GameController names `name`, if it's here whole.
    func device(named name: String?) -> Device? {
        guard let name else { return nil }
        return devices.first { $0.name == name }
    }

    private func added(_ handle: IOHIDDevice) {
        guard !devices.contains(where: { $0.handle == handle }), let device = Device(handle) else { return }
        devices.append(device)
        let context = Unmanaged.passUnretained(device).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(handle, device.buffer, device.bufferSize, { context, result, _, _, id, report, length in
            guard result == kIOReturnSuccess else { return }
            let device = Unmanaged<Device>.fromOpaque(context!).takeUnretainedValue()
            var bytes = [UInt8](UnsafeBufferPointer(start: report, count: length))
            // macOS gives numbered reports without their ID when the buffer starts after it.
            if device.numbered, bytes.first != UInt8(truncatingIfNeeded: id) { bytes.insert(UInt8(truncatingIfNeeded: id), at: 0) }
            device.onReport?(bytes)
        }, context)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func removed(_ handle: IOHIDDevice) {
        devices.removeAll { $0.handle == handle }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
