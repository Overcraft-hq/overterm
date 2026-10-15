import Foundation

/// A colour, as a theme file writes it.
struct ThemeColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// `#rrggbb`, `#rgb`, a bare `rrggbb`, or `rgb:rr/gg/bb` — the forms the
    /// theme files use. Anything else (a colour name, a palette reference)
    /// is nil: the theme still loads, that one line is skipped.
    init?(_ text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("rgb:") {
            let parts = hex.dropFirst(4).split(separator: "/")
            guard parts.count == 3 else { return nil }
            hex = parts.map { $0.count == 1 ? String(repeating: String($0), count: 2) : String($0.suffix(2)) }.joined()
        }
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// HSB brightness — the same measure `ChromeTheme` reads off the
    /// terminal background, so a theme the gallery calls dark is the one
    /// the chrome dresses as dark.
    var brightness: Double { max(red, green, blue) }
}

/// One terminal colour theme: a Ghostty theme file, read.
///
/// Ghostty finds these itself (`theme = "<name>"`); this is for *showing*
/// them — the gallery in Settings ▸ Themes draws a window in each theme's
/// colours, which means reading the files ourselves. Pure, so the parser
/// is tested without a terminal.
struct TerminalTheme: Equatable, Sendable, Identifiable {
    /// The file's name, which is what `theme =` takes.
    let name: String
    let background: ThemeColor
    let foreground: ThemeColor
    let cursor: ThemeColor?
    let selection: ThemeColor?
    /// The 16 ANSI colours, 0…15. Short only for a file that omits some.
    let palette: [ThemeColor]

    var id: String { name }

    /// Whether the chrome around this theme would be dark (ChromeTheme's rule).
    var isDark: Bool { background.brightness < 0.5 }

    /// The ANSI colour, or the foreground when the file left it out.
    func ansi(_ index: Int) -> ThemeColor {
        index < palette.count ? palette[index] : foreground
    }

    /// A theme file: `key = value` lines, `palette = 0=#rrggbb` for the
    /// sixteen. Nil without a background and a foreground — there is
    /// nothing to draw a preview from.
    static func parse(_ text: String, name: String) -> TerminalTheme? {
        var background: ThemeColor?
        var foreground: ThemeColor?
        var cursor: ThemeColor?
        var selection: ThemeColor?
        var palette = [Int: ThemeColor]()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": background = ThemeColor(value)
            case "foreground": foreground = ThemeColor(value)
            case "cursor-color": cursor = ThemeColor(value)
            case "selection-background": selection = ThemeColor(value)
            case "palette":
                // The value is itself `<index>=<colour>`.
                guard let inner = value.firstIndex(of: "="),
                    let index = Int(value[value.startIndex..<inner].trimmingCharacters(in: .whitespaces)),
                    (0...15).contains(index),
                    let colour = ThemeColor(String(value[value.index(after: inner)...]))
                else { continue }
                palette[index] = colour
            default: continue
            }
        }

        guard let background, let foreground else { return nil }
        // Up to the first gap: an index past a missing one would be the
        // wrong colour, and `ansi` falls back for the rest.
        var colours = [ThemeColor]()
        for index in 0...15 {
            guard let colour = palette[index] else { break }
            colours.append(colour)
        }
        return TerminalTheme(
            name: name, background: background, foreground: foreground, cursor: cursor, selection: selection,
            palette: colours)
    }
}
