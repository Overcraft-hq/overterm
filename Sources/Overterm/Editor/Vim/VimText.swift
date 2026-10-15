import Foundation

/// Reads over the text for motions and text objects. Every scan is local to
/// the cursor — nothing builds a list of lines — and UTF-16 units come from a
/// copied window, not an Objective-C call each. Positions are UTF-16 offsets;
/// stepping goes by composed character, so an emoji or `İ` + a combining mark
/// is never split.
final class VimText {
    let string: NSString
    let length: Int
    private var window = [unichar](repeating: 0, count: 4096)
    private var base = 0
    private var filled = 0

    static let newline: unichar = 10

    init(_ string: NSString) {
        self.string = string
        self.length = string.length
    }

    subscript(i: Int) -> unichar {
        if i < base || i >= base + filled { fill(around: i) }
        return window[i - base]
    }

    private func fill(around i: Int) {
        let size = window.count
        base = max(0, min(i - size / 2, length - size))
        filled = min(size, length - base)
        let range = NSRange(location: base, length: filled)
        window.withUnsafeMutableBufferPointer { string.getCharacters($0.baseAddress!, range: range) }
    }

    func substring(_ range: NSRange) -> String { string.substring(with: range) }

    func substring(_ from: Int, _ to: Int) -> String { string.substring(with: NSRange(location: from, length: to - from)) }

    // MARK: Characters

    /// The end of the composed character at `i`.
    func next(_ i: Int) -> Int {
        if i >= length { return length }
        if self[i] < 0x300, i + 1 >= length || self[i + 1] < 0x300 { return i + 1 }
        return NSMaxRange(string.rangeOfComposedCharacterSequence(at: i))
    }

    /// The start of the composed character before `i`.
    func prev(_ i: Int) -> Int {
        if i <= 0 { return 0 }
        if self[i - 1] < 0x300 { return i - 1 }
        return string.rangeOfComposedCharacterSequence(at: i - 1).location
    }

    /// `p` moved back to the start of the composed character it is inside.
    func composedStart(_ p: Int) -> Int {
        if p >= length || p <= 0 { return max(0, min(p, length)) }
        if self[p] < 0x300 && !UTF16.isTrailSurrogate(self[p]) { return p }
        return string.rangeOfComposedCharacterSequence(at: p).location
    }

    func character(at i: Int) -> String { i < length ? substring(i, next(i)) : "" }

    func isNewline(_ i: Int) -> Bool { i < length && self[i] == VimText.newline }

    func isBlank(_ i: Int) -> Bool {
        guard i < length else { return false }
        let u = self[i]
        return u == 32 || u == 9
    }

    /// Vim's character classes: 0 blank (and newline), 1 punctuation, 2 word,
    /// 3 emoji/symbols. `big` (W B E) folds everything but blanks into one.
    func charClass(_ i: Int, big: Bool) -> Int {
        guard i < length else { return 0 }
        let u = self[i]
        if u == 10 || u == 32 || u == 9 || u == 13 { return 0 }
        if big { return 2 }
        if u < 0x80 {
            let c = UInt8(u)
            let word = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
            return word ? 2 : 1
        }
        var value = UInt32(u)
        if UTF16.isLeadSurrogate(u), i + 1 < length, UTF16.isTrailSurrogate(self[i + 1]) {
            value = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(self[i + 1]) - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(value) else { return 1 }
        let props = scalar.properties
        if props.isWhitespace { return 0 }
        if props.isAlphabetic || props.numericType != nil { return 2 }
        switch props.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .connectorPunctuation: return 2
        default: break
        }
        if props.isEmoji && value > 0xFF { return 3 }
        return 1
    }

    // MARK: Lines

    func lineStart(_ p: Int) -> Int {
        var i = min(max(p, 0), length)
        while i > 0 && self[i - 1] != VimText.newline { i -= 1 }
        return i
    }

    /// The offset of the line's newline, or the end of the text.
    func lineEnd(_ p: Int) -> Int {
        var i = max(p, 0)
        while i < length && self[i] != VimText.newline { i += 1 }
        return i
    }

    func firstNonBlank(_ p: Int) -> Int {
        var i = lineStart(p)
        while isBlank(i) { i += 1 }
        return i
    }

    func lineIsEmpty(_ p: Int) -> Bool { lineStart(p) == lineEnd(p) }

    func lineIsBlank(_ p: Int) -> Bool {
        var i = lineStart(p)
        while isBlank(i) { i += 1 }
        return i >= length || self[i] == VimText.newline
    }

    func indentation(_ p: Int) -> String {
        let ls = lineStart(p)
        var i = ls
        while isBlank(i) { i += 1 }
        return substring(ls, i)
    }

    /// The start of the line `count` lines below (fewer at the end).
    func lineDown(_ p: Int, _ count: Int) -> (start: Int, moved: Int) {
        var ls = lineStart(p)
        var moved = 0
        while moved < count {
            let le = lineEnd(ls)
            if le >= length { break }
            ls = le + 1
            moved += 1
        }
        return (ls, moved)
    }

