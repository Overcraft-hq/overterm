import Foundation

extension VimEngine {
    func handleCommandLine(_ key: VimKey) {
        for token in key.tokens {
            guard var line = commandLine else { return }
            switch token {
            case "<esc>", "<c-c>":
                closeCommandLine()
                return
            case "<cr>":
                executeCommandLine()
                return
            case "<bs>", "<c-h>":
                if line.count <= 1 {
                    closeCommandLine()
                    return
                }
                line.removeLast()
            case "<c-u>":
                line = String(line.prefix(1))
            case "<c-w>":
                while line.count > 1, line.last == " " { line.removeLast() }
                while line.count > 1, let c = line.last, c != " " { line.removeLast() }
            default:
                if token.hasPrefix("<") && token.count > 1 { continue }
                line += token
            }
            commandLine = line
        }
    }

    func closeCommandLine() {
        commandLine = nil
        mode = commandLineReturn
        if isVisual { updateVisualSelection() }
    }

    func executeCommandLine() {
        guard let line = commandLine, let kind = line.first else { return }
        let body = String(line.dropFirst())
        closeCommandLine()
        switch kind {
        case "/", "?":
            let pattern = body.isEmpty ? lastSearch?.pattern : body
            guard let pattern else {
                message = "No previous search"
                return
            }
            lastSearch = (pattern, kind == "/", nil)
            _ = move(.searchNext(reverse: false), count: commandLineCount)
        default:
            ex(body)
        }
    }

    // MARK: Search

