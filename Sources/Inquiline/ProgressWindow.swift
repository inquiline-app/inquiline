import AppKit

/// What a Mac installer shows while it works: the app's icon, what it's doing and a progress
/// bar, for the work that takes minutes, such as adding Google Play. Closing it only hides it;
/// the work goes on, and the menu bar icon shows it.
final class ProgressWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let message = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init(detail: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Inquiline"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        message.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        message.lineBreakMode = .byTruncatingTail
        let note = NSTextField(wrappingLabelWithString: detail)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)

        let text = NSStackView(views: [message, bar, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = row
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            text.widthAnchor.constraint(equalToConstant: 300),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            note.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
    }

    /// What it's doing now.
    func show(_ text: String) {
        message.stringValue = text
        guard !window.isVisible else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        bar.stopAnimation(nil)
        window.close()
    }
}
