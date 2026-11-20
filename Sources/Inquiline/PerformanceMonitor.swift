import AppKit
import IOKit

/// The app's performance at a glance, opened from its frame rate in the toolbar: frames a
/// second over the last half minute, and how much of the Mac's CPU and GPU, and of Android's
/// memory, are in use now. Nothing it needs asks for a permission.
final class PerformanceMonitor: NSViewController {
    private let fps = NSTextField(labelWithString: "–")
    private let graph = FrameGraph()
    private let cpu = Meter(name: "CPU")
    private let gpu = Meter(name: "GPU")
    private let memory = Meter(name: "Memory")

    override func loadView() {
        fps.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        let unit = NSTextField(labelWithString: "FPS")
        unit.textColor = .secondaryLabelColor
        let top = NSStackView(views: [fps, unit])
        top.alignment = .firstBaseline
        top.spacing = 6
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let stack = NSStackView(views: [top, graph, cpu.row, gpu.row, memory.row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.widthAnchor.constraint(equalToConstant: 260).isActive = true
        for view in [graph, cpu.row, gpu.row, memory.row] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        view = stack
    }

    /// `cores`: how many of the Mac's cores Android used; `memory`: Android's, in bytes.
    func update(history: [Int], cores: Double, gpu utilization: Double?, memory: (used: Double, total: Double)?) {
        guard isViewLoaded else { return }
        fps.stringValue = history.last.map(String.init) ?? "–"
        graph.values = history
        let share = cores / Double(ProcessInfo.processInfo.activeProcessorCount)
        cpu.show(share, text: String(format: "%.0f%%", share * 100))
        if let utilization {
            gpu.show(utilization / 100, text: String(format: "%.0f%%", utilization))
        } else {
            gpu.show(0, text: "–")
        }
        if let memory, memory.total > 0 {
            self.memory.show(memory.used / memory.total, text: String(format: "%.1f / %.0f GB", memory.used / 1e9, memory.total / 1e9))
        } else {
            self.memory.show(0, text: "–")
        }
    }

    /// The Mac's GPU in use now, in percent, as Activity Monitor's GPU History shows it.
    static func gpuUtilization() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: Double?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let value = statistics["Device Utilization %"] as? NSNumber {
                found = max(found ?? 0, value.doubleValue)
            }
        }
        return found
    }

    /// Android's memory in use, as it counts it (what its apps can't have), and all it has.
    static func androidMemory() -> (used: Double, total: Double)? {
        guard let info = try? AdbClient.shell("cat /proc/meminfo", timeout: 2) else { return nil }
        func kilobytes(_ name: String) -> Double? {
            info.split(separator: "\n").first { $0.hasPrefix(name + ":") }
                .flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Double($0) }
        }
        guard let total = kilobytes("MemTotal"), let available = kilobytes("MemAvailable") else { return nil }
        return ((total - available) * 1024, total * 1024)
    }
}

/// A name, a value and a bar.
private final class Meter {
    let row: NSView
    private let value = NSTextField(labelWithString: "–")
    private let bar = NSLevelIndicator()

    init(name: String) {
        let label = NSTextField(labelWithString: name)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        let line = NSStackView(views: [label, value])
        line.distribution = .fill
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.levelIndicatorStyle = .continuousCapacity
        bar.minValue = 0
        bar.maxValue = 1
        bar.warningValue = 0.75
        bar.criticalValue = 0.9
        let stack = NSStackView(views: [line, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        row = stack
    }

    func show(_ share: Double, text: String) {
        bar.doubleValue = min(max(share, 0), 1)
        value.stringValue = text
    }
}

/// Frames a second, one bar for each of the last seconds; a fall shows as a dip.
private final class FrameGraph: NSView {
    var values: [Int] = [] { didSet { needsDisplay = true } }
    static let seconds = 30

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let top = Double(max(values.max() ?? 0, 60))
        let width = bounds.width / CGFloat(Self.seconds)
        for (index, value) in values.suffix(Self.seconds).enumerated() {
            let height = bounds.height * CGFloat(Double(value) / top)
            let x = bounds.width - CGFloat(min(values.count, Self.seconds) - index) * width
            (value < 30 ? NSColor.systemOrange : NSColor.systemGreen).setFill()
            NSRect(x: x + 0.5, y: 0, width: max(width - 1, 1), height: height).fill()
        }
    }
}
