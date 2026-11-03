import SwiftUI

/// A page's list keys: single letters, the section digits and `?`, only
/// while the page's list has the keyboard — the terminal hidden under the
/// page never sees them, and a list is where a keystroke can't be text.
/// Each page has its own table (Docker's is `DockerKey`); the window sends
/// every key down by one path (`handlePageKey`, `WorkspacePage.press`) and
/// the page reads it with `press(_:sheetShowing:)`. Pure.
protocol ResourceKey: CaseIterable, Hashable, Sendable where AllCases: RandomAccessCollection {
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
}

/// What a key down means on a page's list.
enum ResourceKeyPress<Key: ResourceKey> {
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
    static func of(_ characters: String) -> Self? {
        let name = keyName(of: characters)
        // A key's name (`Space`) is not what is typed: one character, or
        // a named key's.
        guard name != characters || characters.count == 1 else { return nil }
        return allCases.first { $0.key == name }
    }

    /// A typed character as a table names it: ↩, Space and ⌫ (delete or
    /// backspace) by their names, anything else as itself.
    static func keyName(of characters: String) -> String {
        switch characters {
        case "\r": "↩"
        case " ": "Space"
        case "\u{7F}", "\u{08}": "⌫"
        default: characters
        }
    }

    /// A key down on the list: nil when it means nothing there and goes on
    /// to the list (arrows, ⌘C…). An open sheet of keys takes any key to
    /// close; a digit is its section; `?` and `/` are every page's.
    static func press(_ characters: String, sheetShowing: Bool) -> ResourceKeyPress<Self>? {
        if sheetShowing { return .closeSheet }
        guard let key = of(characters) else { return nil }
        if let section = key.section { return .section(section) }
        if key == help { return .help }
        if key == filter { return .filter }
        return .key(key)
    }

    /// No key twice, and every one a typed key can reach.
    static var isWellFormed: Bool {
        let keys = allCases.map(\.key)
        return Set(keys).count == keys.count && allCases.allSatisfy { of(typed(of: $0.key)) == $0 }
    }

    /// What is typed for a key's name: the inverse of `keyName(of:)`.
    static func typed(of key: String) -> String {
        switch key {
        case "↩": "\r"
        case "Space": " "
        case "⌫": "\u{7F}"
        default: key
        }
    }
}

/// The sheet `?` shows over a page: its keys, as its table says them. Any
/// key or a click closes it.
struct ResourceKeySheet<Key: ResourceKey>: View {
    @ObservedObject var theme: ChromeTheme
    let identifier: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keys in the list").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text).padding(.bottom, 4)
            ForEach(Array(Key.allCases), id: \.self) { key in
                HStack(spacing: 12) {
                    Text(verbatim: key.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text)
                        .frame(width: 48, alignment: .leading)
                    Text(key.title).font(.system(size: 12)).foregroundStyle(theme.text2)
                }
            }
            Text("↑↓ to move, ⇧ and ⌘ to pick several, ⌘C copies their names.").font(.system(size: 11)).foregroundStyle(theme.text3)
                .padding(.top, 6)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.menu).shadow(radius: 20))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.menuEdge))
        .onTapGesture { close() }
        .accessibilityIdentifier(identifier)
    }
}
