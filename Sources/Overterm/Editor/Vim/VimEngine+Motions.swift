import Foundation

/// Where a motion lands and how an operator takes the text up to it.
struct VimMotionTarget {
    enum Kind { case exclusive, inclusive, linewise }
    var pos: Int
    var kind: Kind
    /// G, %, a search, a mark: `` ` `` comes back to where it started.
    var jump = false
}

/// What an operator works on.
enum VimRange: Equatable {
    case chars(NSRange)
    /// Whole lines, from the line holding the first offset to the line holding the last.
    case lines(Int, Int)
}

extension VimEngine {
    func move(_ m: VimMotion, count: Int?) -> Bool {
        let t = text
        let p = isVisual ? visualCursor : t.clampNormal(buffer.selection.location)
        let goal = desiredColumn ?? t.column(p)
        guard let target = evaluate(m, from: p, count: count, op: nil, t) else { return false }
        if target.jump { lastJump = p }
        switch m {
        case .halfPageDown, .pageDown, .halfPageUp, .pageUp:
            let lines = visibleLineCount(t)
            let half = m == .halfPageDown || m == .halfPageUp
            let amount = count ?? (half ? max(1, lines / 2) : max(1, lines - 2))
            buffer.scroll(.lines(m == .halfPageDown || m == .pageDown ? amount : -amount))
        default: break
        }
        let atLineEnd = m == .lineEnd || (m.isVertical && goal == Int.max)
        place(target.pos, t, allowLineEnd: atLineEnd)
        if m.isVertical {
            desiredColumn = goal
        } else if m == .lineEnd {
            desiredColumn = Int.max
        } else {
            desiredColumn = nil
        }
        return true
    }

