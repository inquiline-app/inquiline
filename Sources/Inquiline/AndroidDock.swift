import AppKit

/// All the Android apps in the Dock, as one stack named Inquiline Apps, which opens as a grid, as the
/// Dock's own stacks do: the folder the apps are in (AppShortcuts.folder). Only when the user
/// turns it on, from Inquiline's menu.
enum AndroidDock {
    private static var folder: URL { AppShortcuts.folder }
    private static let dock = "com.apple.dock" as CFString

    /// Whether the stack is in the Dock.
    static var isShown: Bool {
        tiles("persistent-others").contains { path(of: $0) == folder.standardizedFileURL.path }
    }

    static func show(_ shown: Bool) {
        var tiles = tiles("persistent-others").filter { path(of: $0) != folder.standardizedFileURL.path }
        if shown {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.setIcon(NSApp.applicationIconImage, forFile: folder.path, options: [])
            tiles.append([
                "tile-type": "directory-tile",
                "tile-data": [
                    "file-data": ["_CFURLString": folder.absoluteString, "_CFURLStringType": 15],
                    "file-label": folder.lastPathComponent,
                    "file-type": 2,
                    // By name, shown as its folder, opening as a grid.
                    "arrangement": 1,
                    "displayas": 1,
                    "showas": 2,
                    "preferreditemsize": -1,
                ] as [String: Any],
            ])
        }
        save("persistent-others", tiles)
        restart()
    }

    /// Apps that moved (AppShortcuts) stay in the Dock where the user kept them.
    static func follow(_ moves: [URL: URL]) {
        let paths = Dictionary(uniqueKeysWithValues: moves.map { ($0.key.standardizedFileURL.path, $0.value) })
        var changed = false
        for key in ["persistent-apps", "persistent-others"] {
            let tiles = tiles(key).map { tile -> [String: Any] in
                guard let old = path(of: tile), let new = paths[old] else { return tile }
                changed = true
                var tile = tile
                var data = tile["tile-data"] as? [String: Any] ?? [:]
                var file = data["file-data"] as? [String: Any] ?? [:]
                file["_CFURLString"] = new.absoluteString
                file["_CFURLStringType"] = 15
                // The Dock would find the old place again by its bookmark, and go back to it.
                for key in ["book", "_CFURLAliasData"] {
                    file[key] = nil
                    data[key] = nil
                }
                data["file-data"] = file
                tile["tile-data"] = data
                return tile
            }
            if changed { save(key, tiles) }
        }
        if changed { restart() }
    }

    private static func tiles(_ key: String) -> [[String: Any]] {
        CFPreferencesCopyAppValue(key as CFString, dock) as? [[String: Any]] ?? []
    }

    private static func save(_ key: String, _ tiles: [[String: Any]]) {
        CFPreferencesSetAppValue(key as CFString, tiles as CFArray, dock)
        CFPreferencesAppSynchronize(dock)
    }

    private static func path(of tile: [String: Any]) -> String? {
        let data = tile["tile-data"] as? [String: Any]
        let file = data?["file-data"] as? [String: Any]
        guard let string = file?["_CFURLString"] as? String, let url = URL(string: string) else { return nil }
        return url.standardizedFileURL.path
    }

    /// The Dock reads its settings as it starts.
    private static func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
