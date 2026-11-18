import AppKit
import WidgetKit

// Asked by Inquiline (WidgetBridge) after Android redrew one of this app's widgets: the Mac
// redraws them, as only the extension's own app may ask, and the widgets it shows are printed.
if CommandLine.arguments.contains(WidgetBridge.reloadArgument) {
    WidgetCenter.shared.reloadAllTimelines()
    WidgetCenter.shared.getCurrentConfigurations { result in
        let shown = ((try? result.get()) ?? []).map { ["kind": $0.kind, "family": $0.family.inquilineName] }
        if let data = try? JSONSerialization.data(withJSONObject: shown) { FileHandle.standardOutput.write(data) }
        exit(0)
    }
    dispatchMain()
}

extension WidgetFamily {
    /// As the extension names sizes in its files.
    var inquilineName: String {
        switch self {
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        case .systemExtraLarge: "extraLarge"
        default: "other"
        }
    }
}

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