    func evaluate(_ m: VimMotion, from p: Int, count: Int?, op: VimOperator?, _ t: VimText) -> VimMotionTarget? {
        let n = max(1, count ?? 1)
        let len = t.length
        func vertical(_ down: Bool, _ lines: Int) -> VimMotionTarget? {
            let (ls, moved) = down ? t.lineDown(p, lines) : t.lineUp(p, lines)
            guard moved > 0 else { return nil }
            let goal = desiredColumn ?? t.column(p)
            return VimMotionTarget(pos: t.position(column: goal, lineStart: ls), kind: .linewise)
        }
        switch m {
        case .left:
            let ls = t.lineStart(p)
            var q = p
            for _ in 0..<n where q > ls { q = t.prev(q) }
            return q == p ? nil : VimMotionTarget(pos: q, kind: .exclusive)
        case .right:
            let le = t.lineEnd(p)
            var q = p
            for _ in 0..<n {
                let next = t.next(q)
                if next > le || (next == le && op == nil) { break }
                q = next
            }
            return q == p ? nil : VimMotionTarget(pos: q, kind: .exclusive)
        case .down: return vertical(true, n)
        case .up: return vertical(false, n)
        case .halfPageDown, .halfPageUp, .pageDown, .pageUp:
            let lines = visibleLineCount(t)
            let half = m == .halfPageDown || m == .halfPageUp
            let amount = count ?? (half ? max(1, lines / 2) : max(1, lines - 2))
            return vertical(m == .halfPageDown || m == .pageDown, amount)
        case .nextLineStart:
            let (ls, moved) = t.lineDown(p, n)
            return moved == 0 ? nil : VimMotionTarget(pos: t.firstNonBlank(ls), kind: .linewise)
        case .prevLineStart:
            let (ls, moved) = t.lineUp(p, n)
            return moved == 0 ? nil : VimMotionTarget(pos: t.firstNonBlank(ls), kind: .linewise)
        case .currentLine:
            return VimMotionTarget(pos: t.firstNonBlank(t.lineDown(p, n - 1).start), kind: .linewise)
        case .wordForward(let big):
            if op == .change && t.charClass(p, big: big) != 0 {
                // `cw` is `ce`, but stays on a word's last character.
                var q = p
                for k in 0..<n {
                    let next = t.next(q)
                    let atEnd = next >= len || t.charClass(next, big: big) != t.charClass(q, big: big)
                    if k == 0 && atEnd { continue }
                    q = t.wordEnd(q, big: big)
                }
                return VimMotionTarget(pos: q, kind: .inclusive)
            }
            var q = p
            var start = p
            for _ in 0..<n {
                start = q
                q = t.wordForward(q, big: big)
                if q >= len { break }
            }
            if op != nil {
                // `dw` on a line's last word stops at the line's end.
                let le = t.lineEnd(start)
                if le < q && le > start { q = le }
            }
            return q == p ? nil : VimMotionTarget(pos: q, kind: .exclusive)
        case .wordEnd(let big):
            var q = p
            for _ in 0..<n { q = t.wordEnd(q, big: big) }
            return q == p ? nil : VimMotionTarget(pos: q, kind: .inclusive)
        case .wordBack(let big):
            var q = p
            for _ in 0..<n { q = t.wordBack(q, big: big) }
            return q == p ? nil : VimMotionTarget(pos: q, kind: .exclusive)
        case .wordEndBack(let big):
            var q = p
            for _ in 0..<n { q = t.wordEndBack(q, big: big) }
            return q == p ? nil : VimMotionTarget(pos: q, kind: .inclusive)
        case .lineStart:
            return VimMotionTarget(pos: t.lineStart(p), kind: .exclusive)
        case .firstNonBlank:
            return VimMotionTarget(pos: t.firstNonBlank(p), kind: .exclusive)
        case .lineEnd:
            return VimMotionTarget(pos: t.lineEnd(t.lineDown(p, n - 1).start), kind: .exclusive)
        case .lastNonBlank:
            let ls = t.lineDown(p, n - 1).start
            var q = t.lineEnd(ls)
            while q > ls && t.isBlank(q - 1) { q -= 1 }
            return VimMotionTarget(pos: q > ls ? t.prev(q) : ls, kind: .inclusive)
        case .fileStart:
            let ls = count.map { t.lineStart(number: $0) } ?? 0
            return VimMotionTarget(pos: t.firstNonBlank(ls), kind: .linewise, jump: true)
        case .fileEnd:
            let ls = count.map { t.lineStart(number: $0) } ?? t.lineStart(len)
            return VimMotionTarget(pos: t.firstNonBlank(ls), kind: .linewise, jump: true)
        case .find(let c, let forward, let till):
            lastFind = (c, forward, till)
            return find(c, forward: forward, till: till, count: n, from: p, isRepeat: false, t)
        case .repeatFind(let reverse):
            guard let last = lastFind else { return nil }
            return find(last.char, forward: last.forward != reverse, till: last.till, count: n, from: p, isRepeat: true, t)
        case .matchPair:
            let le = t.lineEnd(p)
            var q = p
            while q < le && !Self.bracketUnits.contains(t[q]) { q += 1 }
            guard q < le, let match = t.match(q) else { return nil }
            return VimMotionTarget(pos: match, kind: .inclusive, jump: true)
        case .paragraphForward:
            var ls = t.lineStart(p)
            for _ in 0..<n {
                while ls < len && t.lineIsEmpty(ls) {
                    let le = t.lineEnd(ls)
                    if le >= len { break }
                    ls = le + 1
                }
                while true {
                    let le = t.lineEnd(ls)
                    if le >= len {
                        ls = len
                        break
                    }
                    ls = le + 1
                    if t.lineIsEmpty(ls) { break }
                }
            }
            return VimMotionTarget(pos: ls, kind: .exclusive, jump: true)
        case .paragraphBack:
            var ls = t.lineStart(p)
            for _ in 0..<n {
                while ls > 0 && t.lineIsEmpty(ls) { ls = t.lineStart(ls - 1) }
                while ls > 0 {
                    ls = t.lineStart(ls - 1)
                    if t.lineIsEmpty(ls) { break }
                }
            }
            return VimMotionTarget(pos: ls, kind: .exclusive, jump: true)
        case .screenTop, .screenMiddle, .screenBottom:
            let visible = buffer.visibleCharacterRange
            let top = t.lineStart(min(visible.location, len))
            let bottom = t.lineStart(max(visible.location, min(NSMaxRange(visible), len) - 1))
            var ls: Int
            switch m {
            case .screenTop:
                ls = top
                for _ in 1..<n where ls < bottom { ls = t.lineEnd(ls) + 1 }
            case .screenBottom:
                ls = bottom
                for _ in 1..<n where ls > top { ls = t.lineStart(ls - 1) }
            default:
                var lines = 0
                var i = top
                while i < bottom {
                    i = t.lineEnd(i) + 1
                    lines += 1
                }
                ls = t.lineDown(top, lines / 2).start
            }
            return VimMotionTarget(pos: t.firstNonBlank(ls), kind: .linewise, jump: true)
        case .searchNext(let reverse):
            guard let last = lastSearch else {
                message = "No previous search"
                return nil
            }
            guard let q = search(last.pattern, caseSensitive: last.caseSensitive, forward: last.forward != reverse, from: p, count: n, t) else { return nil }
            return VimMotionTarget(pos: q, kind: .exclusive, jump: true)
        case .searchWord(let forward):
            let ls = t.lineStart(p)
            let le = t.lineEnd(p)
            var i = p
            while i < le && t.charClass(i, big: false) != 2 { i = t.next(i) }
            guard i < le else { return nil }
            var s = i
            while s > ls && t.charClass(t.prev(s), big: false) == 2 { s = t.prev(s) }
            var e = i
            while e < le && t.charClass(e, big: false) == 2 { e = t.next(e) }
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: t.substring(s, e)) + "\\b"
            lastSearch = (pattern, forward, true)
            guard let q = search(pattern, caseSensitive: true, forward: forward, from: s, count: n, t) else { return nil }
            return VimMotionTarget(pos: q, kind: .exclusive, jump: true)
        case .mark(let c, let linewise):
            let stored: Int?
            switch c {
            case "`", "'": stored = lastJump
            case "<": stored = lastVisual.map { min($0.anchor, $0.cursor) }
            case ">": stored = lastVisual.map { max($0.anchor, $0.cursor) }
            default: stored = marks[c]
            }
            guard let stored else {
                message = "Mark not set"
                return nil
            }
            let q = min(stored, len)
            return linewise
                ? VimMotionTarget(pos: t.firstNonBlank(q), kind: .linewise, jump: true)
                : VimMotionTarget(pos: q, kind: .exclusive, jump: true)
        }
    }

    static let bracketUnits: Set<unichar> = [40, 41, 91, 93, 123, 125]

    func find(_ c: String, forward: Bool, till: Bool, count n: Int, from p: Int, isRepeat: Bool, _ t: VimText) -> VimMotionTarget? {
        let ls = t.lineStart(p)
        let le = t.lineEnd(p)
        let unit: unichar? = c.utf16.count == 1 ? c.utf16.first : nil
        func matches(_ i: Int) -> Bool {
            if let unit { return t[i] == unit && t.next(i) == i + 1 }
            return t.character(at: i) == c
        }
        var q = p
        for k in 0..<n {
            if forward {
                var i = t.next(q)
                // `;` after `t` would find the character it stopped before.
                if till && isRepeat && k == 0 && i < le && matches(i) { i = t.next(i) }
                while i < le && !matches(i) { i = t.next(i) }
                guard i < le else { return nil }
                q = i
            } else {
                var i = q
                if till && isRepeat && k == 0 && i > ls && matches(t.prev(i)) { i = t.prev(i) }
                repeat {
                    if i <= ls { return nil }
                    i = t.prev(i)
                } while !matches(i)
                q = i
            }
        }
        if till { q = forward ? t.prev(q) : t.next(q) }
        return VimMotionTarget(pos: q, kind: forward ? .inclusive : .exclusive)
    }

    // MARK: Text objects

    func textObject(_ object: VimTextObject, at p: Int, count: Int?, op: VimOperator?, _ t: VimText) -> VimRange? {
        let n = max(1, count ?? 1)
        switch object {
        case .word(let big, let around):
            return wordObject(at: p, big: big, around: around, count: n, t)
        case .quote(let q, let around):
            return quoteObject(at: p, quote: unichar(q.asciiValue!), around: around, t)
        case .pair(let open, let close, let around):
            return pairObject(at: p, open: unichar(open.asciiValue!), close: unichar(close.asciiValue!), around: around, count: n, op: op, t)
        case .paragraph(let around):
            return paragraphObject(at: p, around: around, count: n, t)
        }
    }

    func wordObject(at p: Int, big: Bool, around: Bool, count n: Int, _ t: VimText) -> VimRange {
        let ls = t.lineStart(p)
        let le = t.lineEnd(p)
        if ls == le { return .chars(NSRange(location: ls, length: 0)) }
        let p = min(p, t.prev(le))
        let c = t.charClass(p, big: big)
        var s = p
        var e = t.next(p)
        while s > ls && t.charClass(t.prev(s), big: big) == c { s = t.prev(s) }
        while e < le && t.charClass(e, big: big) == c { e = t.next(e) }
        func extendRun() {
            guard e < le else { return }
            let run = t.charClass(e, big: big)
            while e < le && t.charClass(e, big: big) == run { e = t.next(e) }
        }
        func extendBlanks() -> Bool {
            guard e < le, t.charClass(e, big: big) == 0 else { return false }
            while e < le && t.charClass(e, big: big) == 0 { e = t.next(e) }
            return true
        }
        if !around {
            for _ in 1..<n { extendRun() }
        } else if c == 0 {
            // On blanks: the blanks and the word after them.
            for k in 0..<n {
                if k > 0 { _ = extendBlanks() }
                extendRun()
            }
        } else {
            var trailing = false
            for k in 0..<n {
                if k > 0 { extendRun() }
                trailing = extendBlanks() || trailing
            }
            if !trailing {
                var b = s
                while b > ls && t.charClass(t.prev(b), big: big) == 0 { b = t.prev(b) }
                if b > ls || s == ls { s = b }
            }
        }
        return .chars(NSRange(location: s, length: e - s))
    }

    func quoteObject(at p: Int, quote q: unichar, around: Bool, _ t: VimText) -> VimRange? {
        let ls = t.lineStart(p)
        let le = t.lineEnd(p)
        var quotes: [Int] = []
        var i = ls
        var escaped = false
        while i < le {
            let u = t[i]
            if escaped {
                escaped = false
            } else if u == 92 {
                escaped = true
            } else if u == q {
                quotes.append(i)
            }
            i += 1
        }
        var pair: (Int, Int)?
        var k = 0
        while k + 1 < quotes.count {
            if quotes[k] <= p && p <= quotes[k + 1] {
                pair = (quotes[k], quotes[k + 1])
                break
            }
            k += 2
        }
        if pair == nil {
            k = 0
            while k + 1 < quotes.count {
                if quotes[k] > p {
                    pair = (quotes[k], quotes[k + 1])
                    break
                }
                k += 2
            }
        }
        guard let (open, close) = pair else { return nil }
        if !around { return .chars(NSRange(location: open + 1, length: close - open - 1)) }
        var s = open
        var e = close + 1
        if e < le && t.isBlank(e) {
            while e < le && t.isBlank(e) { e += 1 }
        } else {
            var b = s
            while b > ls && t.isBlank(b - 1) { b -= 1 }
            if b > ls { s = b }
        }
        return .chars(NSRange(location: s, length: e - s))
    }

    func pairObject(at p: Int, open: unichar, close: unichar, around: Bool, count n: Int, op: VimOperator?, _ t: VimText) -> VimRange? {
        let len = t.length
        var o: Int?
        if p < len && t[p] == open {
            o = p
        } else {
            o = t.unmatchedOpen(before: p, open, close)
        }
        if o == nil {
            // Not inside one: the next pair on the line, as Zed does.
            let le = t.lineEnd(p)
            var i = p
            while i < le && t[i] != open { i += 1 }
            if i < le { o = i }
        }
        guard var o, var c = t.matchForward(from: o + 1, open, close) else { return nil }
        for _ in 1..<n {
            guard let outer = t.unmatchedOpen(before: o, open, close), let outerClose = t.matchForward(from: outer + 1, open, close) else { break }
            o = outer
            c = outerClose
        }
        if around { return .chars(NSRange(location: o, length: c + 1 - o)) }
        var s = o + 1
        var e = c
        if t.lineStart(o) != t.lineStart(c) {
            // A block on its own lines: its lines, not the brackets' newlines.
            if s < e && t[s] == VimText.newline { s += 1 }
            let cls = t.lineStart(c)
            var i = cls
            while i < c && t.isBlank(i) { i += 1 }
            if i == c && cls >= s {
                e = cls
                if op == .change && e > s { e -= 1 }
            }
        }
        return .chars(NSRange(location: s, length: max(0, e - s)))
    }

    func paragraphObject(at p: Int, around: Bool, count n: Int, _ t: VimText) -> VimRange {
        let len = t.length
        let ls0 = t.lineStart(p)
        let blank = t.lineIsBlank(ls0)
        func nextLine(_ l: Int) -> Int? {
            let le = t.lineEnd(l)
            return le < len ? le + 1 : nil
        }
        func extend(_ last: inout Int, _ b: Bool) {
            while let nl = nextLine(last), t.lineIsBlank(nl) == b { last = nl }
        }
        var first = ls0
        while first > 0 {
            let pl = t.lineStart(first - 1)
            if t.lineIsBlank(pl) != blank { break }
            first = pl
        }
        var last = ls0
        extend(&last, blank)
        for _ in 1..<n {
            guard let nl = nextLine(last) else { break }
            last = nl
            extend(&last, t.lineIsBlank(nl))
        }
        if around {
            if let nl = nextLine(last) {
                last = nl
                extend(&last, t.lineIsBlank(nl))
            } else if !blank {
                while first > 0 {
                    let pl = t.lineStart(first - 1)
                    if !t.lineIsBlank(pl) { break }
                    first = pl
                }
            }
        }
        return .lines(first, last)
    }
}
