import Foundation

/// Ranking for the editor's completions and pickers, as fzf and Zed rank:
/// the query's characters in order anywhere in the candidate, ignoring case,
/// scored by where they land — at the start, after `_ - . /` or a space, on a
/// camelCase hump, in runs — less what lies between. The best alignment, not
/// the first: "gtl" takes goToLine's g-T-L, not the g-t of "got". (The
/// palette's `FuzzyMatch` is the greedy one, kept for its ranking.)
enum CompletionMatch {
    static let scoreMatch = 16
    static let gapStart = -3
    static let gapExtension = -1
    /// At the start, or after whitespace.
    static let bonusBoundaryWhite = 10
    /// After a path separator.
    static let bonusBoundaryDelimiter = 9
    /// After other punctuation (`_ - . :`), or on punctuation itself.
    static let bonusBoundary = 8
    /// A camelCase hump, or a digit after a letter.
    static let bonusCamel = 7
    /// Each character of a run gets at least this.
    static let bonusConsecutive = 4
    /// The query's first character counts its bonus twice: where a match
    /// starts says most about it.
    static let firstCharMultiplier = 2
    /// Typed in the candidate's case.
    static let bonusCase = 1
    /// Longer candidates rank lower, a point a character, by up to this much.
    static let maxLengthPenalty = 10

    /// Past these (characters), the alignment's cost isn't worth it: nil.
    static let maxCandidateLength = 1024
    static let maxQueryLength = 128

