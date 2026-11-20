import AppKit

/// All the Android apps in the Dock, as one stack named Android, which opens as a grid, as the
/// Dock's own stacks do: a folder Inquiline keeps, of links to each app where it is, in the
/// Applications folder, so Spotlight and Launchpad still list each app once. Only when the
/// user turns it on, from Inquiline's menu.
enum AndroidDock {
    static var folder: URL { AndroidRuntime.shared.home.appendingPathComponent("Android", isDirectory: true) }

    /// Whether the stack is in the Dock.
    static var isShown: Bool {
        tiles().contains(where: isOurs)
    }

    static func show(_ shown: Bool, apps: [URL]) {
        var tiles = tiles().filter { !isOurs($0) }
        if shown {
            update(apps: apps, always: true)
            NSWorkspace.shared.setIcon(NSApp.applicationIconImage, forFile: folder.path, options: [])
            tiles.append([
                "tile-type": "directory-tile",
                "tile-data": [
                    "file-data": ["_CFURLString": folder.absoluteString, "_CFURLStringType": 15],
                    "file-label": "Android",
                    "file-type": 2,
                    // By name, shown as its folder, opening as a grid.
                    "arrangement": 1,
                    "displayas": 1,
                    "showas": 2,
                    "preferreditemsize": -1,
                ] as [String: Any],
            ])
        }
        CFPreferencesSetAppValue("persistent-others" as CFString, tiles as CFArray, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        // The Dock reads its settings as it starts.
        let dock = Process()
        dock.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        dock.arguments = ["Dock"]
        try? dock.run()
        if !shown { try? FileManager.default.removeItem(at: folder) }
    }

    /// A link for each app, by its name, as apps come and go; kept only while the stack is shown.
    static func update(apps: [URL], always: Bool = false) {
        let files = FileManager.default
        guard always || files.fileExists(atPath: folder.path) else { return }
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let wanted = Dictionary(apps.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        let present = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in present where name.hasSuffix(".app") {
            let link = folder.appendingPathComponent(name)
            if let target = wanted[name], (try? files.destinationOfSymbolicLink(atPath: link.path)) == target.path { continue }
            try? files.removeItem(at: link)
        }
        for (name, app) in wanted where !files.fileExists(atPath: folder.appendingPathComponent(name).path) {
            try? files.createSymbolicLink(at: folder.appendingPathComponent(name), withDestinationURL: app)
        }
    }

    private static func tiles() -> [[String: Any]] {
        CFPreferencesCopyAppValue("persistent-others" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
    }

    private static func isOurs(_ tile: [String: Any]) -> Bool {
        let data = tile["tile-data"] as? [String: Any]
        let file = data?["file-data"] as? [String: Any]
        guard let string = file?["_CFURLString"] as? String, let url = URL(string: string) else { return false }
        return url.standardizedFileURL.path == folder.standardizedFileURL.path
    }
}
