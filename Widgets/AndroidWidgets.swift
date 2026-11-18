import ImageIO
import SwiftUI
import WidgetKit

// The widget extension inside each Android app's Mac app (Contents/PlugIns/Widgets.appex): it
// offers that app's Android widgets in the Mac's widget gallery, under the app's own name, as a
// phone's widget picker lists them. Inquiline writes what to show into its own folder, which the
// extension may read (and drop requests into) and nothing else:
//   ~/Library/Application Support/Inquiline/widgets/<package>/
//     manifest.json        the app's widgets: kind (w0…w4), name, Mac sizes, preview file
//     <kind>-preview.png   the picture Android gives for the widget picker
//     <kind>-<family>.png  the widget as Android last drew it at that size
//     requests/            a file per widget the Mac shows: "<kind>-<family>" holding "<w>x<h>"
// Built by Scripts/build-app.sh with swiftc; AppShortcuts puts a copy in each app.

struct ManifestWidget: Decodable {
    let kind: String
    let label: String
    let families: [String]
    let preview: String?
}

enum Folder {
    /// The real home, not the sandbox container's.
    static var home: URL {
        let path = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: path)
    }

    /// The Android app this extension's app stands for, from that app's Info.plist.
    static var package: String? {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["InquilinePackage"] as? String
    }

    static var widgets: URL? {
        package.map { home.appendingPathComponent("Library/Application Support/Inquiline/widgets/\($0)") }
    }

    static func manifest() -> [ManifestWidget] {
        guard let file = widgets?.appendingPathComponent("manifest.json"), let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([ManifestWidget].self, from: data)) ?? []
    }

    /// The picture, no larger than the widget shows it on a Retina screen: the Mac leaves a
    /// widget blank whose picture has more pixels than the widget.
    static func image(_ name: String, fitting size: CGSize) -> NSImage? {
        guard let file = widgets?.appendingPathComponent(name),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(max(size.width, size.height) * 2)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

extension WidgetFamily {
    var name: String {
        switch self {
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        case .systemExtraLarge: "extraLarge"
        default: "other"
        }
    }

    init?(name: String) {
        switch name {
        case "small": self = .systemSmall
        case "medium": self = .systemMedium
        case "large": self = .systemLarge
        case "extraLarge": self = .systemExtraLarge
        default: return nil
        }
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let image: NSImage?
}

struct Provider: TimelineProvider {
    let kind: String

    private func entry(_ context: Context, live: Bool) -> Entry {
        let size = context.displaySize
        let drawn = live ? Folder.image("\(kind)-\(context.family.name).png", fitting: size) : nil
        return Entry(date: .now, image: drawn ?? Folder.image("\(kind)-preview.png", fitting: size))
    }

    func placeholder(in context: Context) -> Entry { entry(context, live: false) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(entry(context, live: !context.isPreview))
    }

    /// Asks Inquiline for the widget at this size, then shows what it has. Inquiline asks the
    /// Mac to redraw once Android has drawn it; the timeline's own refresh is a fallback.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        if let requests = Folder.widgets?.appendingPathComponent("requests") {
            try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
            let size = "\(Int(context.displaySize.width))x\(Int(context.displaySize.height))"
            try? Data(size.utf8).write(to: requests.appendingPathComponent("\(kind)-\(context.family.name)"))
        }
        completion(Timeline(entries: [entry(context, live: true)], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct AndroidWidgetView: View {
    let entry: Entry

    var body: some View {
        // Android's widget, its empty edges already trimmed, fitted to the box with the Mac's own
        // margins and background, as the Mac's widgets have them.
        Group {
            if let image = entry.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "square.dashed").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// One of up to five widgets an app offers; slot `index` of its manifest.
enum Slot {
    static func configuration(_ index: Int) -> some WidgetConfiguration {
        let kind = "w\(index)"
        let manifest = Folder.manifest()
        let widget = manifest.first { $0.kind == kind }
        return StaticConfiguration(kind: kind, provider: Provider(kind: kind)) { AndroidWidgetView(entry: $0) }
            .configurationDisplayName(widget?.label ?? "")
            .description("")
            .supportedFamilies((widget?.families ?? []).compactMap(WidgetFamily.init(name:)))
    }
}

struct W0: Widget { var body: some WidgetConfiguration { Slot.configuration(0) } }
struct W1: Widget { var body: some WidgetConfiguration { Slot.configuration(1) } }
struct W2: Widget { var body: some WidgetConfiguration { Slot.configuration(2) } }
struct W3: Widget { var body: some WidgetConfiguration { Slot.configuration(3) } }
struct W4: Widget { var body: some WidgetConfiguration { Slot.configuration(4) } }

@main
struct AndroidWidgets: WidgetBundle {
    var body: some Widget {
        W0()
        W1()
        W2()
        W3()
        W4()
    }
}
