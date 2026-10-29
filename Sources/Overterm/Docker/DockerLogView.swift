import AppKit
import SwiftUI

/// Lines of text in an AppKit text view — a log, an inspect's JSON. A
/// SwiftUI list of thousands of lines doesn't scroll; a text view also
/// selects across lines and copies. New lines are appended rather than the
/// whole text set again, and the view keeps to the bottom while it was
/// there (`follow`).
struct DockerTextView: NSViewRepresentable {
    /// How many lines there are, and the ones in a range, drawn — only the
    /// new ones are drawn as a log grows. `revision` changes when the text
    /// is something other than the old one with lines added (a filter, a
    /// cleared log).
    let count: Int
    let revision: Int
    let render: (Range<Int>) -> [NSAttributedString]
    var wrap = true
    var follow = true
    /// Lines picked out of it, to an agent (⌘L, its right-click menu): a
    /// log's; nil for what isn't one (Inspect's JSON, a build's log).
    var ask: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        // The class method makes the subclass's text view.
        let scroll = DockerLogTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.allowsUndo = false
        text.layoutManager?.allowsNonContiguousLayout = true
        text.setAccessibilityIdentifier("docker.text")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? DockerLogTextView)?.ask = ask
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        setWrap(wrap, scroll, text)
        let coordinator = context.coordinator
        let atBottom = scroll.contentView.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 24
        let reset = coordinator.revision != revision || count < coordinator.shown
        if reset {
            storage.setAttributedString(Self.joined(render(0..<count)))
            coordinator.revision = revision
        } else if count > coordinator.shown {
            let added = Self.joined(render(coordinator.shown..<count))
            if storage.length > 0 { storage.append(NSAttributedString(string: "\n")) }
            storage.append(added)
        } else {
            return
        }
        coordinator.shown = count
        // Kept at the bottom while it was there; a line read further up
        // stays where it is.
        if follow && (atBottom || reset) { text.scrollToEndOfDocument(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown = 0
        var revision = -1
    }

    private static func joined(_ lines: [NSAttributedString]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(line)
        }
        return out
    }

    private func setWrap(_ wrap: Bool, _ scroll: NSScrollView, _ text: NSTextView) {
        guard let container = text.textContainer, container.widthTracksTextView != wrap else { return }
        container.widthTracksTextView = wrap
        text.isHorizontallyResizable = !wrap
        if wrap {
            container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            text.frame.size.width = scroll.contentSize.width
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        scroll.hasHorizontalScroller = !wrap
    }
}

/// A log's text view: lines picked out of it go to an agent, widened to
/// whole lines — ⌘L (Edit's Ask an Agent About the Selection, which
/// reaches it before the terminal hidden under the page) and its
/// right-click menu. Without a selection, or a log, ⌘L goes on up the
/// responder chain: the window then asks about the selected container.
final class DockerLogTextView: NSTextView {
    var ask: ((String) -> Void)?

    @objc func askAboutSelection(_ sender: Any?) {
        let range = selectedRange()
        if let ask, range.length > 0 { return ask(DockerAgentText.wholeLines(of: string, range)) }
        if nextResponder?.tryToPerform(#selector(askAboutSelection(_:)), with: sender) != true { NSSound.beep() }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(askAboutSelection(_:)) ? true : super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(askAboutSelection(_:)) ? true : super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard ask != nil, selectedRange().length > 0 else { return menu }
        // A copy: the text view's menu may be one it keeps.
        let shown = (menu?.copy() as? NSMenu) ?? NSMenu()
        let item = NSMenuItem(title: "Ask an Agent About These Lines", action: #selector(askAboutSelection(_:)), keyEquivalent: "")
        item.target = self
        shown.insertItem(.separator(), at: 0)
        shown.insertItem(item, at: 0)
        return shown
    }
}

/// How a log line looks: its time dim, its level in its colour, a JSON
/// line's fields after its message. Pure but for the colours.
@MainActor
enum DockerLogStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    static func color(_ level: DockerLogLine.Level?) -> NSColor? {
        switch level {
        case .fatal, .error: NSColor(srgbRed: 0.94, green: 0.36, blue: 0.34, alpha: 1)
        case .warning: TabStatusStyle.waitingNS
        case .debug, .trace: nil
        default: nil
        }
    }

    /// A service's colour in merged logs: the same one each time, told
    /// apart from its neighbours.
    static func serviceColor(_ service: String) -> NSColor {
        let palette: [NSColor] = [.systemTeal, .systemPurple, .systemOrange, .systemPink, .systemIndigo, .systemGreen, .systemYellow, .systemBlue]
        let sum = service.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[sum % palette.count]
    }

    /// `2026-10-27T10:00:00.123456789Z` → `10:00:00.123`, local time.
    static func time(_ stamp: String) -> String {
        let trimmed = stamp.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: stamp) else { return stamp }
        return timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func line(_ line: DockerLogLine, text: NSColor, dim: NSColor, timestamps: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ string: String, _ color: NSColor) {
            out.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        if timestamps, let stamp = line.timestamp { add(time(stamp) + "  ", dim) }
        if let service = line.service { add(service + " | ", serviceColor(service)) }
        let levelColor = color(line.level)
        let body = line.stream == .stderr && levelColor == nil ? text.withAlphaComponent(0.85) : text
        add(line.message, levelColor ?? (line.level == .debug || line.level == .trace ? dim : body))
        if !line.fields.isEmpty { add("  " + line.fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "), dim) }
        return out
    }
}
