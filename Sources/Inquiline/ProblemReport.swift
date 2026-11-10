import AppKit

/// "Report a Problem…": gathers what helps find a problem into one zip the user can look at,
/// then opens the GitHub form with their Mac filled in, to drag the zip into. Nothing is sent
/// by Inquiline itself. Every log in it goes through `Private.redact`, so it holds what
/// happened, not who the user is.
enum ProblemReport {
    static let form = "https://github.com/inquiline-app/inquiline/issues/new"

    /// Blocks while it reads Android's log, so call it off the main thread.
    static func make() throws -> URL {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let logs = AppLog.folder
        let name = "Inquiline Report " + ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime]).replacingOccurrences(of: ":", with: "")
        let work = files.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work.deletingLastPathComponent()) }

        try anonymized(info()).write(to: work.appendingPathComponent("mac.txt"), atomically: true, encoding: .utf8)
        for log in ["inquiline.old.log", "inquiline.log", "engine.old.log", "engine.log"] {
            if let text = try? String(contentsOf: logs.appendingPathComponent(log), encoding: .utf8) {
                try Private.redact(text).write(to: work.appendingPathComponent(log), atomically: true, encoding: .utf8)
            }
        }
        androidLog(to: work.appendingPathComponent("android.log"))
        // macOS's crash reports of the last week, for Inquiline, its engine and its apps.
        let reports = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let crashes = ((try? files.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date, String)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      date > weekAgo, let text = try? String(contentsOf: url, encoding: .utf8),
                      text.prefix(2000).contains("io.github.inquiline-app") || url.lastPathComponent.hasPrefix("Inquiline")
                else { return nil }
                return (url, date, text)
            }
            .sorted { $0.1 > $1.1 }.prefix(10)
        if !crashes.isEmpty {
            let folder = work.appendingPathComponent("crashes")
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for (url, _, text) in crashes {
                try anonymized(text).write(to: folder.appendingPathComponent(url.lastPathComponent), atomically: true, encoding: .utf8)
            }
        }

        let outFolder = logs.appendingPathComponent("Reports")
        try files.createDirectory(at: outFolder, withIntermediateDirectories: true)
        // Only the newest report is kept.
        for old in (try? files.contentsOfDirectory(at: outFolder, includingPropertiesForKeys: nil)) ?? [] {
            try? files.removeItem(at: old)
        }
        let zip = outFolder.appendingPathComponent(name + ".zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", work.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw RuntimeError("Couldn't make the report's zip.") }
        return zip
    }

    /// Android's log as it keeps it on its disk (AndroidRuntime.keepLogs), oldest first; if it
    /// hasn't kept one yet, what's still in its memory. Android needn't be running for the rest.
    private static func androidLog(to file: URL) {
        guard AndroidRuntime.shared.isRunning else { return }
        let raw = file.appendingPathExtension("raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        try? AdbClient.download("su 0 sh -c 'cd /data/misc/logd 2>/dev/null && cat $(ls -r logcat.[0-9]* 2>/dev/null) logcat 2>/dev/null "
            + "|| logcat -d -b main,system,crash,events'", to: raw)
        guard let data = try? Data(contentsOf: raw), !data.isEmpty else { return }
        try? Private.redact(String(decoding: data, as: UTF8.self)).write(to: file, atomically: true, encoding: .utf8)
    }

    /// The Mac, as the form asks for it.
    static var mac: String {
        "\(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string")), \(ProcessInfo.processInfo.physicalMemory >> 30) GB"
    }
    static var macOS: String {
        "macOS " + ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
    }
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static func formURL() -> URL {
        var parts = URLComponents(string: form)!
        parts.queryItems = [URLQueryItem(name: "template", value: "problem.yml"), URLQueryItem(name: "mac", value: mac),
                            URLQueryItem(name: "macos", value: macOS), URLQueryItem(name: "version", value: version)]
        return parts.url!
    }

    private static func info() -> String {
        let free = (try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        return """
        Mac: \(mac)
        \(macOS)
        Inquiline: \(version), at \(Bundle.main.bundlePath)
        Free disk space: \(free >> 30) GB
        Android: \(AndroidRuntime.shared.isRunning ? "running" : "stopped")
        Made: \(Date())

        """
    }

    /// The user's name, as it appears in paths, becomes "user".
    private static func anonymized(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "/Users/" + NSUserName(), with: "/Users/user")
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &value, &size, nil, 0)
        return String(cString: value)
    }
}
