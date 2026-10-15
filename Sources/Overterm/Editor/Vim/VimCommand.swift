import Foundation

enum VimMotion: Equatable, Sendable {
    case left, right, down, up
    /// `+` / `<cr>`, `-`, `_`.
    case nextLineStart, prevLineStart, currentLine
    case wordForward(big: Bool), wordEnd(big: Bool), wordBack(big: Bool), wordEndBack(big: Bool)
    case lineStart, firstNonBlank, lineEnd, lastNonBlank
    case fileStart, fileEnd
    case find(String, forward: Bool, till: Bool)
    case repeatFind(reverse: Bool)
    case matchPair
    case paragraphBack, paragraphForward
    case screenTop, screenMiddle, screenBottom
    case halfPageDown, halfPageUp, pageDown, pageUp
    case searchNext(reverse: Bool)
    case searchWord(forward: Bool)
    case mark(Character, linewise: Bool)

    var isVertical: Bool {
        switch self {
        case .down, .up, .halfPageDown, .halfPageUp, .pageDown, .pageUp: return true
        default: return false
        }
    }
}

enum VimTextObject: Equatable, Sendable {
    case word(big: Bool, around: Bool)
    case quote(Character, around: Bool)
    case pair(open: Character, close: Character, around: Bool)
    case paragraph(around: Bool)
}

enum VimOperator: Equatable, Sendable {
    case delete, change, yank, indent, outdent, reindent, uppercase, lowercase, toggleCase
}

enum VimTarget: Equatable, Sendable {
    case motion(VimMotion)
    case object(VimTextObject)
    /// `dd`, `cc`, `>>`: the operator doubled.
    case lines
    /// Visual mode's selection; `.selectionLines` for `D` `C` `Y`…, whole lines either way.
    case selection, selectionLines
}

enum VimInsert: Equatable, Sendable {
    case before, after, lineStart, lineFirstNonBlank, lineEnd, lineBelow, lineAbove
}

enum VimAction: Equatable, Sendable {
    case insert(VimInsert)
    case put(before: Bool)
    case join(spaces: Bool)
    case toggleCaseChar
    case replaceChar(String)
    case replaceMode
    case undo, redo, repeatLast
    case visual(linewise: Bool)
    case reselect
    case swapEnds
    case scroll(VimScroll, firstNonBlank: Bool)
    case scrollLines(Int)
    case setMark(Character)
    case commandLine(Character)
    case cancel
}

struct VimCommand: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case move(VimMotion)
        case operate(VimOperator, VimTarget)
        case action(VimAction)
        /// A text object typed in visual mode: it selects.
        case select(VimTextObject)
    }

    var register: Character?
    var count: Int?
    var kind: Kind

    /// Whether `.` repeats it.
    var isChange: Bool {
        switch kind {
        case .operate(let op, _): return op != .yank
        case .action(let a):
            switch a {
            case .insert, .put, .join, .toggleCaseChar, .replaceChar, .replaceMode: return true
            default: return false
            }
        default: return false
        }
    }
}

enum VimParse: Equatable {
    case incomplete, invalid
    case complete(VimCommand)
}

