import Foundation
import UniformTypeIdentifiers

/// An app as download sites give it: one APK, or a ZIP of a base APK and the parts it was split
/// into for each processor, screen and language (.xapk, .apkm, .apks, .apkx), with a game's own
/// data (OBB) in an XAPK. Android takes the parts this device needs, as Play Store sends only those.
struct ApkBundle {
    /// One app in the file: its base APK first, then its parts.
    struct App {
        let manifest: ApkManifest
        let apks: [URL]
        /// Game data files, which go to Android/obb/<package>.
        let obbs: [URL]
    }

    /// The file types Inquiline opens, besides a plain APK; a ZIP only when chosen in Add APK.
    static let bundleExtensions = ["xapk", "apkm", "apks", "apkx"]
    static var contentTypes: [UTType] {
        (["apk"] + bundleExtensions).compactMap { UTType(filenameExtension: $0) } + [.zip]
    }

    let apps: [App]
    /// Where a bundle was unpacked, removed by `remove()`.
    private let folder: URL?

    init(file: URL) throws {
        let name = file.lastPathComponent
        if file.pathExtension.lowercased() == "apk" {
            guard let manifest = ApkManifest(apk: file) else { throw RuntimeError("\(name) is not a valid APK.") }
            apps = [App(manifest: manifest, apks: [file], obbs: [])]
            folder = nil
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inquiline-bundle-\(UUID().uuidString)")
        self.folder = folder
        do {
            try Self.unzip(file, to: folder)
            apps = try Self.apps(in: folder, name: name)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func remove() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private static func unzip(_ file: URL, to folder: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", file.path, folder.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw RuntimeError("\(file.lastPathComponent) couldn't be opened. If it's an older APKM file, which is encrypted, download it again.")
        }
    }

    private static func apps(in folder: URL, name: String) throws -> [App] {
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        var parts = files.filter { $0.pathExtension.lowercased() == "apk" }
            .compactMap { url in ApkManifest(apk: url).map { (url: url, manifest: $0) } }
        // A bundletool .apks file has whole APKs for older Androids besides the parts.
        if parts.contains(where: { $0.manifest.split != nil }) {
            parts.removeAll { $0.manifest.split == nil && $0.url.pathComponents.contains("standalones") }
        }
        let bases = parts.filter { $0.manifest.split == nil }
        guard !bases.isEmpty else {
            throw RuntimeError(parts.isEmpty ? "\(name) has no Android app in it." : "\(name) has parts of an app but not the app itself.")
        }
        return bases.map { base in
            let package = base.manifest.package
            let splits = parts.filter { $0.manifest.package == package && $0.manifest.split != nil }
            let chosen = choose(splits.map { ($0.url, $0.manifest.split!) })
            let obbs = files.filter {
                $0.pathExtension.lowercased() == "obb" && $0.deletingLastPathComponent().lastPathComponent == package
            }
            return App(manifest: base.manifest, apks: [base.url] + chosen, obbs: obbs)
        }
    }

    private static let abis = ["armeabi", "armeabi_v7a", "arm64_v8a", "x86", "x86_64", "mips", "mips64"]
    private static let densities = ["ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240, "xhdpi": 320,
                                    "xxhdpi": 480, "xxxhdpi": 640]

    /// The parts this Android needs: the 64-bit ARM one of those for processors, the one for its
    /// screen of those for densities, every language and every feature.
    private static func choose(_ splits: [(url: URL, name: String)]) -> [URL] {
        func config(_ name: String) -> String? {
            // "config.arm64_v8a", or a feature's own, "feature.config.xhdpi"
            name.components(separatedBy: "config.").count > 1 ? name.components(separatedBy: "config.").last : nil
        }
        let screen = 320 // androidboot.redroid_dpi
        let offered = Set(splits.compactMap { config($0.name) }.filter { densities[$0] != nil })
        let density = offered.min { a, b in
            let (da, db) = (densities[a]!, densities[b]!)
            // The nearest at or above the screen's, as Android scales down better than up.
            return (da >= screen ? da - screen : 10000 + screen - da) < (db >= screen ? db - screen : 10000 + screen - db)
        }
        return splits.filter { split in
            guard let value = config(split.name) else { return true }
            if abis.contains(value) { return value == "arm64_v8a" }
            if densities[value] != nil { return value == density }
            return true
        }.map(\.url)
    }
}