    /// `/` patterns are regular expressions (ICU, close to Zed's), matched
    /// ignoring case unless they have a capital — smartcase.
    func regex(_ pattern: String, caseSensitive: Bool?) -> NSRegularExpression? {
        let sensitive = caseSensitive ?? (pattern != pattern.lowercased())
        let key = (sensitive ? "s:" : "i:") + pattern
        if let cached = regexCache, cached.key == key { return cached.regex }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !sensitive { options.insert(.caseInsensitive) }
        let translated = pattern.replacingOccurrences(of: "\\<", with: "\\b").replacingOccurrences(of: "\\>", with: "\\b")
        guard
            let regex = (try? NSRegularExpression(pattern: translated, options: options))
                ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: options))
        else { return nil }
        regexCache = (key, regex)
        return regex
    }

    /// The `count`th match from `p`, wrapping around the end.
    func search(_ pattern: String, caseSensitive: Bool?, forward: Bool, from p: Int, count: Int, _ t: VimText) -> Int? {
        guard let regex = regex(pattern, caseSensitive: caseSensitive) else { return nil }
        var q = p
        for _ in 0..<count {
            guard let m = forward ? nextMatch(regex, after: q, t) : previousMatch(regex, before: q, t) else {
                message = "Pattern not found: \(pattern)"
                return nil
            }
            q = m
        }
        return q
    }

    private static let matching: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]

    func nextMatch(_ regex: NSRegularExpression, after p: Int, _ t: VimText) -> Int? {
        let s = t.string as String
        let start = min(t.next(p), t.length)
        if let m = regex.firstMatch(in: s, options: Self.matching, range: NSRange(location: start, length: t.length - start)) {
            return m.range.location
        }
        return regex.firstMatch(in: s, options: Self.matching, range: NSRange(location: 0, length: t.length))?.range.location
    }

    func previousMatch(_ regex: NSRegularExpression, before p: Int, _ t: VimText) -> Int? {
        lastMatch(regex, before: p, t) ?? lastMatch(regex, before: t.length + 1, t)
    }

    /// Scans back in growing chunks: the last match before the cursor
    /// without matching the whole file from the top.
    private func lastMatch(_ regex: NSRegularExpression, before limit: Int, _ t: VimText) -> Int? {
        let s = t.string as String
        var chunk = 4096
        while true {
            let lo = max(0, limit - chunk)
            var found: Int?
            regex.enumerateMatches(in: s, options: Self.matching, range: NSRange(location: lo, length: t.length - lo)) { m, _, stop in
                guard let m else { return }
                if m.range.location < limit { found = m.range.location } else { stop.pointee = true }
            }
            if found != nil || lo == 0 { return found }
            chunk *= 4
        }
    }

    // MARK: Ex

    /// `:N`, `:s`, ranges (`%`, `'<,'>`, `N,M`, `.`, `$`); the rest goes to `exCommand`.
    func ex(_ body: String) {
        var s = Substring(body.trimmingCharacters(in: .whitespaces))
        guard !s.isEmpty else { return }
        let t = text
        let here = t.clampNormal(buffer.selection.location)
        var range: (Int, Int)?
        if s.hasPrefix("%") {
            s.removeFirst()
            range = (0, t.lineStart(t.length))
        } else if let a = address(&s, t, here) {
            var b = a
            if s.hasPrefix(",") {
                s.removeFirst()
                guard let second = address(&s, t, here) else {
                    message = "Invalid range"
                    return
                }
                b = second
            }
            range = (min(a, b), max(a, b))
        }
        let command = s.trimmingCharacters(in: .whitespaces)
        if command.isEmpty {
            if let range {
                lastJump = here
                setCursor(t.clampNormal(t.firstNonBlank(range.1)))
            }
            return
        }
        if command.hasPrefix("s"), command.count > 1, let d = command.dropFirst().first, !d.isLetter, !d.isNumber, d != " " {
            let line = t.lineStart(here)
            substitute(String(command.dropFirst()), range: range ?? (line, line))
            return
        }
        if let exCommand {
            message = exCommand(command)
        } else {
            message = "Not an editor command: \(command)"
        }
    }

    private func address(_ s: inout Substring, _ t: VimText, _ here: Int) -> Int? {
        if s.hasPrefix(".") {
            s.removeFirst()
            return t.lineStart(here)
        }
        if s.hasPrefix("$") {
            s.removeFirst()
            return t.lineStart(t.length)
        }
        if s.hasPrefix("'"), s.count >= 2 {
            let mark = s[s.index(after: s.startIndex)]
            let offset: Int?
            switch mark {
            case "<": offset = lastVisual.map { min($0.anchor, $0.cursor) }
            case ">": offset = lastVisual.map { max($0.anchor, $0.cursor) }
            default: offset = marks[mark]
            }
            guard let offset else { return nil }
            s.removeFirst(2)
            return t.lineStart(min(offset, t.length))
        }
        let digits = s.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        s.removeFirst(digits.count)
        return t.lineStart(number: max(1, n))
    }

    /// `:s/pattern/replacement/flags` over the lines, as one undo step.
    func substitute(_ arg: String, range: (Int, Int)) {
        let delimiter = arg.first!
        var parts: [String] = [""]
        var escaped = false
        for c in arg.dropFirst() {
            if escaped {
                if c != delimiter { parts[parts.count - 1].append("\\") }
                parts[parts.count - 1].append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == delimiter && parts.count < 3 {
                parts.append("")
            } else {
                parts[parts.count - 1].append(c)
            }
        }
        if escaped { parts[parts.count - 1].append("\\") }
        let flags = parts.count > 2 ? parts[2] : ""
        guard let pattern = parts[0].isEmpty ? lastSearch?.pattern : parts[0] else {
            message = "No previous regular expression"
            return
        }
        let caseSensitive: Bool? = flags.contains("i") ? false : flags.contains("I") ? true : nil
        guard let regex = regex(pattern, caseSensitive: caseSensitive) else { return }
        lastSearch = (pattern, true, caseSensitive)
        let template = Self.template(parts.count > 1 ? parts[1] : "")
        let global = flags.contains("g")

        let t = text
        let start = t.lineStart(range.0)
        let end = t.lineEnd(range.1)
        let lines = t.substring(start, end).components(separatedBy: "\n")
        var changed: [Int: String] = [:]
        for (i, line) in lines.enumerated() {
            let whole = NSRange(location: 0, length: (line as NSString).length)
            if global {
                guard regex.firstMatch(in: line, range: whole) != nil else { continue }
                changed[i] = regex.stringByReplacingMatches(in: line, range: whole, withTemplate: template)
            } else if let m = regex.firstMatch(in: line, range: whole) {
                let replacement = regex.replacementString(for: m, in: line, offset: 0, template: template)
                changed[i] = (line as NSString).replacingCharacters(in: m.range, with: replacement)
            }
        }
        guard let first = changed.keys.min(), let last = changed.keys.max() else {
            message = "Pattern not found: \(pattern)"
            return
        }
        var offset = start
        for i in 0..<first { offset += (lines[i] as NSString).length + 1 }
        var oldLength = 0
        var new: [String] = []
        for i in first...last {
            oldLength += (lines[i] as NSString).length + (i < last ? 1 : 0)
            new.append(changed[i] ?? lines[i])
        }
        beginGroup()
        buffer.replace(NSRange(location: offset, length: oldLength), with: new.joined(separator: "\n"))
        endGroup()
        let lastLine = offset + new.dropLast().reduce(0) { $0 + ($1 as NSString).length + 1 }
        let after = text
        setCursor(after.clampNormal(after.firstNonBlank(lastLine)))
    }

    /// Vim's replacement (`\1`, `&`, `\n`) as an NSRegularExpression template.
    static func template(_ replacement: String) -> String {
        var out = ""
        let chars = Array(replacement)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let d = chars[i + 1]
                i += 2
                switch d {
                case "0"..."9": out += "$\(d)"
                case "n", "r": out += "\n"
                case "t": out += "\t"
                case "\\": out += "\\\\"
                case "$": out += "\\$"
                default: out.append(d)
                }
                continue
            }
            if c == "&" {
                out += "$0"
            } else if c == "$" {
                out += "\\$"
            } else if c == "\\" {
                out += "\\\\"
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }
}
