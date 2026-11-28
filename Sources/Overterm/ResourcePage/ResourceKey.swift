import SwiftUI

/// A page's list keys: single letters, the section digits and `?`, only
/// while the page's list has the keyboard — the terminal hidden under the
/// page never sees them, and a list is where a keystroke can't be text.
/// Each page has its own table (Docker's is `DockerKey`); the window sends
/// every key down by one path (`handlePageKey`, `WorkspacePage.press`) and
/// the page reads it with `press(_:sheetShowing:)`. Pure.
package protocol ResourceKey: CaseIterable, Hashable, Sendable where AllCases: RandomAccessCollection {
    /// What a digit goes to.
    associatedtype Section
    /// What is pressed: one character, or a key's name (`↩`, `Space`, `⌫`).
    var key: String { get }
    /// What it does, as `?` lists it.
    var title: String { get }
    /// The section this key goes to, for a digit.
    var section: Section? { get }
    /// `?`: these keys.
    static var help: Self { get }
    /// `/`: the filter field.
    static var filter: Self { get }
    /// The heading `?` lists it under; nil: "Keys in the list".
    var sheetGroup: String? { get }
}

extension ResourceKey {
    package var sheetGroup: String? { nil }

    /// The filter field's tooltip: the syntax `?` lists on `/`'s line, from
    /// the same words so the two can't drift apart (DISC-U7).
    package static var filterHelp: String { ResourceKeys.filterHelp(filter.title) }
}

package enum ResourceKeys {
    /// "Filter — status:running port:5432" → "status:running port:5432 — ? lists the keys".
    package static func filterHelp(_ title: String) -> String {
        let prefix = "Filter — "
        let syntax = title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
        return syntax + " — ? lists the keys"
    }
}

/// What a key down means on a page's list.
package enum ResourceKeyPress<Key: ResourceKey> {
    /// The keys' sheet was showing: any key closes it, and does nothing else.
    case closeSheet
    case section(Key.Section)
    case help
    case filter
    /// One of the page's own: what it does there is the page's.
    case key(Key)
}

extension ResourceKey {
    /// The key a typed character is, if any. Case matters (Docker's `D` is
    /// compose down, `d` the Database panel).
    package static func of(_ characters: String) -> Self? {
        let name = keyName(of: characters)
        // A key's name (`Space`) is not what is typed: one character, or
        // a named key's.
        guard name != characters || characters.count == 1 else { return nil }
        return allCases.first { $0.key == name }
    }

    /// A typed character as a table names it: ↩, Space, ⌫ (delete or
    /// backspace) and Esc by their names, anything else as itself.
    package static func keyName(of characters: String) -> String {
        switch characters {
        case "\r": "↩"
        case " ": "Space"
        case "\u{7F}", "\u{08}": "⌫"
        case "\u{1B}": "Esc"
        default: characters
        }
    }

    /// A key down on the list: nil when it means nothing there and goes on
    /// to the list (arrows, ⌘C…). An open sheet of keys takes any key to
    /// close; a digit is its section; `?` and `/` are every page's.
    package static func press(_ characters: String, sheetShowing: Bool) -> ResourceKeyPress<Self>? {
        if sheetShowing { return .closeSheet }
        guard let key = of(characters) else { return nil }
        if let section = key.section { return .section(section) }
        if key == help { return .help }
        if key == filter { return .filter }
        return .key(key)
    }

    /// No key twice, and every one a typed key can reach.
    package static var isWellFormed: Bool {
        let keys = allCases.map(\.key)
        return Set(keys).count == keys.count && allCases.allSatisfy { of(typed(of: $0.key)) == $0 }
    }

    /// What is typed for a key's name: the inverse of `keyName(of:)`.
    package static func typed(of key: String) -> String {
        switch key {
        case "↩": "\r"
        case "Space": " "
        case "⌫": "\u{7F}"
        case "Esc": "\u{1B}"
        default: key
        }
    }
}

/// The sheet `?` shows over a page: its keys, as its table says them,
/// grouped, and the window's commands that are the page's with the keys
/// bound now (`windowCommands`, prefixes such as `"docker."`). Any key or a
/// click closes it.
package struct ResourceKeySheet<Key: ResourceKey>: View {
    @ObservedObject package var theme: ChromeTheme
    @ObservedObject private var keybindings = Keybindings.shared
    package let identifier: String
    package var title: String
    /// A line under the keys: what the list itself reads (← →).
    package var footnote: String? = nil
    package var windowCommands: [String]
    package let close: () -> Void

    package init(
        theme: ChromeTheme, identifier: String, title: String = KeySheet.listGroup, footnote: String? = nil, windowCommands: [String] = [],
        close: @escaping () -> Void
    ) {
        self._theme = ObservedObject(wrappedValue: theme)
        self.identifier = identifier
        self.title = title
        self.footnote = footnote
        self.windowCommands = windowCommands
        self.close = close
    }

    package var body: some View {
        let window = KeySheet.commands(KeySheet.commands(prefixed: windowCommands), title: KeySheet.windowGroup) { keybindings.key(for: $0)?.display }
        let notes = [footnote, "↑↓ to move, ⇧ and ⌘ to pick several, ⌘C copies their names."].compactMap { $0 }.joined(separator: "\n")
        KeySheetView(
            theme: theme, title: title, groups: KeySheet.groups(of: Key.self) + [window].compactMap { $0 }, footnote: notes, identifier: identifier,
            close: close)
    }
}
