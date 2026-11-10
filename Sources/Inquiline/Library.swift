import AppKit

/// Which ways up an app can run, as its manifest declares.
enum AppOrientation: String, Codable {
    case portrait, landscape, both

    /// `screenOrientation` values from Android's ActivityInfo.
    init(screenOrientation: Int?) {
        switch screenOrientation {
        case 0, 6, 8, 11: self = .landscape
        case 1, 7, 9, 12: self = .portrait
        default: self = .both
        }
    }
}

struct LibraryApp: Codable {
    let package: String
    var label: String
    var orientation: AppOrientation?
}

/// The apps installed in the VM, kept on the Mac so the list and its icons are
/// available without booting Android. Use from the main thread.
final class Library {
    private(set) var apps: [LibraryApp] = []
    var onChange: (() -> Void)?

    private let fileURL: URL
    private let iconsURL: URL
    private var icons: [String: NSImage] = [:]

    init(home: URL) {
        fileURL = home.appendingPathComponent("library.json")
        iconsURL = home.appendingPathComponent("icons")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([LibraryApp].self, from: data) {
            apps = saved
        }
    }

    func add(_ info: ApkInfo) {
        if let index = apps.firstIndex(where: { $0.package == info.package }) {
            apps[index].label = info.label
            apps[index].orientation = info.orientation ?? apps[index].orientation
        } else {
            apps.append(LibraryApp(package: info.package, label: info.label, orientation: info.orientation))
            apps.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
        changed()
    }

    func app(package: String) -> LibraryApp? {
        apps.first { $0.package == package }
    }

    func remove(package: String) {
        apps.removeAll { $0.package == package }
        icons[package] = nil
        try? FileManager.default.removeItem(at: iconURL(package))
        changed()
    }

    func hasIcon(package: String) -> Bool {
        FileManager.default.fileExists(atPath: iconURL(package).path)
    }

    func setIcon(_ png: Data, package: String) {
        guard let image = NSImage(data: png) else { return }
        try? FileManager.default.createDirectory(at: iconsURL, withIntermediateDirectories: true)
        try? png.write(to: iconURL(package), options: .atomic)
        icons[package] = image
        changed()
    }

    func icon(package: String) -> NSImage {
        if let cached = icons[package] { return cached }
        if let image = NSImage(contentsOf: iconURL(package)) {
            icons[package] = image
            return image
        }
        return NSApp.applicationIconImage
    }

    private func iconURL(_ package: String) -> URL {
        iconsURL.appendingPathComponent("\(package).png")
    }

    private func changed() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(apps) {
            try? data.write(to: fileURL, options: .atomic)
        }
        onChange?()
    }
}
