import Foundation

/// The editor's text as the vim engine sees it. The text view adapter
/// implements it; the engine never touches AppKit.
@MainActor
protocol VimBuffer: AnyObject {
    /// The live text. Read again after every edit: it may be the storage itself.
    var text: NSString { get }
    /// Normal mode: a 0-length range at the cursor's character. Visual
    /// modes: the highlighted range. Insert: the caret.
    var selection: NSRange { get set }
    /// One edit. Between `beginUndoGroup` and `endUndoGroup` it joins the
    /// command's single undo step.
    func replace(_ range: NSRange, with string: String)
    /// Nests: a whole command (`3dd`, `ciw` + what is typed until Esc, a `.`)
    /// is one group, so one `u` takes it back.
    func beginUndoGroup()
    func endUndoGroup()
    func undo()
    func redo()
    /// The characters on screen, for H M L and the page moves. Characters, not
    /// lines: the layout manager has them, and counting lines in a 4 MB file
    /// on every ⌃d would not be free.
    var visibleCharacterRange: NSRange { get }
    /// zz zt zb (relative to the line at `selection`) and ⌃e ⌃y / the page
    /// moves (by lines; positive is down). The engine moves the cursor itself.
    func scroll(_ request: VimScroll)
    /// What `>>` and `o` after `{` add: a tab or the file's spaces.
    func indentUnit() -> String
    /// The system clipboard: Zed's `use_system_clipboard: always`, so the
    /// unnamed register is the clipboard.
    var clipboard: String? { get set }
}

enum VimScroll: Equatable, Sendable {
    case cursorToCenter, cursorToTop, cursorToBottom
    case lines(Int)
}

enum VimMode: Equatable, Sendable {
    case normal, insert, visual, visualLine
    /// `R`: typed characters overwrite.
    case replace
    /// `:` `/` `?` — `VimEngine.commandLine` holds what is typed.
    case commandLine
}

/// One key press as the text view got it.
struct VimKey: Equatable, Sendable {
    enum Named: Equatable, Sendable {
        case escape, enter, backspace, delete, tab, left, right, up, down, home, end, pageUp, pageDown
    }

    struct Modifiers: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let command = Modifiers(rawValue: 4)
        static let shift = Modifiers(rawValue: 8)
    }

    /// What the key typed, with Option applied (a Turkish layout types `{`
    /// with ⌥) — `event.characters`; with Control, the bare letter
    /// (`charactersIgnoringModifiers`).
    var characters: String
    var named: Named?
    var modifiers: Modifiers

    init(_ characters: String, modifiers: Modifiers = []) {
        self.characters = characters
        self.named = nil
        self.modifiers = modifiers
    }

    init(_ named: Named, modifiers: Modifiers = []) {
        self.characters = ""
        self.named = named
        self.modifiers = modifiers
    }

    /// The key in vim's notation: `d`, `<c-r>`, `<esc>`. Characters typed at
    /// once (a dead key, IME) are one token each.
    var tokens: [String] {
        if let named {
            switch named {
            case .escape: return ["<esc>"]
            case .enter: return ["<cr>"]
            case .backspace: return ["<bs>"]
            case .delete: return ["<del>"]
            case .tab: return ["<tab>"]
            case .left: return ["<left>"]
            case .right: return ["<right>"]
            case .up: return ["<up>"]
            case .down: return ["<down>"]
            case .home: return ["<home>"]
            case .end: return ["<end>"]
            case .pageUp: return ["<pageup>"]
            case .pageDown: return ["<pagedown>"]
            }
        }
        if modifiers.contains(.control) {
            let c = characters.lowercased()
            if c == "[" { return ["<esc>"] }
            return c.isEmpty ? [] : ["<c-\(c)>"]
        }
        switch characters {
        case "\u{1b}": return ["<esc>"]
        case "\r", "\n": return ["<cr>"]
        case "\t": return ["<tab>"]
        case "\u{7f}": return ["<bs>"]
        default: return characters.map { String($0) }
        }
    }
}
