import AppKit
import UserNotifications

/// Android's notifications in the Mac's Notification Center, as a phone shows them.
///
/// A small app inside Android (Scripts/vm/notifications-agent) reads them with Android's
/// notification access and hands them over adb, which only Inquiline holds. What Android would
/// alert with, from apps the user let post notifications, shows on the Mac; clicking one opens
/// its app. Android keeps them coming while it rests (EngineControl).
/// Nothing of what they say is logged or kept.
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()

    private static let agent = "io.github.inquiline.notifications"
    private static let agentVersion = 1
    private static let socket = "localabstract:inquiline-notifications"

    /// Opens an app's window, given its package.
    var openApp: ((String) -> Void)?
    /// The app's name and icon, given its package, when Inquiline knows the app.
    var appInfo: ((String) -> (label: String, icon: NSImage)?)?

    private let queue = DispatchQueue(label: "inquiline.notifications")
    private var connection: Int32 = -1
    private var connecting = false
    /// What each shown notification said, so an update that changes nothing doesn't alert again.
    private var shown: [String: String] = [:]
    private var iconFiles: [String: URL] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called whenever Android is ready; connects once, and again after Android restarts.
    func start() {
        queue.async { [self] in
            guard connection < 0, !connecting else { return }
            connecting = true
            defer { connecting = false }
            do {
                try installAgentIfNeeded()
                connection = try connect()
            } catch {
                AppLog.write("Notifications aren't available: \(error.localizedDescription)")
                return
            }
            let fd = connection
            Thread.detachNewThread { [self] in
                read(from: fd)
                queue.async { [self] in
                    if connection == fd { connection = -1 }
                    close(fd)
                }
            }
        }
    }

    private func installAgentIfNeeded() throws {
        let installed = (try? AdbClient.shell("pm list packages --show-versioncode \(Self.agent)")) ?? ""
        if !installed.contains("versionCode:\(Self.agentVersion)") {
            guard let apk = Bundle.main.url(forResource: "inquiline-notifications", withExtension: "apk"),
                  let size = try apk.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { throw RuntimeError("The notifications helper is missing from the app bundle.") }
            let result = try AdbClient.exec("cmd package install -S \(size) -r", input: apk)
            guard result.contains("Success") else { throw RuntimeError("Could not add the notifications helper.") }
        }
        _ = try AdbClient.shell("cmd notification allow_listener \(Self.agent)/.Listener")
    }

    /// Android binds the agent a moment after it's allowed, so it's asked a few times.
    private func connect() throws -> Int32 {
        for _ in 0..<20 {
            if let fd = try? AdbClient.open(Self.socket) {
                // adb opens a stream to a socket nobody listens on and closes it at once.
                var probe = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&probe, 1, 300) == 0 { return fd }
                close(fd)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw RuntimeError("The notifications helper didn't answer.")
    }

    private func read(from fd: Int32) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while case let count = Darwin.read(fd, &chunk, chunk.count), count > 0 {
            buffer += chunk[..<count]
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    DispatchQueue.main.async { self.handle(message) }
                }
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        let center = UNUserNotificationCenter.current()
        if let key = message["removed"] as? String {
            shown[key] = nil
            center.removeDeliveredNotifications(withIdentifiers: [key])
            return
        }
        guard let key = message["posted"] as? String, let package = message["package"] as? String else { return }
        let title = message["title"] as? String ?? ""
        let text = message["text"] as? String ?? ""
        let said = title + "\n" + text
        // An app that updates a notification in place, as a chat adding a message, alerts
        // again unless it asked to alert once.
        if let before = shown[key], before == said || message["silent"] as? Bool == true { return }
        shown[key] = said

        let info = appInfo?(package)
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? (info?.label ?? "") : title
        if !title.isEmpty, let label = info?.label { content.subtitle = label }
        content.body = text
        content.sound = .default
        content.threadIdentifier = package
        content.userInfo = ["key": key, "package": package]
        if let icon = info?.icon, let file = iconFile(package: package, icon: icon),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: file) {
            content.attachments = [attachment]
        }
        // The Mac asks the user once, when the first notification arrives.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    /// A notification takes its picture from a file, which it moves into its own store, so each
    /// gets a fresh copy.
    private func iconFile(package: String, icon: NSImage) -> URL? {
        guard let tiff = icon.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inquiline-notification-icons")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".png")
        return (try? png.write(to: file)) != nil ? file : nil
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let package = info["package"] as? String {
            openApp?(package)
        }
        completionHandler()
    }
}
