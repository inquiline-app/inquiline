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
    /// the main thread, with the installed apps and their versions. Returns whether any changed.
    @discardableResult
    func updateManifests(packages: [String], versions: [String: String]) -> Bool {
        var changed = false
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        for package in packages where package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil {
            let app = folder.appendingPathComponent(package)
            let source = app.appendingPathComponent("version")
            // The manifest's own format too, so a new Inquiline writes it again.
            let version = "5 " + (versions[package] ?? "")
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
                    write(preview, named: "\(kind)-preview", in: app)
                    entry["preview"] = "\(kind)-preview.png"
                }
                manifest.append(entry)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: manifest) else { continue }
            try? data.write(to: app.appendingPathComponent("manifest.json"), options: .atomic)
            try? version.write(to: source, atomically: true, encoding: .utf8)
            changed = true
        }
        // An app Android no longer has takes its widgets with it.
        for gone in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where !packages.contains(gone) {
            try? files.removeItem(at: folder.appendingPathComponent(gone))
        }
        return changed
    }

    /// The Mac's widget sizes in points, which are dp in Android.
    private static let familySizes: [(name: String, width: Double, height: Double)] = [
        ("small", 170, 170), ("medium", 364, 170), ("large", 364, 382),
    ]

    /// The Mac sizes a widget looks right in, from its own default size, as Android lays it out
    /// first: never smaller than that, as it would be cut; one it doesn't resize toward only a
    /// little larger; and of a shape close to its own, as what it says about resizing often isn't
    /// what its layout does. When none quite is, the closest in shape it fits.
    private func families(_ widget: [String: Any]) -> [String] {
        let mode = widget["resizeMode"] as? Int ?? 0
        let width = Double(max(widget["minWidth"] as? Int ?? 1, 1)), height = Double(max(widget["minHeight"] as? Int ?? 1, 1))
        let fits = Self.familySizes.filter { $0.width >= width * 0.95 && $0.height >= height * 0.95 }
        func shape(_ family: (name: String, width: Double, height: Double)) -> Double {
            abs(log(family.width / family.height / (width / height)))
        }
        let right = fits.filter { family in
            (mode & 1 != 0 || family.width <= width * 1.7) && (mode & 2 != 0 || family.height <= height * 1.7) && shape(family) <= 0.5
        }
        if !right.isEmpty { return right.map(\.name) }
        return fits.min { shape($0) < shape($1) }.map { [$0.name] } ?? []
    }

    /// The picture without the transparent edges Android leaves around a widget, so the Mac
    /// can fit what's drawn to its box, and the widget's own background colour, as "rrggbb":
    /// the commonest opaque colour along the middles of its edges (its corners are rounded).
    static func trimmed(_ png: Data) -> (png: Data, color: String?) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (png, nil) }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return (png, nil) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 8 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return (png, nil) }
        var counts: [Int: Int] = [:]
        func sample(_ x: Int, _ y: Int) {
            let i = (y * width + x) * 4
            guard pixels[i + 3] >= 250 else { return }
            counts[Int(pixels[i] >> 3) << 10 | Int(pixels[i + 1] >> 3) << 5 | Int(pixels[i + 2] >> 3), default: 0] += 1
        }
        let w = right - left, h = bottom - top
        for x in stride(from: left + w / 4, to: right - w / 4, by: 1) { sample(x, top + 2); sample(x, bottom - 2) }
        for y in stride(from: top + h / 4, to: bottom - h / 4, by: 1) { sample(left + 2, y); sample(right - 2, y) }
        let color = counts.max { $0.value < $1.value }.map { key, _ in
            String(format: "%02x%02x%02x", (key >> 10 & 31) << 3 | 4, (key >> 5 & 31) << 3 | 4, (key & 31) << 3 | 4)
        }
        guard w + 1 < width || h + 1 < height,
              let cropped = image.cropping(to: CGRect(x: left, y: top, width: w + 1, height: h + 1)) else { return (png, color) }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return (png, color) }
        CGImageDestinationAddImage(destination, cropped, nil)
        return (CGImageDestinationFinalize(destination) ? out as Data : png, color)
    }

    /// Writes a picture and its background colour beside it, for the extension.
    private func write(_ png: Data, named name: String, in app: URL) {
        let picture = Self.trimmed(png)
        try? picture.png.write(to: app.appendingPathComponent("\(name).png"), options: .atomic)
        try? (picture.color ?? "").write(to: app.appendingPathComponent("\(name).color"), atomically: true, encoding: .utf8)
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
            // Android is up, well after its apps' Mac apps were written at launch.
            AppShortcuts.registerWidgets()
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
            write(png, named: "\(parts[1])-\(parts[2])", in: app)
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
