import Foundation

extension VimEngine {
    func operate(_ op: VimOperator, _ target: VimTarget, _ command: VimCommand) -> Bool {
        let t = text
        let fromVisual = isVisual
        let p = fromVisual ? visualCursor : t.clampNormal(buffer.selection.location)
        let range: VimRange
        switch target {
        case .lines:
            range = .lines(p, t.lineDown(p, max(1, command.count ?? 1) - 1).start)
        case .motion(let m):
            guard let target = evaluate(m, from: p, count: command.count, op: op, t) else {
                // `s` on an empty line still changes something: nothing.
                if op == .change && m == .right {
                    enterInsert(at: p)
                    return true
                }
                return false
            }
            if target.jump { lastJump = p }
            let a = min(p, target.pos)
            let b = max(p, target.pos)
            switch target.kind {
            case .linewise: range = .lines(a, b)
            case .exclusive: range = .chars(NSRange(location: a, length: b - a))
            case .inclusive: range = .chars(NSRange(location: a, length: min(t.length, t.next(b)) - a))
            }
        case .object(let object):
            guard let r = textObject(object, at: p, count: command.count, op: op, t) else { return false }
            range = r
        case .selection, .selectionLines:
            let a = min(visualAnchor, visualCursor)
            let b = max(visualAnchor, visualCursor)
            if mode == .visualLine || target == .selectionLines {
                range = .lines(a, b)
            } else {
                range = .chars(NSRange(location: a, length: min(t.length, t.next(b)) - a))
            }
            lastVisual = (visualAnchor, visualCursor, mode == .visualLine)
            mode = .normal
        }
        let times = fromVisual ? max(1, command.count ?? 1) : 1
        return apply(op, range, register: command.register, cursor: p, fromVisual: fromVisual, times: times, t)
    }

    /// The text a linewise operator takes, and what deleting it removes: the
    /// last line takes the newline before it instead of one after.
    func lineSpan(_ first: Int, _ last: Int, _ t: VimText) -> (text: String, delete: NSRange, content: NSRange) {
        let start = t.lineStart(first)
        let end = t.lineEnd(max(first, last))
        let content = NSRange(location: start, length: end - start)
        let delete: NSRange
        if end < t.length {
            delete = NSRange(location: start, length: end + 1 - start)
        } else if start > 0 {
            delete = NSRange(location: start - 1, length: end - start + 1)
        } else {
            delete = NSRange(location: 0, length: t.length)
        }
        return (t.substring(content) + "\n", delete, content)
    }

    func apply(_ op: VimOperator, _ range: VimRange, register: Character?, cursor p: Int, fromVisual: Bool, times: Int, _ t: VimText) -> Bool {
        switch op {
        case .yank:
            switch range {
            case .chars(let r):
                store(t.substring(r), linewise: false, register: register)
                setCursor(t.clampNormal(r.location))
            case .lines(let first, let last):
                store(lineSpan(first, last, t).text, linewise: true, register: register)
                if fromVisual {
                    setCursor(t.clampNormal(first))
                } else if t.lineStart(first) < t.lineStart(p) {
                    setCursor(t.clampNormal(t.position(column: t.column(p), lineStart: t.lineStart(first))))
                } else {
                    setCursor(p)
                }
            }
        case .delete:
            switch range {
            case .chars(let r):
                guard r.length > 0 else { return false }
                store(t.substring(r), linewise: false, register: register)
                buffer.replace(r, with: "")
                setCursor(text.clampNormal(r.location))
            case .lines(let first, let last):
                let span = lineSpan(first, last, t)
                store(span.text, linewise: true, register: register)
                buffer.replace(span.delete, with: "")
                let after = text
                setCursor(after.clampNormal(after.firstNonBlank(min(span.delete.location, after.length))))
            }
        case .change:
            switch range {
            case .chars(let r):
                if r.length > 0 { store(t.substring(r), linewise: false, register: register) }
                buffer.replace(r, with: "")
                enterInsert(at: r.location)
            case .lines(let first, let last):
                let span = lineSpan(first, last, t)
                store(span.text, linewise: true, register: register)
                let indent = t.indentation(first)
                buffer.replace(span.content, with: indent)
                enterInsert(at: span.content.location + indent.utf16.count)
                insertAutoIndent = !indent.isEmpty
            }
        case .indent, .outdent:
            let (first, last): (Int, Int)
            switch range {
            case .chars(let r): (first, last) = (r.location, max(r.location, NSMaxRange(r) - 1))
            case .lines(let a, let b): (first, last) = (a, b)
            }
            shift(first, last, outdent: op == .outdent, times: times, t)
            let after = text
            setCursor(after.clampNormal(after.firstNonBlank(t.lineStart(first))))
        case .reindent:
            let first: Int
            switch range {
            case .chars(let r): first = r.location
            case .lines(let a, _): first = a
            }
            setCursor(t.clampNormal(t.firstNonBlank(first)))
        case .uppercase, .lowercase, .toggleCase:
            let r: NSRange
            switch range {
            case .chars(let chars): r = chars
            case .lines(let first, let last): r = lineSpan(first, last, t).content
            }
            let old = t.substring(r)
            let new = Self.changeCase(old, op)
            if new != old { buffer.replace(r, with: new) }
            let after = text
            if case .lines = range, !fromVisual {
                setCursor(after.clampNormal(p))
            } else {
                setCursor(after.clampNormal(r.location))
            }
        }
        return true
    }

