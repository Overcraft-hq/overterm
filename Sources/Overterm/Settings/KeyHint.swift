import SwiftUI

/// A command's key as it is bound now, for the places that show one in a
/// tooltip, a header or an empty state (DISC-U4, DISC-N3). A key written
/// into the text went wrong the moment its command was rebound.
@MainActor
package enum KeyHints {
    /// The key bound to `id` now, as menus show it; nil when unbound or unknown.
    package static func key(_ id: String, keys: Keybindings = .shared) -> String? {
        KeyCommands.byID[id].flatMap { keys.key(for: $0)?.display }
    }

    /// "Overgit (⌥⌘G)", or the title alone while nothing is bound.
    package static func help(_ title: String, command id: String?, keys: Keybindings = .shared) -> String {
        guard let id, let key = key(id, keys: keys) else { return title }
        return "\(title) (\(key))"
    }

    /// `text` with the command's key in it: `%@` stands for the key. Nil
    /// when the command is unbound, so the hint isn't drawn with a gap.
    package static func text(_ text: String, command id: String, keys: Keybindings = .shared) -> String? {
        key(id, keys: keys).map { text.replacingOccurrences(of: "%@", with: $0) }
    }
}

/// A small line naming a key, following keybindings.json as it changes:
/// `KeyHint("⌥⌘↓ jumps…")` is written `KeyHint("%@ jumps to the next tab that needs you", command: "tabs.nextAttention")`.
/// Nothing at all while the command has no key.
package struct KeyHint: View {
    @ObservedObject private var keys: Keybindings
    private let text: String
    private let command: String
    private let color: Color
    private let size: CGFloat

    package init(_ text: String, command: String, color: Color, size: CGFloat = 11, keys: Keybindings = .shared) {
        self.text = text
        self.command = command
        self.color = color
        self.size = size
        self.keys = keys
    }

    package var body: some View {
        if let line = KeyHints.text(text, command: command, keys: keys) {
            Text(verbatim: line).font(.system(size: ChromeMetrics.text(size))).foregroundStyle(color)
        }
    }
}
