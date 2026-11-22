import GhosttyKit

/// A clipboard request libghostty wants confirmed before carrying it out
/// (`confirm_read_clipboard_cb`): a paste that could run commands, or a
/// program in the terminal reading the clipboard (OSC 52). The window asks
/// in a sheet (TerminalWindowController.confirmClipboard).
///
/// Allowing completes the request *confirmed*, with the text the sheet
/// showed; denying denies it (`ghostty_surface_deny_clipboard_request`,
/// Ghostty 1.4). Completed unconfirmed, libghostty asks again at once —
/// Overterm answered a denial that way once and looped until the stack
/// overflowed.
package struct ClipboardConfirmation: Equatable {
    package enum Kind: Equatable {
        /// A paste libghostty flags: a line break no bracketed paste frames,
        /// or the bracketed-paste end sequence inside it.
        case paste
        /// A program asks for the clipboard's contents (OSC 52).
        case read
    }

    /// What libghostty is answered: the text, confirmed, or a denial.
    package enum Reply: Equatable {
        case hand(String)
        case deny
    }

    package let kind: Kind
    /// What would be pasted, or handed to the program.
    package let text: String

    /// Nil for any other request: OSC 52 writes are confirmed through
    /// `write_clipboard_cb`.
    package init?(request: ghostty_clipboard_request_e, text: String) {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE: kind = .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: kind = .read
        default: return nil
        }
        self.text = text
    }

    /// Only the selected tab asks — you see who is asking — and one sheet at
    /// a time, so a program can't pile them up. Anything else is refused
    /// without asking.
    package static func shouldAsk(fromSelectedTab: Bool, alreadyAsking: Bool) -> Bool {
        fromSelectedTab && !alreadyAsking
    }

    package func reply(allowed: Bool) -> Reply {
        allowed ? .hand(text) : .deny
    }

    package var title: String {
        switch kind {
        case .paste: "Paste Potentially Unsafe Text?"
        case .read: "Allow Clipboard Access?"
        }
    }

    package func message(tab: String) -> String {
        // A tab's title is often the running command line; its start, the
        // program, is who is asking.
        let name = tab.count > 40 ? String(tab.prefix(39)) + "…" : tab
        return switch kind {
        case .paste: "Pasting this into “\(name)” could run it as commands."
        case .read: "A program in “\(name)” wants to read the clipboard. Allowing hands it the text below."
        }
    }

    package var allowTitle: String { kind == .paste ? "Paste" : "Allow" }
    package var denyTitle: String { kind == .paste ? "Cancel" : "Deny" }

    /// The text as the sheet shows it: control characters as their symbols
    /// (an escape sequence hidden in a paste is what the sheet is for), line
    /// breaks and tabs as they are, cut after `limit` characters.
    package func preview(limit: Int = 2_000) -> String {
        var shown = ""
        shown.unicodeScalars.append(contentsOf: text.prefix(limit).unicodeScalars.map(Self.visible))
        let rest = text.count - limit
        if rest > 0 { shown += "\n… \(rest) more \(rest == 1 ? "character" : "characters")" }
        return shown
    }

    /// ␛ for ESC, ␍ for CR, ␡ for DEL — the Control Pictures block.
    private static func visible(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x09, 0x0A: scalar
        case 0x00..<0x20: Unicode.Scalar(0x2400 + scalar.value)!
        case 0x7F: "\u{2421}"
        default: scalar
        }
    }
}