    static func changeCase(_ s: String, _ op: VimOperator) -> String {
        switch op {
        case .uppercase: return s.uppercased()
        case .lowercase: return s.lowercased()
        default:
            return String(s.flatMap { c -> String in c.isUppercase ? c.lowercased() : c.isLowercase ? c.uppercased() : String(c) })
        }
    }

    /// `>` and `<`: edits worked out first, made from the bottom up so the
    /// offsets above stay true.
    func shift(_ first: Int, _ last: Int, outdent: Bool, times: Int, _ t: VimText) {
        let unit = buffer.indentUnit()
        let width = unit == "\t" ? 4 : max(1, unit.count)
        var edits: [(NSRange, String)] = []
        var ls = t.lineStart(first)
        let lastLine = t.lineStart(last)
        while true {
            if outdent {
                var i = ls
                for _ in 0..<times {
                    if t.isBlank(i) && t[i] == 9 {
                        i += 1
                    } else {
                        var spaces = 0
                        while spaces < width && i < t.length && t[i] == 32 {
                            i += 1
                            spaces += 1
                        }
                    }
                }
                if i > ls { edits.append((NSRange(location: ls, length: i - ls), "")) }
            } else if !t.lineIsEmpty(ls) {
                edits.append((NSRange(location: ls, length: 0), String(repeating: unit, count: times)))
            }
            let le = t.lineEnd(ls)
            if ls >= lastLine || le >= t.length { break }
            ls = le + 1
        }
        for (range, string) in edits.reversed() { buffer.replace(range, with: string) }
    }

    // MARK: Simple changes

    func toggleCaseChars(_ n: Int) -> Bool {
        let t = text
        let p = t.clampNormal(buffer.selection.location)
        let le = t.lineEnd(p)
        guard p < le else { return false }
        var e = p
        for _ in 0..<n where e < le { e = t.next(e) }
        let r = NSRange(location: p, length: e - p)
        let new = Self.changeCase(t.substring(r), .toggleCase)
        buffer.replace(r, with: new)
        let after = text
        setCursor(after.clampNormal(p + new.utf16.count))
        return true
    }

    func replaceChars(with c: String, count n: Int) -> Bool {
        let t = text
        let p = t.clampNormal(buffer.selection.location)
        let le = t.lineEnd(p)
        var e = p
        for _ in 0..<n {
            guard e < le else { return false }
            e = t.next(e)
        }
        let r = NSRange(location: p, length: e - p)
        if c == "\n" {
            buffer.replace(r, with: "\n")
            setCursor(p + 1)
        } else {
            buffer.replace(r, with: String(repeating: c, count: n))
            setCursor(p + (n - 1) * c.utf16.count)
        }
        return true
    }

    func visualReplace(with c: String) -> Bool {
        let t = text
        let r = buffer.selection
        let old = t.substring(r)
        let new = String(old.map { $0 == "\n" ? "\n" : Character(c == "\n" ? " " : c) })
        lastVisual = (visualAnchor, visualCursor, mode == .visualLine)
        mode = .normal
        buffer.replace(r, with: new)
        setCursor(text.clampNormal(r.location))
        return true
    }

