import AppKit
import Carbon

/// The Mac's keyboard as a USB keyboard plugged into Android, as a phone takes one: each key
/// goes by where it is, pressed and let go, and Android lays the characters out itself. Like a
/// real keyboard it reports its layout with a HID country code, taken from the layout chosen on
/// the Mac, so Android picks the same one. A layout without a code (Dvorak, Colemak, a rare
/// language) leaves the keyboard out, and keys go the way AndroidDisplayView sends them alone.
final class KeyboardBridge {
    private let session: ScrcpySession
    private static let id: UInt16 = 2
    private var plugged = false
    /// Keys held, by HID usage, as the keyboard reports them: up to six at once, as on most.
    private var keys: [UInt8] = []
    private var modifiers: UInt8 = 0
    private var observer: NSObjectProtocol?

    init(session: ScrcpySession) {
        self.session = session
        plug()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
            // Another layout: the keyboard is plugged in again, as one of that layout.
            self?.unplug()
            self?.plug()
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// Whether keys go through this keyboard: only with a layout Android knows.
    var isPlugged: Bool { plugged }

    /// Unplugs the keyboard, as when the app's window closes.
    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        unplug()
    }

    /// Whether Option goes as AltGr, as on a PC-style Mac layout ("Turkish-QWERTY-PC"), whose
    /// Option characters are a PC's AltGr ones. On Apple's own layouts they aren't, and go as text.
    private(set) var optionIsAltGr = false

    private func plug() {
        guard let country = Self.countryOfCurrentLayout() else { return }
        optionIsAltGr = Self.currentLayoutName()?.hasSuffix("-PC") == true
        lessThanKey = Self.keyGiving("<", among: [0x0A, 0x32])
        session.sendHIDOpen(id: Self.id, vendor: 0x05AC, product: 0x024F, name: "Mac Keyboard",
                            descriptor: Self.descriptor, country: country)
        plugged = true
        numLockOn = false
    }

    /// A Mac's keypad always types digits; Android starts a keyboard with Num Lock off, the
    /// keypad as arrows. Turned on before the first key, once Android has the keyboard.
    private var numLockOn = false

    private func turnNumLockOn() {
        guard !numLockOn else { return }
        numLockOn = true
        for report in [[0, 0, 0x53, 0, 0, 0, 0, 0], [UInt8](repeating: 0, count: 8)] {
            session.sendHIDInput(id: Self.id, report: report)
        }
    }

    private func unplug() {
        guard plugged else { return }
        session.sendHIDClose(id: Self.id)
        plugged = false
        keys = []
        modifiers = 0
    }

    /// A key pressed or let go, by its Mac key code. False when it has no USB key, so it
    /// goes some other way.
    func key(_ keyCode: UInt16, down: Bool, flags: NSEvent.ModifierFlags? = nil) -> Bool {
        guard plugged, let usage = usage(of: keyCode) else { return false }
        // The key's own modifiers count, as a Shift pressed while the window wasn't taking keys.
        if let flags { modifiers = Self.modifierBits(flags) | (optionIsAltGr && flags.contains(.option) ? 0x40 : 0) }
        if down {
            turnNumLockOn()
            guard !keys.contains(usage) else { return true } // the Mac repeating it: Android repeats itself
            guard keys.count < 6 else { return true }
            keys.append(usage)
        } else {
            keys.removeAll { $0 == usage }
        }
        send()
        return true
    }

    /// Shift, Control, Caps Lock and, on a PC-style layout, Option as AltGr, as the Mac reports
    /// them changing. Command stays with the Mac's menus.
    func modifiersChanged(_ event: NSEvent) {
        guard plugged else { return }
        if event.keyCode == 57 { // Caps Lock: one press for each change, as the key toggles
            for down in [true, false] { _ = key(57, down: down) }
            return
        }
        let flags = event.modifierFlags
        let bits = Self.modifierBits(flags) | (optionIsAltGr && flags.contains(.option) ? 0x40 : 0)
        guard bits != modifiers else { return }
        modifiers = bits
        send()
    }

    /// Control and Shift held, as the keyboard reports them, from the bits macOS keeps for
    /// each side (NX_DEVICE…KEYMASK); a side it doesn't name counts as the left one.
    private static func modifierBits(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        let raw = UInt(flags.rawValue)
        var bits: UInt8 = 0
        if raw & 0x2000 != 0 { bits |= 0x10 } else if flags.contains(.control) { bits |= 0x01 }
        if raw & 0x0004 != 0 { bits |= 0x20 } else if flags.contains(.shift) { bits |= 0x02 }
        return bits
    }

    /// Lets go of every key, as when the window stops taking keys.
    func releaseAll() {
        guard plugged, !keys.isEmpty || modifiers != 0 else { return }
        keys = []
        modifiers = 0
        send()
    }

    private func send() {
        var report: [UInt8] = [modifiers, 0]
        report += keys
        report += [UInt8](repeating: 0, count: 6 - keys.count)
        session.sendHIDInput(id: Self.id, report: report)
    }

    // MARK: - Layout

    /// The HID country code of the Mac's chosen layout, which Android turns into a layout
    /// of its own; nil for one it has none for.
    static func countryOfCurrentLayout() -> UInt8? {
        currentLayoutName().flatMap { countries[$0] }
    }

