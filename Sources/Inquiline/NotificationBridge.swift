import AppKit
import UserNotifications

/// Android's notifications in the Mac's Notification Center, as a phone shows them.
///
/// KDE Connect inside Android reads them and sends them to Inquiline (KDEConnect). They show
/// as the Mac's own notifications, by app; clicking one opens its app where the notification
/// points, as tapping it on a phone does; a chat's can be answered and an app's buttons pressed
/// from the Mac; and closing one closes it in Android too, and the other way round. Android keeps
/// them coming while it rests (EngineControl). Nothing of what they say is logged or kept.
///
/// The small app Inquiline keeps in Android (Scripts/vm/notifications-agent) opens a
/// notification's screen (Open) and carries the GPS and the desktop widgets, over adb.
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()

    static let agent = "io.github.inquiline.notifications"
    static let agentVersion = 50
    private static let socket = "localabstract:inquiline-notifications"

    /// Opens an app's window, given its package; with true, without starting the app, whose
    /// notification's screen starts there instead.
    var openApp: ((String, Bool) -> Void)?
    /// The argument an app's window gets when a notification opens it.
    static let fromNotification = "--from-notification"
    /// The app's name and icon, given its package, when Inquiline knows the app.
    var appInfo: ((String) -> (label: String, icon: NSImage)?)?

    private let queue = DispatchQueue(label: "inquiline.notifications")
    private var connection: Int32 = -1
    private var connecting = false
    /// What each shown notification said, so an update that changes nothing doesn't alert again.
    private var shown: [String: String] = [:]

    private static let replyCategory = "reply"
    private static let plainCategory = "plain"
    /// The categories registered so far: one per set of an app's buttons.
    private var categories: [String: UNNotificationCategory] = [:]
    /// The last answer written on the Mac, by app: the chat then adds it to its notification,
    /// which is nothing new for the user.
    private var sentReplies: [String: String] = [:]

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        LocationBridge.shared.send = { [weak self] in self?.send($0) }
        DesktopWidgets.shared.send = { [weak self] in self?.send($0) }
        _ = category(reply: false, actions: [])
        _ = category(reply: true, actions: [])
        KDEConnect.shared.received = { [weak self] type, body in
            DispatchQueue.main.async { self?.received(type, body) }
        }
    }

    /// The category for a notification with a reply box and these buttons, registered once.
    /// Closing any tells Android, which closes it there too.
    private func category(reply: Bool, actions: [String]) -> String {
        let identifier = ([reply ? Self.replyCategory : Self.plainCategory] + actions).joined(separator: "\u{1f}")
        if categories[identifier] == nil {
            var buttons: [UNNotificationAction] = []
            if reply {
                buttons.append(UNTextInputNotificationAction(identifier: Self.replyCategory, title: "Reply", options: [],
                                                             textInputButtonTitle: "Send", textInputPlaceholder: ""))
            }
            buttons += actions.map { UNNotificationAction(identifier: "action:" + $0, title: $0, options: []) }
            categories[identifier] = UNNotificationCategory(identifier: identifier, actions: buttons, intentIdentifiers: [],
                                                             options: [.customDismissAction])
            UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
        }
        return identifier
    }

    /// Called whenever Android is ready; connects once, and again after Android restarts.
    func start() {
        queue.async { [self] in
            guard connection < 0, !connecting else { return }
            connecting = true
            defer { connecting = false }
            KDEConnect.shared.start()
            do {
                try installAgentIfNeeded()
                connection = try connect()
            } catch {
                AppLog.write("Notifications aren't available: \(error.localizedDescription)")
                return
            }
            let fd = connection
            DispatchQueue.main.async { DesktopWidgets.shared.connected() }
            Thread.detachNewThread { [self] in
                read(from: fd)
                // No helper, no one asking where the Mac is.
                DispatchQueue.main.async { LocationBridge.shared.set(wanted: false) }
                queue.async { [self] in
                    if connection == fd { connection = -1 }
                    close(fd)
                }
                // The helper restarted, as when it's updated, while Android runs on: connect again.
                queue.asyncAfter(deadline: .now() + 3) { [self] in
                    if AndroidRuntime.shared.isRunning { start() }
                }
            }
        }
    }

    /// Runs `body` once the helper inside Android is there, which it also uses for other work.
    func withAgent(_ body: @escaping () -> Void) {
        queue.async { [self] in
            guard (try? installAgentIfNeeded()) != nil else { return }
            body()
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
        // Hosting widgets, as a phone's home screen does (DesktopWidgets).
        _ = try? AdbClient.shell("appwidget grantbind --package \(Self.agent) --user 0")
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
        if let key = message["widget"] as? String, let png = (message["png"] as? String).flatMap({ Data(base64Encoded: $0) }) {
            DesktopWidgets.shared.received(key: key, png: png)
            return
        }
        if let key = message["widgetOpen"] as? String, let package = message["package"] as? String {
            DesktopWidgets.shared.tapped(key: key, package: package, opensApp: message["activity"] as? Bool ?? true,
                                         display: message["display"] as? Int ?? 0)
            return
        }
        if let key = message["widgetBound"] as? String, let id = message["id"] as? Int {
            DesktopWidgets.shared.bound(key: key, id: id, setup: message["configure"] as? String,
                                        package: message["package"] as? String)
            return
        }
        if let key = message["widgetDone"] as? String {
            DesktopWidgets.shared.tapDone(key: key)
            return
        }
        if let location = message["location"] as? String {
            LocationBridge.shared.set(wanted: location == "start")
            return
        }
    }

    /// A packet from Android's KDE Connect.
    private func received(_ type: String, _ body: [String: Any]) {
        guard type == "kdeconnect.notification", let key = body["id"] as? String else { return }
        let center = UNUserNotificationCenter.current()
        if body["isCancel"] as? Bool == true {
            if shown[key] != nil { AppLog.write("Notification removed in Android, so on the Mac too") }
            shown[key] = nil
            center.removeDeliveredNotifications(withIdentifiers: [key])
            return
        }
        // Android's key: user|package|id|tag|uid.
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        let package = parts.count > 1 ? String(parts[1]) : (body["appName"] as? String ?? "")
        let title = body["title"] as? String ?? ""
        let text = body["text"] as? String ?? ""
        // The time the app gives the message too: the same words sent again are a new message.
        let said = title + "\n" + text + "\n" + String(describing: body["time"] ?? "")
        // Already there when Android connected, or an update that changes nothing or asked to
        // alert once: kept, not alerted again.
        if shown[key] == said || body["silent"] as? Bool == true {
            if shown[key] != said { AppLog.write("Notification from \(package): an update, not shown again") }
            shown[key] = said
            return
        }
        // A chat adding the user's own reply to the conversation, as after answering from the Mac:
        // nothing new for the user, as on a phone.
        if sentReplies[package].map({ !$0.isEmpty && text.hasSuffix($0) }) == true {
            sentReplies[package] = nil
            shown[key] = said
            AppLog.write("Notification from \(package): the user's own message, not shown")
            return
        }
        shown[key] = said

        let replyId = body["requestReplyId"] as? String
        let actions = body["actions"] as? [String] ?? []
        let info = appInfo?(package)
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? (info?.label ?? body["appName"] as? String ?? "") : title
        if !title.isEmpty { content.subtitle = info?.label ?? body["appName"] as? String ?? "" }
        content.body = text
        content.sound = .default
        content.threadIdentifier = package
        content.userInfo = ["key": key, "package": package, "replyId": replyId ?? "",
                            "clearable": body["isClearable"] as? Bool ?? true]
        content.categoryIdentifier = category(reply: replyId != nil, actions: actions)
        // The app's icon beside the words; not on a chat's, where it would fill the answer box.
        if replyId == nil, let icon = info?.icon, let file = iconFile(package: package, icon: icon),
           let attachment = try? UNNotificationAttachment(identifier: "icon", url: file) {
            content.attachments = [attachment]
        }
        // The Mac asks the user once, when the first notification arrives.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                AppLog.write("Notification from \(package): not shown, the Mac doesn't allow Inquiline's")
                return
            }
            center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) { error in
                AppLog.write("Notification from \(package): " + (error.map { "not shown, \($0.localizedDescription)" } ?? "shown"))
            }
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

    private func send(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        queue.async { [self] in
            guard connection >= 0 else { return }
            let line = [UInt8](data) + [10]
            _ = write(connection, line, line.count)
        }
    }

    /// Opens the screen the notification points to, the chat or the mail, in the app's window,
    /// as tapping it does on a phone: a window already open shows it, and one opened for it
    /// starts with it, not with the app's first screen. Android lets only a privileged process
    /// open an app's screen from the background, so the helper's Open does it. It takes the
    /// notification's action at once, as opening may clear the notification, and runs it once
    /// it knows the window's display.
    private func open(key: String, group: String, package: String) {
        let unsafe = "[\"'`$\\\\]"
        let safe = key.range(of: unsafe, options: .regularExpression) == nil
            && group.range(of: unsafe, options: .regularExpression) == nil
        let identifier = "io.github.inquiline-app.app." + package.replacingOccurrences(of: "_", with: "-")
        DispatchQueue.global().async { [self] in
            var helper: Int32 = -1
            if safe, let fd = try? AdbClient.open("shell,raw:su 0 sh -c 'CLASSPATH=$(pm path \(Self.agent) | cut -d: -f2) "
                                                 + "app_process / \(Self.agent).Open \"\(key)\" \"\(group)\"'") {
                if Self.readLine(fd, seconds: 5) == "ready" { helper = fd } else { close(fd) }
            }
            guard helper >= 0 else {
                DispatchQueue.main.async { self.openApp?(package, false) }
                return
            }
            defer { close(helper) }
            let open = !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
            let before = Self.windowDisplays()
            DispatchQueue.main.async { self.openApp?(package, !open) }
            for _ in 0..<40 {
                // An open window's display shows the app; a new one is the display it makes.
                let display = open ? AndroidRuntime.display(of: package) : Self.windowDisplays().subtracting(before).first
                if let display {
                    let line = Array("\(display)\n".utf8)
                    _ = write(helper, line, line.count)
                    _ = Self.readLine(helper, seconds: 5)
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    /// Opens the app's window, as for a notification's own screen, without its first screen, and
    /// gives the display it shows: for what a widget's tap opens.
    func openWindow(package: String, then run: @escaping (Int) -> Void) {
        let identifier = "io.github.inquiline-app.app." + package.replacingOccurrences(of: "_", with: "-")
        DispatchQueue.global().async { [self] in
            let open = !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
            let before = Self.windowDisplays()
            DispatchQueue.main.async { self.openApp?(package, !open) }
            for _ in 0..<40 {
                let display = open ? AndroidRuntime.display(of: package) : Self.windowDisplays().subtracting(before).first
                if let display { return run(display) }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    /// The displays Inquiline's windows show, which its server names "scrcpy".
    private static func windowDisplays() -> Set<Int> {
        guard let output = try? AdbClient.shell("dumpsys display | grep -o '\"scrcpy\", displayId [0-9]*'") else { return [] }
        return Set(output.split(whereSeparator: \.isNewline).compactMap { Int($0.split(separator: " ").last ?? "") })
    }


    private static func readLine(_ fd: Int32, seconds: Int) -> String? {
        var line = [UInt8]()
        var byte: UInt8 = 0
        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            guard poll(&waiting, 1, 200) >= 0 else { return nil }
            if waiting.revents == 0 { continue }
            guard Darwin.read(fd, &byte, 1) == 1 else { return nil }
            if byte == 10 { return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            line.append(byte)
        }
        return nil
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let key = info["key"] as? String, let package = info["package"] as? String else {
            completionHandler()
            return
        }
        if let reply = response as? UNTextInputNotificationResponse, !reply.userText.isEmpty,
           let replyId = info["replyId"] as? String, !replyId.isEmpty {
            DispatchQueue.main.async { self.sentReplies[package] = reply.userText }
            KDEConnect.shared.send("kdeconnect.notification.reply", ["requestReplyId": replyId, "message": reply.userText])
        } else if response.actionIdentifier.hasPrefix("action:") {
            KDEConnect.shared.send("kdeconnect.notification.action",
                                   ["key": key, "action": String(response.actionIdentifier.dropFirst("action:".count))])
        } else if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            // Closed on the Mac: closed in Android too, as clearing it there.
            DispatchQueue.main.async { self.shown[key] = nil }
            if info["clearable"] as? Bool != false {
                KDEConnect.shared.send("kdeconnect.notification.request", ["cancel": key])
            }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            AppLog.write("Opening \(package) from its notification")
            open(key: key, group: "", package: package)
        }
        completionHandler()
    }
}
