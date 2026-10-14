import AppKit

/// The colours code is drawn in — the editor's, and the changes pane's
/// diffs: one palette, so a file reads the same in both.
enum SyntaxPalette {
    /// `text`: the terminal's foreground. Comments are it, faded (and set in
    /// italics by whoever draws them).
    static func color(_ kind: SyntaxHighlighter.Kind, text: NSColor) -> NSColor {
        switch kind {
        case .comment: text.withAlphaComponent(0.45)
        case .string: NSColor(srgbRed: 0.60, green: 0.80, blue: 0.47, alpha: 1)
        case .number: NSColor(srgbRed: 0.96, green: 0.66, blue: 0.40, alpha: 1)
        case .keyword: NSColor(srgbRed: 0.78, green: 0.56, blue: 0.95, alpha: 1)
        }
    }
}
