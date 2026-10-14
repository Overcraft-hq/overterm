import AppKit

/// What a press in the tab strip means.
///
/// The strip lives in the title bar, which takes mouse events before
/// SwiftUI sees them, so every press there is read by the window's event
/// monitor rather than by a gesture (docs/debugging.md). This is the part
/// of that decision worth testing on its own.
enum StripClick: Equatable {
    /// Right-click, or ⌃-click — macOS's other context click, which arrives
    /// as a *left* press with `.control` and is invisible to a monitor
    /// watching only `.rightMouseDown`.
    case context
    /// ⌘-click: mark the tab for a group command without selecting it.
    case mark
    /// A plain press: select, and maybe start a drag.
    case press

    static func kind(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> StripClick? {
        if type == .rightMouseDown { return .context }
        guard type == .leftMouseDown else { return nil }
        // ⌃ wins over ⌘: ⌃⌘-click is still a context click, as it is
        // everywhere else on macOS.
        if modifiers.contains(.control) { return .context }
        if modifiers.contains(.command) { return .mark }
        return .press
    }
}
