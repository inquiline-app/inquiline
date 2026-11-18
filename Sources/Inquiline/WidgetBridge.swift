import AppKit
import CoreServices

/// Android apps' widgets in the Mac's widget gallery, on the desktop and in Notification Center,
/// as a phone's home screen has them. Each app's Mac app carries a widget extension
/// (Widgets/AndroidWidgets.swift) that shows what this writes into `folder`; the helper inside
/// Android hosts the widgets the Mac shows and sends each new picture of them (WidgetHost.java).
///
/// The extension may only read and write in `folder`, so that's where everything meets: the
/// manifest of each app's widgets, their pictures, and a request file for each widget the Mac
/// shows. A widget the Mac stops showing is let go once the app's Mac app, asked to reload its
/// widgets, no longer lists it.
final class WidgetBridge {
    static let shared = WidgetBridge()

    private let queue = DispatchQueue(label: "inquiline.widgets")
    /// What the extension may reach: the real home's, not a test copy's.
    let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Inquiline/widgets")
    /// Up to five widgets an app offers go to the gallery, as slots w0…w4 the extension declares.
    private static let slots = 5
    /// The Mac redraws an app's widgets this often at most, as it budgets reloads anyway.
    private static let reloadInterval: TimeInterval = 30

    private struct Placed: Equatable {
        let width: Int
        let height: Int
    }

    /// The widgets the helper shows now, by "<package>|<kind>|<family>".
    private var placed: [String: Placed] = [:]
    private var lastReload: [String: Date] = [:]
    private var reloadQueued: Set<String> = []
    private var stream: FSEventStreamRef?
    var send: (([String: Any]) -> Void)?

    private init() {}

    // MARK: - Manifests

    /// Writes each app's widget manifest and previews, when the app is new or changed. Call off
    /// the main thread, with the installed apps and their versions.
    func updateManifests(packages: [String], versions: [String: String]) {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        for package in packages where package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil {
            let app = folder.appendingPathComponent(package)
            let source = app.appendingPathComponent("version")
            // The manifest's own format too, so a new Inquiline writes it again.
            let version = "4 " + (versions[package] ?? "")
            if (try? String(contentsOf: source, encoding: .utf8)) == version { continue }
            guard let list = AndroidRuntime.shared.widgetList(package: package) else { continue }
            try? files.createDirectory(at: app, withIntermediateDirectories: true)
            var manifest: [[String: Any]] = []
            for (index, widget) in list.prefix(Self.slots).enumerated() {
                let kind = "w\(index)"
                guard let provider = widget["provider"] as? String else { continue }
                var entry: [String: Any] = ["kind": kind, "provider": provider,
                                            "label": widget["label"] as? String ?? "",
                                            "families": families(widget)]
                if let preview = (widget["preview"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                    try? Self.trimmed(preview).write(to: app.appendingPathComponent("\(kind)-preview.png"))
                    entry["preview"] = "\(kind)-preview.png"
                }
                manifest.append(entry)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: manifest) else { continue }
            try? data.write(to: app.appendingPathComponent("manifest.json"), options: .atomic)
            try? version.write(to: source, atomically: true, encoding: .utf8)
        }
        // An app Android no longer has takes its widgets with it.
        for gone in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where !packages.contains(gone) {
            try? files.removeItem(at: folder.appendingPathComponent(gone))
        }
    }

    /// The Mac sizes in a phone's home screen cells, as a 4-column launcher lays widgets out:
    /// small 2×2, medium 4×2, large 4×4.
    private static let familyCells: [(name: String, columns: Int, rows: Int)] = [
        ("small", 2, 2), ("medium", 4, 2), ("large", 4, 4),
    ]

    /// The Mac sizes a widget suits, from the cells it asks for and how far it resizes, as a
    /// launcher would place it: one it can't shrink into, or would sit small in, isn't offered.
    private func families(_ widget: [String: Any]) -> [String] {
        let mode = widget["resizeMode"] as? Int ?? 0
        func int(_ key: String) -> Int { widget[key] as? Int ?? 0 }
        /// Cells for a size in dp, as a phone's home screen sizes them today: 73 dp a cell, less 16.
        func cells(_ dp: Int) -> Int { max(1, Int(((Double(dp) + 16) / 73).rounded(.up))) }
        func range(_ axis: Int, target: String, min: String, minResize: String, maxResize: String) -> (Int, Int) {
            let wanted = int(target) > 0 ? int(target) : cells(int(min))
            guard mode & axis != 0 else { return (wanted, wanted) }
            let smallest = cells(int(minResize) > 0 ? int(minResize) : int(min))
            let largest = int(maxResize) > 0 ? cells(int(maxResize)) : 99
            return (Swift.min(smallest, wanted), Swift.max(largest, wanted))
        }
        let columns = range(1, target: "targetCellWidth", min: "minWidth", minResize: "minResizeWidth", maxResize: "maxResizeWidth")
        let rows = range(2, target: "targetCellHeight", min: "minHeight", minResize: "minResizeHeight", maxResize: "maxResizeHeight")
        // A cell short of the box is fine, as on a home screen; more leaves it looking lost.
        func suits(_ span: (Int, Int), _ box: Int) -> Bool { span.0 <= box && span.1 >= box - 1 }
        let suited = Self.familyCells.filter { suits(columns, $0.columns) && suits(rows, $0.rows) }.map(\.name)
        if !suited.isEmpty { return suited }
        // None quite: the one it fits into with the least room left over.
        let fitting = Self.familyCells.filter { columns.0 <= $0.columns && rows.0 <= $0.rows }
        return fitting.min { ($0.columns * $0.rows) < ($1.columns * $1.rows) }.map { [$0.name] } ?? []
    }

    /// The picture without the transparent edges Android leaves around a widget, so the Mac
    /// can fit what's drawn to its box.
    static func trimmed(_ png: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return png }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return png }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top, right - left + 1 < width || bottom - top + 1 < height,
              let cropped = image.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else { return png }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(destination, cropped, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : png
    }