    private static func currentLayoutName() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    /// Apple's layouts by name → HID country code (HID 1.11, 6.2.1).
    private static let countries: [String: UInt8] = [
        "US": 33, "ABC": 33, "USInternational-PC": 33, "US-Extended": 33, "ABC-Extended": 33,
        "British": 32, "British-PC": 32, "Irish": 32,
        "Turkish-QWERTY-PC": 31, "Turkish-QWERTY": 31, "Turkish": 35, "Turkish-Standard": 35,
        "German": 9, "Austrian": 9, "French": 8, "French-PC": 8, "French-numerical": 8,
        "Spanish": 25, "Spanish-ISO": 25, "Italian": 14, "Italian-Pro": 14,
        "Swedish": 26, "Swedish-Pro": 26, "Norwegian": 19, "Danish": 6, "Finnish": 7,
        "Dutch": 18, "Portuguese": 22, "Polish": 21, "PolishPro": 21,
        "Russian": 23, "Russian-PC": 23, "Czech": 5, "Czech-QWERTY": 5, "Slovak": 24,
        "Hungarian": 12, "Greek": 10, "Hebrew": 11, "Arabic": 1, "Persian": 20,
        "SwissGerman": 28, "SwissFrench": 27, "Belgian": 2, "Canadian-CSA": 4, "CanadianFrench-PC": 4,
        "LatinAmerican": 17,
    ]

    // MARK: - Keys

    /// A boot keyboard, as most USB keyboards are: modifiers, a reserved byte and six keys,
    /// and its lights.
    private static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,             // Generic Desktop, Keyboard, Application
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7,             // Key codes, Left Control … Right GUI
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08,
        0x81, 0x02,                                     // modifiers
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,             // reserved
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05,
        0x91, 0x02,                                     // lights
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,             // lights' padding
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x26, 0xFF, 0x00,
        0x05, 0x07, 0x19, 0x00, 0x2A, 0xFF, 0x00, 0x81, 0x00, // six keys
        0xC0,
    ]

    /// Which of the Mac's two keys by 1 and by left Shift gives "<", the key a European PC
    /// keyboard has by left Shift. Which code each comes as depends on the keyboard (Apple's
    /// ISO ones swap them, as Linux's hid_apple knows), so the layout's own character decides.
    private var lessThanKey: UInt16?

    /// Mac key code → USB HID usage, by where the key is.
    private func usage(of keyCode: UInt16) -> UInt8? {
        if let lessThanKey, keyCode == 0x0A || keyCode == 0x32 {
            return keyCode == lessThanKey ? 0x64 : 0x35
        }
        return Self.usages[keyCode]
    }

    /// The first of these keys that types `character` alone in the Mac's chosen layout.
    private static func keyGiving(_ character: String, among keyCodes: [UInt16]) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        return keyCodes.first { code in
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            return status == noErr && String(utf16CodeUnits: chars, count: length) == character
        }
    }

    private static let usages: [UInt16: UInt8] = [
        0x00: 0x04, 0x01: 0x16, 0x02: 0x07, 0x03: 0x09, 0x04: 0x0B, 0x05: 0x0A, 0x06: 0x1D, 0x07: 0x1B,
        0x08: 0x06, 0x09: 0x19, 0x0A: 0x64, 0x0B: 0x05, 0x0C: 0x14, 0x0D: 0x1A, 0x0E: 0x08, 0x0F: 0x15,
        0x10: 0x1C, 0x11: 0x17, 0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x16: 0x23, 0x17: 0x22,
        0x18: 0x2E, 0x19: 0x26, 0x1A: 0x24, 0x1B: 0x2D, 0x1C: 0x25, 0x1D: 0x27, 0x1E: 0x30, 0x1F: 0x12,
        0x20: 0x18, 0x21: 0x2F, 0x22: 0x0C, 0x23: 0x13, 0x24: 0x28, 0x25: 0x0F, 0x26: 0x0D, 0x27: 0x34,
        0x28: 0x0E, 0x29: 0x33, 0x2A: 0x31, 0x2B: 0x36, 0x2C: 0x38, 0x2D: 0x11, 0x2E: 0x10, 0x2F: 0x37,
        0x30: 0x2B, 0x31: 0x2C, 0x32: 0x35, 0x33: 0x2A, 0x39: 0x39,
        0x41: 0x63, 0x43: 0x55, 0x45: 0x57, 0x4B: 0x54, 0x4C: 0x58, 0x4E: 0x56, 0x51: 0x67,
        0x52: 0x62, 0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, 0x59: 0x5F,
        0x5B: 0x60, 0x5C: 0x61, 0x5D: 0x89, 0x5E: 0x87, 0x5F: 0x85, 0x66: 0x91, 0x68: 0x90,
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41,
        0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45, 0x69: 0x68, 0x6B: 0x69, 0x71: 0x6A, 0x6A: 0x6B,
        0x40: 0x6C, 0x4F: 0x6D, 0x50: 0x6E,
        0x72: 0x49, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E,
        0x7B: 0x50, 0x7C: 0x4F, 0x7D: 0x51, 0x7E: 0x52,
    ]
}
