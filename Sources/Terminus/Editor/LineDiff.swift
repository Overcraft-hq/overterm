import Foundation

/// A mark in the editor's git gutter.
struct GutterHunk: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case added, modified, deleted }
    let kind: Kind
    /// 0-based lines of the current text. `deleted`: empty, at the line the
    /// removed ones stood before — the mark goes on its top edge (the
    /// bottom of the line above); it may be the line count, after the end.
    let lines: Range<Int>
}

/// The editor's git gutter, as Zed and VS Code draw it: which lines of the
/// buffer are new, changed, or have lines removed before them against the
/// base (the index or HEAD). Myers' diff over line hashes, in linear space
/// (the middle-snake recursion), after trimming what the two share at
/// either end — a few edits to a 50 000-line file cost hashing it and not
/// much more (LineDiffTests times one). Lines are compared by a 64-bit hash
/// of their bytes: two different lines colliding is not worth a second
/// compare.
enum LineDiff {
    /// Past this many differences in a stretch, the stretch is marked
    /// modified whole rather than diffed: Myers is O((N+M)·D), and a file
    /// rewritten wholesale has nothing finer worth showing.
    static let maxEditDistance = 5000

    static func hunks(base: String, current: String) -> [GutterHunk] {
        let a = lineHashes(base)
        let b = lineHashes(current)
        var differ = Differ(a: a, b: b)
        differ.diff(aLow: 0, aHigh: a.count, bLow: 0, bHigh: b.count)
        return differ.blocks.map { block in
            let lines = block.bLow..<block.bHigh
            if block.aLow == block.aHigh { return GutterHunk(kind: .added, lines: lines) }
            if block.bLow == block.bHigh { return GutterHunk(kind: .deleted, lines: lines) }
            return GutterHunk(kind: .modified, lines: lines)
        }
    }

    /// FNV-1a of each line's bytes, its newline left out; a trailing newline
    /// ends the last line rather than starting an empty one.
    static func lineHashes(_ text: String) -> [UInt64] {
        var text = text
        return text.withUTF8 { bytes in
            var hashes: [UInt64] = []
            hashes.reserveCapacity(bytes.count / 32)
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            var empty = true
            for byte in bytes {
                if byte == 0x0A {
                    hashes.append(hash)
                    hash = 0xcbf2_9ce4_8422_2325
                    empty = true
                } else {
                    hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
                    empty = false
                }
            }
            if !empty { hashes.append(hash) }
            return hashes
        }
    }

    /// A changed stretch: lines aLow..<aHigh of the base became bLow..<bHigh.
    struct Block: Equatable {
        var aLow: Int, aHigh: Int, bLow: Int, bHigh: Int
    }

    private struct Differ {
        let a: [UInt64]
        let b: [UInt64]
        var blocks: [Block] = []

        init(a: [UInt64], b: [UInt64]) {
            self.a = a
            self.b = b
        }

        /// Stretches are found in order: one that starts where the last ended
        /// joins it (a replacement split by the recursion is one hunk).
        mutating func emit(_ block: Block) {
            if var last = blocks.last, last.aHigh == block.aLow, last.bHigh == block.bLow {
                last.aHigh = block.aHigh
                last.bHigh = block.bHigh
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(block)
            }
        }

        mutating func diff(aLow: Int, aHigh: Int, bLow: Int, bHigh: Int) {
            var aLow = aLow
            var bLow = bLow
            var aHigh = aHigh
            var bHigh = bHigh
            while aLow < aHigh, bLow < bHigh, a[aLow] == b[bLow] {
                aLow += 1
                bLow += 1
            }
            while aLow < aHigh, bLow < bHigh, a[aHigh - 1] == b[bHigh - 1] {
                aHigh -= 1
                bHigh -= 1
            }
            if aLow == aHigh, bLow == bHigh { return }
            if aLow == aHigh || bLow == bHigh {
                emit(Block(aLow: aLow, aHigh: aHigh, bLow: bLow, bHigh: bHigh))
                return
            }
            guard let split = middleSnake(aLow: aLow, aHigh: aHigh, bLow: bLow, bHigh: bHigh) else {
                emit(Block(aLow: aLow, aHigh: aHigh, bLow: bLow, bHigh: bHigh))
                return
            }
            let (x, y) = split
            diff(aLow: aLow, aHigh: x, bLow: bLow, bHigh: y)
            diff(aLow: x, aHigh: aHigh, bLow: y, bHigh: bHigh)
        }

        /// Where the forward and backward searches meet (Myers 1986, §4b, as
        /// diff-match-patch's bisect writes it), as a split point in the base
        /// and the current text; nil past `maxEditDistance` or with nothing
        /// in common. Both ends differ: the caller trimmed what they share.
        func middleSnake(aLow: Int, aHigh: Int, bLow: Int, bHigh: Int) -> (Int, Int)? {
            let n = aHigh - aLow
            let m = bHigh - bLow
            let maxD = min((n + m + 1) / 2, LineDiff.maxEditDistance / 2)
            let offset = maxD + 1
            let size = 2 * maxD + 3
            var forward = [Int](repeating: -1, count: size)
            var backward = [Int](repeating: -1, count: size)
            forward[offset + 1] = 0
            backward[offset + 1] = 0
            let delta = n - m
            // With an odd delta the paths meet on a forward step, else a backward one.
            let front = delta % 2 != 0
            var k1Start = 0
            var k1End = 0
            var k2Start = 0
            var k2End = 0
            for d in 0..<maxD {
                var k1 = -d + k1Start
                while k1 <= d - k1End {
                    let i = offset + k1
                    var x1 = (k1 == -d || (k1 != d && forward[i - 1] < forward[i + 1])) ? forward[i + 1] : forward[i - 1] + 1
                    var y1 = x1 - k1
                    while x1 < n, y1 < m, a[aLow + x1] == b[bLow + y1] {
                        x1 += 1
                        y1 += 1
                    }
                    forward[i] = x1
                    if x1 > n {
                        k1End += 2
                    } else if y1 > m {
                        k1Start += 2
                    } else if front {
                        let j = offset + delta - k1
                        if j >= 0, j < size, backward[j] != -1, x1 >= n - backward[j] { return (aLow + x1, bLow + y1) }
                    }
                    k1 += 2
                }
                var k2 = -d + k2Start
                while k2 <= d - k2End {
                    let i = offset + k2
                    var x2 = (k2 == -d || (k2 != d && backward[i - 1] < backward[i + 1])) ? backward[i + 1] : backward[i - 1] + 1
                    var y2 = x2 - k2
                    while x2 < n, y2 < m, a[aHigh - 1 - x2] == b[bHigh - 1 - y2] {
                        x2 += 1
                        y2 += 1
                    }
                    backward[i] = x2
                    if x2 > n {
                        k2End += 2
                    } else if y2 > m {
                        k2Start += 2
                    } else if !front {
                        let j = offset + delta - k2
                        if j >= 0, j < size, forward[j] != -1 {
                            let x1 = forward[j]
                            let y1 = offset + x1 - j
                            if x1 >= n - x2 { return (aLow + x1, bLow + y1) }
                        }
                    }
                    k2 += 2
                }
            }
            return nil
        }
    }
}