/// Pending keys to a command: `"a2d3w` → register a, count 6, delete by
/// word. Parsed again from the start on each key, which is what lets the
/// status line show `2d` while it waits.
enum VimParser {
    static func parse(_ t: [String], visual: Bool) -> VimParse {
        var i = 0
        var register: Character?
        if i < t.count, t[i] == "\"" {
            guard t.count > 1 else { return .incomplete }
            guard t[1].count == 1, let c = t[1].first, isRegister(c) else { return .invalid }
            register = c
            i = 2
        }
        let c1 = count(t, &i)
        guard i < t.count else { return .incomplete }
        func done(_ kind: VimCommand.Kind, _ count: Int?) -> VimParse {
            .complete(VimCommand(register: register, count: count, kind: kind))
        }
        // `g` and `z` start two-key commands.
        var key = t[i]
        let keyStart = i
        if key == "g" || key == "z" {
            guard i + 1 < t.count else { return .incomplete }
            key += t[i + 1]
            i += 2
        } else {
            i += 1
        }

        if visual {
            if let op = visualOperators[key] { return done(.operate(op, .selection), c1) }
            if let op = visualLineOperators[key] { return done(.operate(op, .selectionLines), c1) }
            if key == "i" || key == "a" {
                guard i < t.count else { return .incomplete }
                guard let object = textObject(t[i], around: key == "a") else { return .invalid }
                return done(.select(object), c1)
            }
            switch key {
            case "o", "O": return done(.action(.swapEnds), c1)
            case "J": return done(.action(.join(spaces: true)), c1)
            case "gJ": return done(.action(.join(spaces: false)), c1)
            case "r":
                guard i < t.count else { return .incomplete }
                guard let c = typed(t[i]) else { return .invalid }
                return done(.action(.replaceChar(c)), c1)
            default: break
            }
        } else if let op = operators[key] {
            let c2 = count(t, &i)
            let n = c1.map { $0 * (c2 ?? 1) } ?? c2
            guard i < t.count else { return .incomplete }
            // Doubled: dd, gUU, gUgU.
            if t[i] == String(key.last!) { return done(.operate(op, .lines), n) }
            if t[i] == "g" && key.count == 2 {
                guard i + 1 < t.count else { return .incomplete }
                if "g" + t[i + 1] == key { return done(.operate(op, .lines), n) }
            }
            if t[i] == "i" || t[i] == "a" {
                guard i + 1 < t.count else { return .incomplete }
                guard let object = textObject(t[i + 1], around: t[i] == "a") else { return .invalid }
                return done(.operate(op, .object(object)), n)
            }
            var j = i
            switch motion(t, &j) {
            case .some(.some(let m)): return done(.operate(op, .motion(m)), n)
            case .some(.none): return .incomplete
            case .none: return .invalid
            }
        } else {
            switch key {
            case "x", "<del>": return done(.operate(.delete, .motion(.right)), c1)
            case "X": return done(.operate(.delete, .motion(.left)), c1)
            case "s": return done(.operate(.change, .motion(.right)), c1)
            case "S": return done(.operate(.change, .lines), c1)
            case "C": return done(.operate(.change, .motion(.lineEnd)), c1)
            case "D": return done(.operate(.delete, .motion(.lineEnd)), c1)
            case "Y": return done(.operate(.yank, .lines), c1)
            case "i": return done(.action(.insert(.before)), c1)
            case "a": return done(.action(.insert(.after)), c1)
            case "I": return done(.action(.insert(.lineFirstNonBlank)), c1)
            case "gI": return done(.action(.insert(.lineStart)), c1)
            case "A": return done(.action(.insert(.lineEnd)), c1)
            case "o": return done(.action(.insert(.lineBelow)), c1)
            case "O": return done(.action(.insert(.lineAbove)), c1)
            case "J": return done(.action(.join(spaces: true)), c1)
            case "gJ": return done(.action(.join(spaces: false)), c1)
            case "~": return done(.action(.toggleCaseChar), c1)
            case "R": return done(.action(.replaceMode), c1)
            case "u": return done(.action(.undo), c1)
            case "<c-r>": return done(.action(.redo), c1)
            case ".": return done(.action(.repeatLast), c1)
            case "r":
                guard i < t.count else { return .incomplete }
                guard let c = typed(t[i]) else { return .invalid }
                return done(.action(.replaceChar(c)), c1)
            case "m":
                guard i < t.count else { return .incomplete }
                guard t[i].count == 1, let c = t[i].first, c.isLetter else { return .invalid }
                return done(.action(.setMark(c)), c1)
            default: break
            }
        }

        // Both modes.
        switch key {
        case "p": return done(.action(.put(before: false)), c1)
        case "P": return done(.action(.put(before: true)), c1)
        case "v": return done(.action(.visual(linewise: false)), c1)
        case "V": return done(.action(.visual(linewise: true)), c1)
        case "gv": return done(.action(.reselect), c1)
        case "zz", "z.": return done(.action(.scroll(.cursorToCenter, firstNonBlank: key == "z.")), c1)
        case "zt", "z<cr>": return done(.action(.scroll(.cursorToTop, firstNonBlank: key == "z<cr>")), c1)
        case "zb", "z-": return done(.action(.scroll(.cursorToBottom, firstNonBlank: key == "z-")), c1)
        case "<c-e>": return done(.action(.scrollLines(1)), c1)
        case "<c-y>": return done(.action(.scrollLines(-1)), c1)
        case ":", "/", "?": return done(.action(.commandLine(key.first!)), c1)
        case "<esc>", "<c-c>": return done(.action(.cancel), c1)
        default: break
        }
        var j = keyStart
        switch motion(t, &j) {
        case .some(.some(let m)): return done(.move(m), c1)
        case .some(.none): return .incomplete
        case .none: return .invalid
        }
    }

    static let operators: [String: VimOperator] = [
        "d": .delete, "c": .change, "y": .yank, ">": .indent, "<": .outdent, "=": .reindent,
        "gU": .uppercase, "gu": .lowercase, "g~": .toggleCase,
    ]

