import Foundation

/// The values a plan marks sensitive somewhere, looked for everywhere else
/// in it (analysis 5.6): a sensitive variable copied into an attribute
/// nothing marks (`terraform_data`'s `output`) is still that value. A leaf
/// equal to one — a string of any length, a number by its text — is masked
/// whole; one at least `TerraformPlan.minimumSecret` long is also hunted
/// inside other strings and redacted there.
///
/// The hunt is a pass over a string's bytes per distinct length of value,
/// whatever the number of values (2,000 `random_password` results in a
/// 15 MB plan): a rolling hash of each window of that length, a bit filter,
/// then the values of that hash compared byte for byte. A `contains` per
/// value per string was 512 scans of every string, and values sharing a
/// prefix (`acme-pw-…`) defeat any index by first bytes. Pure.
struct TerraformSensitiveValues: Sendable {
    static let none = TerraformSensitiveValues([])

    /// Every value, whole.
    let exact: Set<String>
    /// The longest value's bytes: a longer leaf is equal to none.
    private let longest: Int
    /// The values long enough to hunt for, by length, longest first.
    private let groups: [Group]
    private let redaction = Array(TerraformPlan.redaction.utf8)

    private struct Group: Sendable {
        var length: Int
        /// `base` to the power `length - 1`: what leaves the window as it rolls.
        var top: UInt64
        /// The values of this length, by their hash.
        var values: [UInt64: [[UInt8]]]
        /// One bit per low 16 bits of a value's hash: most windows stop here.
        var filter: [UInt64]
    }

    private static let base: UInt64 = 1_099_511_628_211

    init(_ values: Set<String>) {
        exact = values
        longest = values.map(\.utf8.count).max() ?? 0
        var byLength: [Int: [UInt64: [[UInt8]]]] = [:]
        for value in values where value.utf8.count >= TerraformPlan.minimumSecret {
            let bytes = Array(value.utf8)
            byLength[bytes.count, default: [:]][Self.hash(bytes[...]), default: []].append(bytes)
        }
        groups = byLength.keys.sorted(by: >).map { length in
            let values = byLength[length] ?? [:]
            var filter = [UInt64](repeating: 0, count: 1 << 10)
            for hash in values.keys { filter[Int(hash & 0xFFFF) >> 6] |= 1 << (hash & 63) }
            var top: UInt64 = 1
            for _ in 1..<length { top = top &* Self.base }
            return Group(length: length, top: top, values: values, filter: filter)
        }
    }

    var isEmpty: Bool { exact.isEmpty }

    /// Whether `leaf` is one of the values, or holds one.
    func isSecret(_ leaf: String) -> Bool {
        guard !exact.isEmpty else { return false }
        if leaf.utf8.count <= longest, exact.contains(leaf) { return true }
        return contains(leaf)
    }

    /// Whether `text` holds one of the values long enough to hunt for.
    func contains(_ text: String) -> Bool {
        guard !groups.isEmpty else { return false }
        return Self.bytes(of: text) { bytes in groups.contains { !matches(of: $0, in: bytes, first: true).isEmpty } }
    }

    /// `text` with each value it holds replaced by ••••••, the longest
    /// first where two overlap.
    func redact(_ text: String) -> String {
        guard !groups.isEmpty else { return text }
        return Self.bytes(of: text) { bytes -> String in
            var found: [(start: Int, length: Int)] = []
            for group in groups { found += matches(of: group, in: bytes, first: false).map { ($0, group.length) } }
            guard !found.isEmpty else { return text }
            found.sort { $0.start != $1.start ? $0.start < $1.start : $0.length > $1.length }
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var at = 0
            for match in found where match.start >= at {
                out.append(contentsOf: bytes[at..<match.start])
                out.append(contentsOf: redaction)
                at = match.start + match.length
            }
            out.append(contentsOf: bytes[at...])
            return String(decoding: out, as: UTF8.self)
        }
    }

    /// Where `group`'s values start in `bytes` (the first only, with `first`).
    private func matches(of group: Group, in bytes: UnsafeBufferPointer<UInt8>, first: Bool) -> [Int] {
        let length = group.length
        guard bytes.count >= length else { return [] }
        var starts: [Int] = []
        var hash: UInt64 = 0
        for index in 0..<length { hash = hash &* Self.base &+ UInt64(bytes[index]) }
        var start = 0
        while true {
            if group.filter[Int(hash & 0xFFFF) >> 6] & (1 << (hash & 63)) != 0, let candidates = group.values[hash] {
                let window = UnsafeBufferPointer(rebasing: bytes[start..<(start + length)])
                if candidates.contains(where: { $0.elementsEqual(window) }) {
                    starts.append(start)
                    if first { return starts }
                }
            }
            let next = start + length
            guard next < bytes.count else { break }
            hash = (hash &- UInt64(bytes[start]) &* group.top) &* Self.base &+ UInt64(bytes[next])
            start += 1
        }
        return starts
    }

    private static func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var hash: UInt64 = 0
        for byte in bytes { hash = hash &* base &+ UInt64(byte) }
        return hash
    }

    /// `text`'s UTF-8, contiguous: a bridged string is copied once.
    private static func bytes<T>(of text: String, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
        let copy = Array(text.utf8)
        return copy.withUnsafeBufferPointer(body)
    }
}