    private func manifest(_ package: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(package)/manifest.json")) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    // MARK: - Requests

    /// Watches the extensions' requests, and places what they ask for.
    func start() {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard stream == nil else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<WidgetBridge>.fromOpaque(info).takeUnretainedValue().reconcile()
            }
            guard let created = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
            reconcile()
        }
    }

    /// The helper connected, after Android started: nothing is shown yet, so all is placed again.
    func connected() {
        queue.async { [self] in
            placed = [:]
            // Widgets removed from the Mac while Android was off are let go now: the apps' Mac
            // apps say which they still show.
            let files = FileManager.default
            for package in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
            where !((try? files.contentsOfDirectory(atPath: folder.appendingPathComponent("\(package)/requests").path)) ?? []).isEmpty {
                reload(package: package)
            }
            reconcile()
        }
    }

    /// Makes what the helper shows match the requests: places new or resized widgets and lets
    /// go of those no longer asked for. On `queue`.
    private func reconcile() {
        let files = FileManager.default
        var wanted: [String: Placed] = [:]
        var providers: [String: String] = [:]
        for package in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let requests = folder.appendingPathComponent("\(package)/requests")
            let kinds = Dictionary(manifest(package).compactMap { entry -> (String, String)? in
                guard let kind = entry["kind"] as? String, let provider = entry["provider"] as? String else { return nil }
                return (kind, provider)
            }, uniquingKeysWith: { first, _ in first })
            for name in (try? files.contentsOfDirectory(atPath: requests.path)) ?? [] {
                let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
                guard parts.count == 2, let provider = kinds[parts[0]],
                      let size = try? String(contentsOf: requests.appendingPathComponent(name), encoding: .utf8),
                      case let numbers = size.split(separator: "x").compactMap({ Int($0) }), numbers.count == 2,
                      (1...2000).contains(numbers[0]), (1...2000).contains(numbers[1]) else { continue }
                let key = "\(package)|\(parts[0])|\(parts[1])"
                wanted[key] = Placed(width: numbers[0], height: numbers[1])
                providers[key] = provider
            }
        }
        for (key, size) in wanted where placed[key] != size {
            send?(["placeWidget": key, "provider": providers[key] ?? "", "width": size.width, "height": size.height])
            placed[key] = size
        }
        for key in placed.keys where wanted[key] == nil {
            send?(["removeWidget": key])
            placed[key] = nil
        }
    }

    // MARK: - Pictures

    /// A new picture of a placed widget, from the helper.
    func received(key: String, png: Data) {
        queue.async { [self] in
            let parts = key.split(separator: "|").map(String.init)
            guard parts.count == 3, placed[key] != nil else { return }
            let app = folder.appendingPathComponent(parts[0])
            try? Self.trimmed(png).write(to: app.appendingPathComponent("\(parts[1])-\(parts[2]).png"), options: .atomic)
            reload(package: parts[0])
        }
    }

    /// Asks the Mac to redraw the app's widgets, by running its Mac app for a moment, as only an
    /// extension's own app may. At most every `reloadInterval`; one asked for meanwhile follows.
    private func reload(package: String) {
        let since = Date().timeIntervalSince(lastReload[package] ?? .distantPast)
        guard since >= Self.reloadInterval else {
            guard reloadQueued.insert(package).inserted else { return }
            queue.asyncAfter(deadline: .now() + Self.reloadInterval - since) { [self] in
                reloadQueued.remove(package)
                reload(package: package)
            }
            return
        }
        lastReload[package] = Date()
        guard let app = AppShortcuts.bundle(of: package),
              let program = Bundle(url: app)?.executableURL else { return }
        let process = Process()
        process.executableURL = program
        process.arguments = [Self.reloadArgument]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // The widgets the Mac still shows; a request for any other is gone with it.
        guard let shown = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
        let still = Set(shown.compactMap { entry in entry["kind"].flatMap { kind in entry["family"].map { "\(kind)-\($0)" } } })
        let requests = folder.appendingPathComponent("\(package)/requests")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: requests.path)) ?? [] where !still.contains(name) {
            try? FileManager.default.removeItem(at: requests.appendingPathComponent(name))
        }
    }

    static let reloadArgument = "--reload-widgets"
}
