import AppKit

/// One Android app as its own Mac app, run from its shortcut in ~/Applications: its
/// own window, Dock icon and menu, as an iPhone app on a Mac. Inquiline runs Android.
final class AppProcess: NSObject, NSApplicationDelegate {
    private let package: String
    private var controller: AppWindowController?

    init(package: String) {
        self.package = package
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Android's connections can drop at any time, which must not end the app.
        signal(SIGPIPE, SIG_IGN)
        AppLog.source = package
        // An app left on an older program asks Inquiline to update it and open it again.
        if AppShortcuts.isOutdated(), let url = URL(string: "inquiline://open?package=\(package)") {
            NSWorkspace.shared.open(url)
            NSApp.terminate(nil)
            return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let label = info["CFBundleName"] as? String ?? package
        let orientation = AppOrientation(rawValue: info[AppShortcuts.orientationKey] as? String ?? "") ?? .both
        // A Mac screen is wide, so every app that can run in landscape starts that way.
        // Only portrait-only apps start upright.
        let landscape = orientation != .portrait
        // Apps that turn freely lay out for the window's size; games and apps held one way are scaled.
        let isGame = info["LSApplicationCategoryType"] as? String == "public.app-category.games"
        let controller = AppWindowController(package: package, label: label, orientation: orientation, landscape: landscape,
                                             flexible: !isGame && orientation == .both,
                                             fromNotification: CommandLine.arguments.contains(NotificationBridge.fromNotification))
        self.controller = controller
        buildMenu(label: label, controller: controller)
        controller.window.subtitle = "Starting Android…"
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.restoreFullScreen()

        DispatchQueue.global().async { [package] in
            let ready = AndroidRuntime.waitUntilReady()
            let installed = ready && ((try? AdbClient.shell("cmd package path \(package)"))?.contains("package:") ?? false)
            DispatchQueue.main.async {
                controller.window.subtitle = ""
                AppLog.write(installed ? "Opening" : ready ? "Not installed in Android" : "Android didn't start")
                guard installed else {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = ready ? "\(label) is no longer installed." : "Android didn't start."
                    alert.informativeText = ready ? "Move it to the Trash, or add it again from Inquiline in the menu bar."
                        : "Open Inquiline from the menu bar to see what went wrong."
                    alert.runModal()
                    NSApp.terminate(nil)
                    return
                }
                controller.start()
                self.appStarted = true
                self.loadShortcuts()
            }
        }
    }

    // MARK: - Dock menu

    /// The app's shortcuts, as holding its icon on a phone shows them, in its Dock menu: those
    /// the app offers now, read again as it comes to the front, as some change with use.
    private var shortcuts: [(id: String, label: String, icon: Data?)] = []
    private var loadingShortcuts = false
    private var appStarted = false

    private func loadShortcuts() {
        guard package != AppShortcuts.settingsPackage, !loadingShortcuts else { return }
        loadingShortcuts = true
        DispatchQueue.global(qos: .utility).async { [package] in
            let found = AndroidRuntime.shared.shortcuts(package: package)
            DispatchQueue.main.async {
                self.loadingShortcuts = false
                if let found { self.shortcuts = found }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if appStarted { loadShortcuts() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard !shortcuts.isEmpty else { return nil }
        let menu = NSMenu()
        for shortcut in shortcuts {
            let item = menu.addItem(withTitle: shortcut.label, action: #selector(openShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shortcut.id
            if let data = shortcut.icon, let image = NSImage(data: data) {
                image.size = NSSize(width: 16, height: 16)
                item.image = image
            }
        }
        return menu
    }

    @objc private func openShortcut(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.window.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async { [package] in
            AndroidRuntime.shared.openShortcut(package: package, id: id)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.window.close()
    }

    private func buildMenu(label: String, controller: AppWindowController) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // As Android's Settings > Apps > Storage has them, for this app; not for Settings itself.
        if package != AppShortcuts.settingsPackage {
            appMenu.addItem(withTitle: "Clear Cache", action: #selector(AppWindowController.clearCache), keyEquivalent: "").target = controller
            appMenu.addItem(withTitle: "Clear Data…", action: #selector(AppWindowController.clearData), keyEquivalent: "").target = controller
            appMenu.addItem(.separator())
        }
        appMenu.addItem(withTitle: "Hide \(label)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(label)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // The toolbar's own items, as in any Mac app with one; AppKit turns Show into Hide.
        viewMenu.addItem(withTitle: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: "Customize Toolbar…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Hide Toolbar Automatically", action: #selector(AppWindowController.toggleAutoHideToolbar(_:)), keyEquivalent: "")
            .target = controller
        viewMenu.addItem(.separator())
        AppWindowController.addControlsItems(to: viewMenu, target: controller)
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