    func lineUp(_ p: Int, _ count: Int) -> (start: Int, moved: Int) {
        var ls = lineStart(p)
        var moved = 0
        while moved < count && ls > 0 {
            ls = lineStart(ls - 1)
            moved += 1
        }
        return (ls, moved)
    }

    /// The start of 1-based line `n`, or of the last line.
    func lineStart(number n: Int) -> Int {
        var ls = 0
        var line = 1
        while line < n {
            let r = string.range(of: "\n", options: .literal, range: NSRange(location: ls, length: length - ls))
            if r.location == NSNotFound { break }
            ls = r.location + 1
            line += 1
        }
        return ls
    }

    /// Normal mode's cursor: on a character, never on a line's newline unless
    /// the line is empty.
    func clampNormal(_ p: Int) -> Int {
        guard length > 0 else { return 0 }
        let p = min(max(p, 0), length)
        let ls = lineStart(p)
        let le = lineEnd(p)
        if le == ls { return ls }
        if p >= le { return prev(le) }
        return composedStart(p)
    }

    /// Visual mode may also sit on a newline (`v$`, an empty line).
    func clampVisual(_ p: Int) -> Int {
        guard length > 0 else { return 0 }
        return composedStart(min(max(p, 0), length - 1))
    }

    /// Composed characters from the line's start.
    func column(_ p: Int) -> Int {
        var i = lineStart(p)
        var c = 0
        while i < p {
            i = next(i)
            c += 1
        }
        return c
    }

    /// The position `column` characters into the line at `ls`, or its end.
    func position(column: Int, lineStart ls: Int) -> Int {
        let le = lineEnd(ls)
        var i = ls
        var c = 0
        while c < column && i < le {
            i = next(i)
            c += 1
        }
        return i
    }

    // MARK: Words

    func wordForward(_ p: Int, big: Bool) -> Int {
        var i = p
        let c = charClass(i, big: big)
        if c != 0 {
            while i < length && charClass(i, big: big) == c { i = next(i) }
        }
        while i < length && charClass(i, big: big) == 0 {
            if self[i] == VimText.newline {
                i += 1
                if isNewline(i) { return i }  // an empty line is a word
            } else {
                i += 1
            }
        }
        return i
    }

    func wordEnd(_ p: Int, big: Bool) -> Int {
        var i = next(p)
        while i < length && charClass(i, big: big) == 0 { i += 1 }
        guard i < length else { return prev(length) }
        let c = charClass(i, big: big)
        while true {
            let n = next(i)
            if n >= length || charClass(n, big: big) != c { return i }
            i = n
        }
    }

    func wordBack(_ p: Int, big: Bool) -> Int {
        guard p > 0 else { return 0 }
        var i = prev(p)
        while i > 0 && charClass(i, big: big) == 0 {
            if self[i] == VimText.newline && self[i - 1] == VimText.newline { return i }
            i = prev(i)
        }
        let c = charClass(i, big: big)
        if c == 0 { return i }
        while i > 0 {
            let q = prev(i)
            if charClass(q, big: big) != c { break }
            i = q
        }
        return i
    }

    func wordEndBack(_ p: Int, big: Bool) -> Int {
        var i = p
        let c = charClass(i, big: big)
        if c != 0 {
            while i > 0 && charClass(i, big: big) == c { i = prev(i) }
            if charClass(i, big: big) == c { return 0 }
        }
        while i > 0 && charClass(i, big: big) == 0 {
            if self[i] == VimText.newline && (self[i - 1] == VimText.newline) { return i }
            i = prev(i)
        }
        return i
    }

    // MARK: Pairs

    static let pairs: [unichar: (open: unichar, close: unichar)] = [
        40: (40, 41), 41: (40, 41), 91: (91, 93), 93: (91, 93), 123: (123, 125), 125: (123, 125), 60: (60, 62), 62: (60, 62),
    ]

    /// The bracket matching the one at `p`.
    func match(_ p: Int) -> Int? {
        guard p < length, let pair = VimText.pairs[self[p]] else { return nil }
        if self[p] == pair.open {
            return matchForward(from: p + 1, pair.open, pair.close)
        }
        return unmatchedOpen(before: p, pair.open, pair.close)
    }

    func matchForward(from p: Int, _ open: unichar, _ close: unichar) -> Int? {
        var depth = 0
        var i = p
        while i < length {
            let u = self[i]
            if u == open {
                depth += 1
            } else if u == close {
                if depth == 0 { return i }
                depth -= 1
            }
            i += 1
        }
        return nil
    }

    func unmatchedOpen(before p: Int, _ open: unichar, _ close: unichar) -> Int? {
        var depth = 0
        var i = p - 1
        while i >= 0 {
            let u = self[i]
            if u == close {
                depth += 1
            } else if u == open {
                if depth == 0 { return i }
                depth -= 1
            }
            i -= 1
        }
        return nil
    }
}
