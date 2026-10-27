import AppKit
import SwiftUI

/// What a press in the strip is on.
enum StripPressSubject {
    case tab(Tab)
    case group(TabGroup)
}

enum StripPressPhase {
    case down, drag, up
}

/// Under each tab and island chip: the view a press on it reaches, from the
/// frame view down, as a real one does.
///
/// The strip is in the title bar, and AppKit asks the view a title-bar
/// press lands on whether it moves the window. SwiftUI draws the tabs into
/// layers, so that view was SwiftUI's scroll content, which says yes: a tab
/// dragged to reorder dragged the window, and the window's event monitor
/// never got the drag. This view says no and takes the press, the drag and
/// the release itself — AppKit sends all three to the view that took the
/// press, wherever the pointer goes. What they do is the window's
/// (`TerminalWindowController.stripPress`).
final class StripPressNSView: NSView {
    var onEvent: ((NSEvent, StripPressPhase) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onEvent?(event, .down) }
    override func mouseDragged(with event: NSEvent) { onEvent?(event, .drag) }
    override func mouseUp(with event: NSEvent) { onEvent?(event, .up) }
}

struct StripPressView: NSViewRepresentable {
    let help: String?
    let onEvent: (NSEvent, StripPressPhase) -> Void

    func makeNSView(context: Context) -> StripPressNSView {
        let view = StripPressNSView()
        view.onEvent = onEvent
        view.toolTip = help
        return view
    }

    func updateNSView(_ view: StripPressNSView, context: Context) {
        view.onEvent = onEvent
        view.toolTip = help
    }
}

/// A tab's ×, as an AppKit button: over the tab's press view, a SwiftUI
/// Button never saw its click — AppKit gave it to the view under it.
struct CloseTabButton: NSViewRepresentable {
    let color: Color
    let visible: Bool
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        let button = NSButton(image: image ?? NSImage(), target: context.coordinator, action: #selector(Coordinator.clicked))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.toolTip = "Close Tab (⌘W)"
        button.setAccessibilityIdentifier("tabClose")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.contentTintColor = NSColor(color)
        button.alphaValue = visible ? 1 : 0
    }
}
