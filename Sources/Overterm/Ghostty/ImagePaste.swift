import AppKit
import GhosttyKit

/// ⌘V with a picture on the clipboard, into an agent: Claude Code and Codex
/// read a clipboard image themselves, on ⌃V — a terminal can't send them a
/// picture, and with no text to paste Ghostty sends nothing at all, so ⌘V
/// just did nothing. In a pane an agent has the keyboard of, the paste key
/// with only an image on the clipboard is handed over as ⌃V. Anywhere else
/// it is left alone: ⌃V in a shell is quoted-insert.
enum ImagePaste {
    /// The clipboard a paste reads — the terminal's own, which an isolated
    /// run keeps away from the user's — unless a scenario hands in another.
    nonisolated(unsafe) static var override: NSPasteboard?
    @MainActor static var pasteboard: NSPasteboard { override ?? GhosttyRuntime.pasteboard(GHOSTTY_CLIPBOARD_STANDARD) ?? .general }

    /// An image and nothing a paste would type — no text, no file.
    @MainActor static func clipboardHasOnlyImage(_ pasteboard: NSPasteboard? = nil) -> Bool {
        let pasteboard = pasteboard ?? Self.pasteboard
        let types = Set(pasteboard.types ?? [])
        guard !types.contains(.string), !types.contains(.fileURL) else { return false }
        return !types.isDisjoint(with: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")])
    }

    /// Whether Claude Code or Codex is in the pane's foreground. Blocking (a
    /// scan of the pane's processes): a few milliseconds, once a paste.
    nonisolated static func agentHasKeyboard(login: pid_t?) -> Bool {
        guard let login else { return false }
        let nodes = ProcessInspector().tree(root: login, tag: nil).flatMap(\.flattened)
        return agentHasKeyboard(among: nodes, foreground: ProcessInspector.foregroundGroup(of: login), groupOf: ProcessInspector.processGroup(of:))
    }

    /// Pure: an agent's process in the terminal's foreground group.
    nonisolated static func agentHasKeyboard(among nodes: [ProcessNode], foreground: pid_t?, groupOf: (pid_t) -> pid_t?) -> Bool {
        guard let foreground else { return false }
        return nodes.contains { AgentOverviewModel.agent(of: $0) != nil && groupOf($0.pid) == foreground }
    }

    /// The ⌃V an agent reads the clipboard on, for `window`.
    static func controlV(like event: NSEvent, _ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: event.locationInWindow, modifierFlags: [.control], timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: "\u{16}", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9)
    }
}
