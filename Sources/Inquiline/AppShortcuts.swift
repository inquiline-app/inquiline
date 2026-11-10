import AppKit
import CryptoKit

/// Each Android app is a Mac app in the Applications folder, found in Finder, Spotlight and
/// Launchpad. It runs a copy of this program, which opens that one Android app in its own
/// window (see AppProcess), and moving it to the Trash removes the app.
enum AppShortcuts {
    struct App {
        let package: String
        let label: String
        let orientation: AppOrientation
        let icon: NSImage
    }

    static let packageKey = "InquilinePackage"
    static let mainIdentifier = "io.github.inquiline-app.Inquiline"

    /// Which program an app was made from. Its copy can't be compared byte for byte, as each
    /// app is signed on its own.
    private static let programKey = "InquilineProgram"

    /// A fingerprint of Inquiline's program and the server files apps take from it.
    static func programFingerprint(of bundle: Bundle) -> String? {
        guard let program = bundle.executableURL,
              let server = bundle.url(forResource: "scrcpy-server", withExtension: nil),
              let frames = bundle.url(forResource: "libinquiline-frames", withExtension: "so")
        else { return nil }
        var hash = SHA256()
        for file in [program, server, frames] {
            guard let data = try? Data(contentsOf: file) else { return nil }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Inquiline was updated while this app wasn't open, so it still has the old program.
    /// It's brought up to date on its next launch, as Inquiline does once it quits.
    static func isOutdated() -> Bool {
        guard let mainURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainIdentifier),
              let main = Bundle(url: mainURL),
              let current = programFingerprint(of: main)
        else { return false }
        return Bundle.main.infoDictionary?[programKey] as? String != current
    }
    static let orientationKey = "InquilineOrientation"
    static let homeKey = "InquilineHome"
    /// Where new apps go: the Applications folder, next to every other app, as iPhone apps on a
    /// Mac are. An account that can't write there gets a folder in its own Applications folder.
    static let folder: URL = AndroidRuntime.testHome?.appendingPathComponent("Apps")
        ?? (FileManager.default.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications") : ownFolder)
    private static let ownFolder = AndroidRuntime.testHome?.appendingPathComponent("Apps")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Inquiline Apps")
    /// Called on a background queue with the package of an app the user moved to the Trash.
    static var onRemoved: ((String) -> Void)?

    private static let queue = DispatchQueue(label: "inquiline.shortcuts")
    /// Where each app is, by package, as bookmarks: like Finder's aliases they follow an app the
    /// user moves, so it can live in any folder they like.
    /// A test copy (INQUILINE_HOME) keeps its own, as it shares Inquiline's settings.
    private static let placesKey = "AppPlaces" + (AndroidRuntime.testHome.map { " " + $0.path } ?? "")
    private static var places: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: placesKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: placesKey) }
    }
    private static var watches: [DispatchSourceFileSystemObject] = []

    /// Brings the apps in line with the library: one app per Android app, with its name and
    /// icon, where it is or else in `folder`. Only Inquiline's own apps are ever touched.
    /// `done` is called on the main thread with where each one is.
    static func sync(_ apps: [App], done: (([String: URL]) -> Void)? = nil) {
        guard let fingerprint = programFingerprint(of: Bundle.main),
              let program = Bundle.main.executableURL,
              let server = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil),
              let frames = Bundle.main.url(forResource: "libinquiline-frames", withExtension: "so")
        else { return }
        queue.async {
            let files = FileManager.default
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            var found = locate()
            var wanted = Dictionary(apps.map { ($0.package, $0) }, uniquingKeysWith: { first, _ in first })
            // One moved to the Trash, or deleted, while Inquiline wasn't running is removed, not
            // made again: Inquiline only watches while it runs.
            let trashed = places.keys.filter { wanted[$0] != nil && found[$0] == nil && isGone($0) }
            trashed.forEach { wanted[$0] = nil }
            // An app Android no longer has goes, wherever it is.
            for (package, bundle) in found where wanted[package] == nil {
                try? files.removeItem(at: bundle)
                found[package] = nil
            }
            var locations: [String: URL] = [:]
            var kept: [String: Data] = [:]
            for (package, app) in wanted {
                var bundle = found[package] ?? place(for: app, in: folder)
                // One left in Inquiline's own folder moves to the Applications folder once it can.
                if found[package] != nil, bundle.deletingLastPathComponent() == ownFolder, folder != ownFolder {
                    let moved = place(for: app, in: folder)
                    if (try? files.moveItem(at: bundle, to: moved)) != nil { bundle = moved }
                }
                // A renamed app takes its new name where it is.
                let named = place(for: app, in: bundle.deletingLastPathComponent())
                if named != bundle, files.fileExists(atPath: bundle.path), (try? files.moveItem(at: bundle, to: named)) != nil {
                    bundle = named
                }
                if write(app, to: bundle, program: program, server: server, frames: frames, fingerprint: fingerprint) {
                    locations[package] = bundle
                    kept[package] = try? bundle.bookmarkData()
                }
            }
            places = kept
            trashed.forEach { onRemoved?($0) }
            // Inquiline's own folder goes once it has no apps left; Finder's files in it don't count.
            if folder != ownFolder,
               let left = try? files.contentsOfDirectory(atPath: ownFolder.path),
               left.allSatisfy({ $0.hasPrefix(".") || $0 == "Icon\r" }) {
                try? files.removeItem(at: ownFolder)
            }
            watchPlaces(locations.values)
            if let done { DispatchQueue.main.async { done(locations) } }
        }
    }

    /// The package of an app Inquiline made, or nil for any other.
    private static func package(of bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?[packageKey] as? String
    }

    /// Where Inquiline's apps are now: where their bookmarks lead, and any in the folders they
    /// go in, as apps from before the bookmarks were kept.
    private static func locate() -> [String: URL] {
        var found: [String: URL] = [:]
        for (package, data) in places {
            var stale = false
            if let bundle = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
               !bundle.path.contains("/.Trash/"), self.package(of: bundle) == package {
                found[package] = bundle
            }
        }
        for directory in Set([folder, ownFolder]) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".app") {
                let bundle = directory.appendingPathComponent(name)
                if let package = package(of: bundle), found[package] == nil { found[package] = bundle }
            }
        }
        return found
    }

    /// The app's name in `directory`, never another app's: one of the same name that isn't
    /// Inquiline's, such as a Mac version of the game, keeps its place.
    private static func place(for app: App, in directory: URL) -> URL {
        let name = app.label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        for candidate in [name, "\(name) (Android)"] {
            let bundle = directory.appendingPathComponent(candidate + ".app")
            let owner = package(of: bundle)
            if !FileManager.default.fileExists(atPath: bundle.path) || owner == app.package { return bundle }
        }
        return directory.appendingPathComponent("\(name) (\(app.package)).app")
    }

    /// As on a Mac, an app the user moves to the Trash is one they want gone; moving it
    /// anywhere else isn't. The folders the apps are in are watched for that.
    private static func watchPlaces(_ bundles: Dictionary<String, URL>.Values) {
        watches.forEach { $0.cancel() }
        watches = []
        for directory in Set(bundles.map { $0.deletingLastPathComponent() } + [folder]) {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: queue)
            // Replacing an app, as an update does, takes it away for an instant, so this looks later.
            source.setEventHandler { queue.asyncAfter(deadline: .now() + 2) { checkRemoved() } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watches.append(source)
        }
    }

    /// Whether the app a bookmark leads to is in the Trash or no longer exists.
    private static func isGone(_ package: String) -> Bool {
        guard let data = places[package] else { return false }
        var stale = false
        guard let bundle = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
        else { return true }
        return bundle.path.contains("/.Trash/") || !FileManager.default.fileExists(atPath: bundle.path)
    }

    private static func checkRemoved() {
        var kept = places
        var moved = false
        for (package, data) in places {
            var stale = false
            let bundle = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            guard let bundle, !bundle.path.contains("/.Trash/"), FileManager.default.fileExists(atPath: bundle.path) else {
                kept[package] = nil
                onRemoved?(package)
                continue
            }
            if stale, let fresh = try? bundle.bookmarkData() {
                kept[package] = fresh
                moved = true
            }
        }
        places = kept
        // A moved app is watched where it went.
        if moved { watchPlaces(locate().values) }
    }

    /// Returns whether the app is in place.
    private static func write(_ app: App, to bundle: URL, program: URL, server: URL, frames: URL, fingerprint: String) -> Bool {
        let files = FileManager.default
        let contents = bundle.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/app")
        let iconFile = contents.appendingPathComponent("Resources/AppIcon.icns")
        let serverFile = contents.appendingPathComponent("Resources/scrcpy-server")
        let framesFile = contents.appendingPathComponent("Resources/libinquiline-frames.so")
        let infoFile = contents.appendingPathComponent("Info.plist")
        let icon = icns(app.icon)
        let info: NSMutableDictionary = [
            "CFBundleExecutable": "app",
            // Bundle identifiers can't hold underscores.
            "CFBundleIdentifier": "io.github.inquiline-app.app." + app.package.replacingOccurrences(of: "_", with: "-"),
            "CFBundleName": app.label,
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            packageKey: app.package,
            orientationKey: app.orientation.rawValue,
            programKey: fingerprint,
        ]
        if let home = AndroidRuntime.testHome { info.setValue(home.path, forKey: homeKey) }
        // An update of Inquiline brings a new program, which its apps take on too, but not
        // while one is open: replacing its bundle would end it. It's updated once it quits.
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        if files.fileExists(atPath: bundle.path),
           !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            return true
        }
        // The fingerprint in its Info.plist says whether it has the current program.
        if NSDictionary(contentsOf: infoFile) == info, (try? Data(contentsOf: iconFile)) == icon {
            return true
        }

        let existed = files.fileExists(atPath: bundle.path)
        try? files.removeItem(at: bundle)
        do {
            try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createDirectory(at: iconFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: program, to: executable)
            try files.copyItem(at: server, to: serverFile)
            try files.copyItem(at: frames, to: framesFile)
            try icon.write(to: iconFile)
            try info.write(to: infoFile)
        } catch {
            try? files.removeItem(at: bundle)
            return false
        }
        // Apple silicon only runs signed code; an ad hoc signature is enough for a local app.
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", bundle.path]
        codesign.standardError = FileHandle.nullDevice
        try? codesign.run()
        codesign.waitUntilExit()
        LSRegisterURL(bundle as CFURL, existed)
        return true
    }

    /// Android icons are drawn on macOS's icon grid: a rounded square of 824 in 1024.
    private static func icns(_ image: NSImage) -> Data {
        var entries = Data()
        for (type, size) in [("ic09", 512), ("ic10", 1024)] {
            let png = render(image, size: size)
            entries.append(Data(type.utf8))
            entries.appendBigEndian(UInt32(png.count + 8))
            entries.append(png)
        }
        var data = Data("icns".utf8)
        data.appendBigEndian(UInt32(entries.count + 8))
        data.append(entries)
        return data
    }

    private static func render(_ image: NSImage, size: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let scale = CGFloat(size) / 1024
        let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale).addClip()
        image.draw(in: body)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