    /// The score (higher is better) and the UTF-16 offsets in `candidate` of
    /// the characters matched; nil: not a match. An empty query matches
    /// everything at 0.
    static func score(candidate: String, query: String) -> (score: Int, matched: [Int])? {
        let q = Array(query.unicodeScalars)
        guard !q.isEmpty else { return (0, []) }
        let c = Array(candidate.unicodeScalars)
        let n = q.count
        let m = c.count
        guard n <= m, m <= maxCandidateLength, n <= maxQueryLength else { return nil }
        let qLower = q.map(lower)
        let cLower = c.map(lower)
        // Not a subsequence: no alignment to look for.
        var k = 0
        for scalar in cLower where k < n && scalar == qLower[k] { k += 1 }
        guard k == n else { return nil }

        var bonus = [Int](repeating: 0, count: m)
        var previous = CharClass.white
        for j in 0..<m {
            let current = CharClass(c[j])
            bonus[j] = Self.bonus(previous, current)
            previous = current
        }

        // match[i*m+j]: best score with query[0...i] matched, query[i] at j.
        // gap[i*m+j]: best with query[0...i] matched before j and j skipped
        // (gapFrom: where query[i] was). chunk: the bonus a run started with.
        let none = Int.min / 2
        var match = [Int](repeating: none, count: n * m)
        var chunk = [Int](repeating: 0, count: n * m)
        var fromRun = [Bool](repeating: false, count: n * m)
        var gap = [Int](repeating: none, count: n * m)
        var gapFrom = [Int](repeating: -1, count: n * m)
        for i in 0..<n {
            let row = i * m
            let up = (i - 1) * m
            for j in 0..<m {
                if j > 0 {
                    let opened = match[row + j - 1] > none ? match[row + j - 1] + gapStart : none
                    let extended = gap[row + j - 1] > none ? gap[row + j - 1] + gapExtension : none
                    if opened >= extended, opened > none {
                        gap[row + j] = opened
                        gapFrom[row + j] = j - 1
                    } else if extended > none {
                        gap[row + j] = extended
                        gapFrom[row + j] = gapFrom[row + j - 1]
                    }
                }
                guard j >= i, cLower[j] == qLower[i] else { continue }
                let caseBonus = c[j] == q[i] ? bonusCase : 0
                if i == 0 {
                    match[row + j] = scoreMatch + bonus[j] * firstCharMultiplier + caseBonus
                    chunk[row + j] = bonus[j]
                    continue
                }
                guard j > 0 else { continue }
                var best = none
                if match[up + j - 1] > none {
                    let runBonus = max(bonus[j], chunk[up + j - 1], bonusConsecutive)
                    best = match[up + j - 1] + scoreMatch + runBonus + caseBonus
                    chunk[row + j] = chunk[up + j - 1]
                    fromRun[row + j] = true
                }
                if gap[up + j - 1] > none {
                    let viaGap = gap[up + j - 1] + scoreMatch + bonus[j] + caseBonus
                    if viaGap > best {
                        best = viaGap
                        chunk[row + j] = bonus[j]
                        fromRun[row + j] = false
                    }
                }
                match[row + j] = best
            }
        }
        let last = (n - 1) * m
        var end = -1
        for j in 0..<m where match[last + j] > none && (end < 0 || match[last + j] > match[last + end]) { end = j }
        guard end >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: n)
        var j = end
        for i in stride(from: n - 1, through: 0, by: -1) {
            positions[i] = j
            guard i > 0 else { break }
            j = fromRun[i * m + j] ? j - 1 : gapFrom[(i - 1) * m + j - 1]
        }
        // Scalar index → UTF-16 offset.
        var offsets = [Int](repeating: 0, count: m)
        var offset = 0
        for (index, scalar) in c.enumerated() {
            offsets[index] = offset
            offset += scalar.utf16.count
        }
        let penalty = min(m - n, maxLengthPenalty)
        return (match[last + end] - penalty, positions.map { offsets[$0] })
    }

    private enum CharClass {
        case white, delimiter, nonWord, lower, upper, number

        init(_ scalar: Unicode.Scalar) {
            switch scalar {
            case " ", "\t", "\n", "\r": self = .white
            case "/", "\\": self = .delimiter
            case "0"..."9": self = .number
            case "a"..."z": self = .lower
            case "A"..."Z": self = .upper
            default:
                if scalar.isASCII {
                    self = .nonWord
                } else if scalar.properties.isUppercase {
                    self = .upper
                } else if scalar.properties.isAlphabetic {
                    self = .lower
                } else if scalar.properties.numericType != nil {
                    self = .number
                } else if scalar.properties.isWhitespace {
                    self = .white
                } else {
                    self = .nonWord
                }
            }
        }

        var isWord: Bool { self == .lower || self == .upper || self == .number }
    }

    /// fzf's bonus for a character by the one before it.
    private static func bonus(_ previous: CharClass, _ current: CharClass) -> Int {
        guard current.isWord else { return current == .white ? bonusBoundaryWhite : bonusBoundary }
        switch previous {
        case .white: return bonusBoundaryWhite
        case .delimiter: return bonusBoundaryDelimiter
        case .nonWord: return bonusBoundary
        case .lower, .upper:
            return (previous == .lower && current == .upper) || current == .number ? bonusCamel : 0
        case .number: return 0
        }
    }

    private static func lower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.isASCII {
            let v = scalar.value
            return v >= 0x41 && v <= 0x5A ? Unicode.Scalar(v + 32)! : scalar
        }
        // İ lowers to i and a combining dot: the i is what a query types.
        return scalar.properties.lowercaseMapping.unicodeScalars.first ?? scalar
    }

    // MARK: Buffer words

    /// At most this many words come back.
    static let maxWords = 5000
    /// How much text around the cursor is read for them (UTF-16).
    static let maxScanned = 1 << 20

    /// Words for completion from the buffer itself: distinct identifiers —
    /// letters (any script), digits, `_`, `$`; at least 3 characters, not
    /// starting with a digit — nearest the cursor first, the one being typed
    /// at the cursor left out. Reads at most `maxScanned` around the cursor;
    /// a word cut by that window's edge is left out too.
    static func bufferWords(in text: NSString, near cursor: Int) -> [String] {
        let length = text.length
        let cursor = max(0, min(cursor, length))
        var low = max(0, cursor - maxScanned / 2)
        let high = min(length, low + maxScanned)
        low = max(0, high - maxScanned)
        let count = high - low
        guard count > 0 else { return [] }
        var buffer = [unichar](repeating: 0, count: count)
        text.getCharacters(&buffer, range: NSRange(location: low, length: count))

        // Word ranges in the window, in order.
        var before: [Range<Int>] = []
        var after: [Range<Int>] = []
        var i = 0
        var start = -1
        var scalars = 0
        func endWord(at end: Int) {
            defer { start = -1 }
            guard start >= 0, scalars >= 3 else { return }
            guard start > 0 || low == 0, end < count || high == length else { return }
            let first = buffer[start]
            guard first < 0x30 || first > 0x39 else { return }
            let absolute = (low + start)..<(low + end)
            if absolute.upperBound < cursor {
                before.append(absolute)
            } else if absolute.lowerBound > cursor {
                after.append(absolute)
            }
        }
        while i < count {
            let unit = buffer[i]
            var scalar: Unicode.Scalar? = nil
            var width = 1
            if UTF16.isLeadSurrogate(unit), i + 1 < count, UTF16.isTrailSurrogate(buffer[i + 1]) {
                scalar = Unicode.Scalar(UInt32(0x10000 + ((Int(unit) - 0xD800) << 10) + (Int(buffer[i + 1]) - 0xDC00)))
                width = 2
            } else {
                scalar = Unicode.Scalar(unit)
            }
            let word = scalar.map { $0 == "$" || EditCommands.isWord($0) || $0.properties.isGraphemeExtend } ?? false
            if word {
                if start < 0 {
                    start = i
                    scalars = 0
                }
                scalars += 1
            } else if start >= 0 {
                endWord(at: i)
            }
            i += width
        }
        if start >= 0 { endWord(at: count) }

        // Nearest first: before the cursor walks back, after it forward.
        var words: [String] = []
        var seen = Set<String>()
        var b = before.count - 1
        var a = 0
        while words.count < maxWords, b >= 0 || a < after.count {
            let range: Range<Int>
            if a < after.count, b < 0 || after[a].lowerBound - cursor < cursor - before[b].upperBound {
                range = after[a]
                a += 1
            } else {
                range = before[b]
                b -= 1
            }
            let word = buffer.withUnsafeBufferPointer { pointer in
                String(utf16CodeUnits: pointer.baseAddress! + (range.lowerBound - low), count: range.count)
            }
            if seen.insert(word).inserted { words.append(word) }
        }
        return words
    }
}
