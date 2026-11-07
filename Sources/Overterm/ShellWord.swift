import Foundation

/// A word typed into a tab's shell when it holds a character the line
/// would act on rather than read: a control character (Cc — ^U, ^C, a
/// newline, ESC), a format character (Cf — a bidi override that makes a
/// word read as another), a line or paragraph separator.
///
/// Such a line goes to the pty as typed, not as a paste: the tty's line
/// discipline and zle both take ^U as "erase what was typed", which
/// throws the opening quote away and leaves the rest in the open — a
/// chart folder or a pod's env value written by someone else then runs as
/// a command. Inside single quotes nothing protects them, so a word that
/// holds one is said in ANSI-C quotes (`$'…'`, zsh and bash), every such
/// character as an escape: no raw control byte is ever on the line, and in
/// a shell that doesn't read `$'…'` the line breaks, it doesn't run.
enum ShellWord {
    /// Whether `word` holds a character the line would act on.
    static func hasControl(_ word: String) -> Bool { word.unicodeScalars.contains(where: isControl) }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }

    /// `word` in ANSI-C quotes: `\`, `'` and every character the line
    /// would act on escaped, the rest as it is.
    static func ansiC(_ word: String) -> String {
        var out = "$'"
        for scalar in word.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            default:
                if isControl(scalar) {
                    let value = scalar.value
                    if value < 0x100 {
                        out += "\\x" + hex(value, 2)
                    } else if value < 0x10000 {
                        out += "\\u" + hex(value, 4)
                    } else {
                        out += "\\U" + hex(value, 8)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "'"
    }

    private static func hex(_ value: UInt32, _ digits: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
