import AppKit

let app = NSApplication.shared
// The app shortcuts in ~/Applications run this same program, each for one Android app.
// Inquiline itself lives in the menu bar and runs Android for them.
let delegate: NSApplicationDelegate
if let package = Bundle.main.object(forInfoDictionaryKey: AppShortcuts.packageKey) as? String {
    delegate = AppProcess(package: package)
    app.setActivationPolicy(.regular)
} else {
    delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
}
app.delegate = delegate
app.run()
