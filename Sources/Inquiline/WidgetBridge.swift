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
    /// The Mac's widget sizes in points, which are dp in Android, for which sizes a widget offers.
    private static let familySizes: [(name: String, width: Int, height: Int)] = [
        ("small", 170, 170), ("medium", 364, 170), ("large", 364, 382),
    ]
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
            let version = "2 " + (versions[package] ?? "")
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
                    try? preview.write(to: app.appendingPathComponent("\(kind)-preview.png"))
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

    /// The Mac sizes a widget fits: its smallest size, or the smallest it resizes to, in dp.
    private func families(_ widget: [String: Any]) -> [String] {
        let mode = widget["resizeMode"] as? Int ?? 0
        func smallest(_ plain: String, _ resized: String, axis: Int) -> Int {
            let size = widget[plain] as? Int ?? 0
            let resize = widget[resized] as? Int ?? 0
            return mode & axis != 0 && resize > 0 ? min(size, resize) : size
        }
        let width = smallest("minWidth", "minResizeWidth", axis: 1)
        let height = smallest("minHeight", "minResizeHeight", axis: 2)
        let fits = Self.familySizes.filter { width <= $0.width && height <= $0.height }
        // One that resizes both ways fills any size; another only the one closest to its shape,
        // where it doesn't sit small in a large box (a search bar is a wide widget).
        if mode & 3 == 3 { return fits.map(\.name) }
        let shape = Double(max(widget["minWidth"] as? Int ?? 1, 1)) / Double(max(widget["minHeight"] as? Int ?? 1, 1))
        let closest = fits.min { abs(log(Double($0.width) / Double($0.height) / shape)) < abs(log(Double($1.width) / Double($1.height) / shape)) }
        return closest.map { [$0.name] } ?? []
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
            try? png.write(to: app.appendingPathComponent("\(parts[1])-\(parts[2]).png"), options: .atomic)
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