    static let visualOperators: [String: VimOperator] = [
        "d": .delete, "x": .delete, "<del>": .delete, "c": .change, "s": .change, "y": .yank,
        ">": .indent, "<": .outdent, "=": .reindent,
        "U": .uppercase, "u": .lowercase, "~": .toggleCase, "gU": .uppercase, "gu": .lowercase, "g~": .toggleCase,
    ]

    static let visualLineOperators: [String: VimOperator] = [
        "D": .delete, "X": .delete, "C": .change, "S": .change, "R": .change, "Y": .yank,
    ]

    static func isRegister(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c == "+" || c == "*" || c == "_" || c == "\"")
    }

    /// A key as the character it types, for `r` and `f`.
    static func typed(_ token: String) -> String? {
        switch token {
        case "<tab>": return "\t"
        case "<cr>": return "\n"
        default: return token.hasPrefix("<") && token.count > 1 ? nil : token
        }
    }

    static func count(_ t: [String], _ i: inout Int) -> Int? {
        var n: Int?
        while i < t.count, t[i].count == 1, let d = t[i].first?.wholeNumberValue, d < 10, t[i].first!.isASCII {
            if n == nil && d == 0 { break }
            n = min((n ?? 0) * 10 + d, 99_999)
            i += 1
        }
        return n
    }

    static func textObject(_ token: String, around: Bool) -> VimTextObject? {
        switch token {
        case "w": return .word(big: false, around: around)
        case "W": return .word(big: true, around: around)
        case "\"", "'", "`": return .quote(token.first!, around: around)
        case "(", ")", "b": return .pair(open: "(", close: ")", around: around)
        case "[", "]": return .pair(open: "[", close: "]", around: around)
        case "{", "}", "B": return .pair(open: "{", close: "}", around: around)
        case "<", ">": return .pair(open: "<", close: ">", around: around)
        case "p": return .paragraph(around: around)
        default: return nil
        }
    }

    /// `.some(nil)`: needs more keys; `nil`: not a motion.
    static func motion(_ t: [String], _ i: inout Int) -> VimMotion?? {
        guard i < t.count else { return .some(nil) }
        let key = t[i]
        i += 1
        switch key {
        case "h", "<left>", "<bs>", "<c-h>": return .left
        case "l", "<right>", " ": return .right
        case "j", "<down>", "<c-n>", "<c-j>": return .down
        case "k", "<up>", "<c-p>": return .up
        case "+", "<cr>": return .nextLineStart
        case "-": return .prevLineStart
        case "_": return .currentLine
        case "w": return .wordForward(big: false)
        case "W": return .wordForward(big: true)
        case "b": return .wordBack(big: false)
        case "B": return .wordBack(big: true)
        case "e": return .wordEnd(big: false)
        case "E": return .wordEnd(big: true)
        case "0", "<home>": return .lineStart
        case "^": return .firstNonBlank
        case "$", "<end>": return .lineEnd
        case "G": return .fileEnd
        case "%": return .matchPair
        case "{": return .paragraphBack
        case "}": return .paragraphForward
        case "H": return .screenTop
        case "M": return .screenMiddle
        case "L": return .screenBottom
        case "<c-d>": return .halfPageDown
        case "<c-u>": return .halfPageUp
        case "<c-f>", "<pagedown>": return .pageDown
        case "<c-b>", "<pageup>": return .pageUp
        case "n": return .searchNext(reverse: false)
        case "N": return .searchNext(reverse: true)
        case "*": return .searchWord(forward: true)
        case "#": return .searchWord(forward: false)
        case ";": return .repeatFind(reverse: false)
        case ",": return .repeatFind(reverse: true)
        case "g":
            guard i < t.count else { return .some(nil) }
            let second = t[i]
            i += 1
            switch second {
            case "g": return .fileStart
            case "e": return .wordEndBack(big: false)
            case "E": return .wordEndBack(big: true)
            case "_": return .lastNonBlank
            default: return nil
            }
        case "f", "F", "t", "T":
            guard i < t.count else { return .some(nil) }
            guard let c = typed(t[i]) else { return nil }
            i += 1
            return .find(c, forward: key == "f" || key == "t", till: key == "t" || key == "T")
        case "`", "'":
            guard i < t.count else { return .some(nil) }
            let mark = t[i]
            i += 1
            guard mark.count == 1, let c = mark.first else { return nil }
            return .mark(c, linewise: key == "'")
        default: return nil
        }
    }
}
