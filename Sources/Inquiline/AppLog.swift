import Foundation

/// Inquiline's own log, for finding why something failed: what Android and the app windows
/// did, and the errors they met. ~/Library/Logs/Inquiline/inquiline.log, with the one before
/// as inquiline.old.log, about 8 MB at most. Inquiline and every app window write to it.
///
/// It holds what happened, never what the user has: no file names or paths of theirs, nothing
/// typed or copied, no accounts. Every line still goes through `Private.redact` first.
enum AppLog {
    static var folder: URL {
        AndroidRuntime.testHome?.appendingPathComponent("Logs")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Inquiline")
    }

    private static let queue = DispatchQueue(label: "inquiline.log")
    private static let limit = 4 << 20
    /// Which process wrote a line: Inquiline, or the app a window shows.
    static var source = "Inquiline"

    static func write(_ message: String) {
        let time = Date()
        queue.async {
            let files = FileManager.default
            let log = folder.appendingPathComponent("inquiline.log")
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter.string(from: time, timeZone: .current,
                                                    formatOptions: [.withFullDate, .withFullTime, .withFractionalSeconds])
            let line = "\(stamp) [\(source)] \(Private.redact(message))\n"
            // Appending whole lines keeps those of several processes apart.
            let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { return }
            _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
            let size = lseek(fd, 0, SEEK_END)
            close(fd)
            if size > limit {
                let old = folder.appendingPathComponent("inquiline.old.log")
                _ = rename(log.path, old.path)
            }
        }
    }
}

/// Takes what could say who the user is out of logs: their name in paths, e-mail addresses,
/// web addresses beyond the site, IP and hardware addresses, long numbers and keys.
enum Private {
    private static let rules: [(NSRegularExpression, String)] = [
        // Not Android's own names, such as apex@com.android.wifi or system@app@Foo.apk@classes.dex.
        (#"(?<![@A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@(?!(?:com|org|android|net|google|vendor|system)\.)(?:[A-Za-z][A-Za-z0-9-]*\.){1,3}"#
            + #"(?!(?:apk|jar|so|dex|odex|vdex|oat|art|xml|rc|prop|json|bin|img)\b)[A-Za-z]{2,6}\b(?![@.\w-])"#, "<e-mail>"),
        // A web address keeps its site; its path and query can carry names and keys.
        (#"\b([a-zA-Z][a-zA-Z0-9+.-]*://[^/\s"'<>]+)[^\s"'<>]*"#, "$1/…"),
        (#"\b(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}\b"#, "<hardware address>"),
        // Addresses on the internet; those inside the VM and the Mac say nothing about the user.
        (#"\b(?!(?:0|10|127)\.)(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
        (#"\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b"#, "<ip>"),
        // Phone numbers, card and device numbers.
        (#"\+\d[\d ()-]{7,}\d"#, "<number>"),
        (#"\b\d{10,}\b"#, "<number>"),
        // Keys, tokens and IDs: long runs of hex, or of letters and digits mixed.
        (#"\b[0-9a-fA-F]{16,}\b"#, "<id>"),
        (#"(?=[A-Za-z0-9_+=-]*[0-9])(?=[A-Za-z0-9_+=-]*[A-Za-z])[A-Za-z0-9_+=-]{32,}"#, "<id>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ text: String) -> String {
        var text = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "/Users/" + NSUserName(), with: "/Users/user")
        let full = NSFullUserName()
        if full.count > 2 { text = text.replacingOccurrences(of: full, with: "<name>") }
        let short = NSUserName()
        if short.count > 2 { text = text.replacingOccurrences(of: short, with: "<user>") }
        for (rule, template) in rules {
            text = rule.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text
    }
}