    func join(spaces: Bool, count: Int?) -> Bool {
        var t = text
        var p: Int
        var joins: Int
        if isVisual {
            let a = min(visualAnchor, visualCursor)
            let b = max(visualAnchor, visualCursor)
            var lines = 0
            var ls = t.lineStart(a)
            let last = t.lineStart(b)
            while ls < last {
                ls = t.lineEnd(ls) + 1
                lines += 1
            }
            joins = max(1, lines)
            p = a
            exitVisual()
        } else {
            p = t.clampNormal(buffer.selection.location)
            joins = max(2, count ?? 2) - 1
        }
        var at: Int?
        for _ in 0..<joins {
            let ls = t.lineStart(p)
            let le = t.lineEnd(p)
            guard le < t.length else { break }
            var contentStart = le + 1
            var insertion = ""
            if spaces {
                while t.isBlank(contentStart) { contentStart += 1 }
                let nextEmpty = contentStart >= t.length || t[contentStart] == VimText.newline
                if !(nextEmpty || t[contentStart] == 41 || le == ls || t.isBlank(le - 1)) { insertion = " " }
            }
            buffer.replace(NSRange(location: le, length: contentStart - le), with: insertion)
            at = le
            p = le
            t = text
        }
        guard let at else { return false }
        setCursor(t.clampNormal(at))
        return true
    }

    // MARK: Put

    func put(before: Bool, _ command: VimCommand) -> Bool {
        guard let (string, linewise) = read(register: command.register), !string.isEmpty else { return false }
        let t = text
        let p = t.clampNormal(buffer.selection.location)
        let n = max(1, command.count ?? 1)
        if linewise {
            var line = string
            if !line.hasSuffix("\n") { line += "\n" }
            let block = String(repeating: line, count: n)
            if before {
                let at = t.lineStart(p)
                buffer.replace(NSRange(location: at, length: 0), with: block)
                setCursor(text.firstNonBlank(at))
            } else {
                let le = t.lineEnd(p)
                if le < t.length {
                    buffer.replace(NSRange(location: le + 1, length: 0), with: block)
                    setCursor(text.firstNonBlank(le + 1))
                } else {
                    buffer.replace(NSRange(location: le, length: 0), with: "\n" + block.dropLast())
                    setCursor(text.firstNonBlank(le + 1))
                }
            }
        } else {
            let block = String(repeating: string, count: n)
            let at = before || t.lineIsEmpty(p) ? p : t.next(p)
            buffer.replace(NSRange(location: at, length: 0), with: block)
            let after = text
            if block.contains("\n") {
                setCursor(after.clampNormal(at))
            } else {
                setCursor(after.clampNormal(after.prev(at + block.utf16.count)))
            }
        }
        return true
    }

    /// `p` over a selection: it replaces it, and (`p`, not `P`) the
    /// replaced text becomes the register.
    func visualPut(before: Bool, _ command: VimCommand) -> Bool {
        guard let (string, linewise) = read(register: command.register) else { return false }
        let t = text
        let a = min(visualAnchor, visualCursor)
        let b = max(visualAnchor, visualCursor)
        let wasLinewise = mode == .visualLine
        let range: NSRange
        let old: String
        let replacement: String
        if wasLinewise {
            let span = lineSpan(a, b, t)
            range = span.content
            old = span.text
            replacement = linewise && string.hasSuffix("\n") ? String(string.dropLast()) : string
        } else {
            range = NSRange(location: a, length: min(t.length, t.next(b)) - a)
            old = t.substring(range)
            replacement = linewise ? "\n" + string : string
        }
        lastVisual = (visualAnchor, visualCursor, wasLinewise)
        mode = .normal
        buffer.replace(range, with: replacement)
        if !before { store(old, linewise: wasLinewise, register: nil) }
        let after = text
        if linewise || wasLinewise {
            let start = linewise && !wasLinewise ? range.location + 1 : range.location
            setCursor(after.clampNormal(after.firstNonBlank(start)))
        } else {
            setCursor(after.clampNormal(after.prev(range.location + replacement.utf16.count)))
        }
        return true
    }
}
