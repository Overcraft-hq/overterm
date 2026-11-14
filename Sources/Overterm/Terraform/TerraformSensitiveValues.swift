import CryptoKit
import Darwin
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

/// A plan's sensitive values kept for its apply (analysis 5.6): the
/// stream prints values in clear where Terraform's marks don't reach —
/// `provision_progress.output`, an `apply_errored` diagnostic's detail — and
/// a provisioner echoing a sensitive variable is that value. Every string
/// of the apply's stream goes through `scrub`: a whole line equal to one,
/// or one inside it, becomes ••••••, then `Secrets`' rules. The values in
/// memory only, beside the record's environment; the apply's run folder
/// keeps them as salted digests (`TerraformHashedValues`) for an apply
/// followed again after a crash. It never describes, reflects or prints a
/// value, so a model holding it says nothing of them.
final class TerraformValueMask: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let none = TerraformValueMask(.none)

    private let values: TerraformSensitiveValues
    private let hashed: TerraformHashedValues?

    init(_ values: TerraformSensitiveValues) {
        self.values = values
        hashed = nil
    }

    /// An apply's found again: its run folder's digests.
    init(hashed: TerraformHashedValues) {
        values = .none
        self.hashed = hashed
    }

    var isEmpty: Bool { values.isEmpty && (hashed?.exact.isEmpty ?? true) }

    /// `text` masked by the plan's values, then scrubbed.
    func scrub(_ text: String) -> String {
        if let hashed { return TerraformPlan.scrub(hashed.redact(text)) }
        guard !values.isEmpty else { return TerraformPlan.scrub(text) }
        if values.exact.contains(text) || values.exact.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return TerraformPlan.redaction }
        return TerraformPlan.scrub(values.redact(text))
    }

    /// What the run folder keeps: digests, salted, never a value.
    func digests() -> TerraformHashedValues { hashed ?? TerraformHashedValues(values.exact) }

    /// Kept in `folder` (0600, a new file): the apply's, removed with it.
    func write(to folder: URL) throws {
        guard !isEmpty else { return }
        let data = try JSONEncoder().encode(digests())
        let fd = open(folder.appendingPathComponent(TerraformHashedValues.file).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw POSIXError(.EIO) }
    }

    /// An apply's run folder's, or `none`.
    static func read(_ folder: URL) -> TerraformValueMask {
        let url = folder.appendingPathComponent(TerraformHashedValues.file)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size < 64 << 20,
            let data = try? Data(contentsOf: url), let hashed = try? JSONDecoder().decode(TerraformHashedValues.self, from: data)
        else { return .none }
        return TerraformValueMask(hashed: hashed)
    }

    var description: String { "TerraformValueMask(\(hashed?.exact.count ?? values.exact.count) values)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

/// A plan's sensitive values as salted SHA-256 digests (4.7, 5.6): what a
/// detached apply's run folder keeps, so an apply followed again after
/// Overterm crashed is masked as it was — never a value on disk. A whole
/// string equal to one is masked; values at least `minimumSecret` long are
/// hunted inside strings, window by window, by their lengths (the longest
/// `maxLengths`). Pure.
struct TerraformHashedValues: Codable, Equatable, Sendable {
    static let file = "mask.json"
    static let maxLengths = 32
    /// Hunted inside a string's first bytes only; the rest is cut.
    static let maxHunted = 16 << 10

    var salt: Data
    var exact: Set<Data>
    /// The hunted values' digests by their length in bytes.
    var byLength: [Int: Set<Data>]

    init(_ values: Set<String>, salt: Data? = nil) {
        let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        self.salt = salt
        func digest(_ bytes: [UInt8]) -> Data { Self.digest(bytes[...], salt: salt) }
        exact = Set(values.map { digest(Array($0.utf8)) })
        var byLength: [Int: Set<Data>] = [:]
        for value in values where value.utf8.count >= TerraformPlan.minimumSecret {
            byLength[value.utf8.count, default: []].insert(digest(Array(value.utf8)))
        }
        let kept = byLength.keys.sorted(by: >).prefix(Self.maxLengths)
        self.byLength = byLength.filter { kept.contains($0.key) }
    }

    static func digest(_ bytes: ArraySlice<UInt8>, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        bytes.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return Data(hasher.finalize())
    }

    /// `text` with each value found replaced by ••••••.
    func redact(_ text: String) -> String {
        let all = Array(text.utf8)
        if exact.contains(Self.digest(all[...], salt: salt)) { return TerraformPlan.redaction }
        let trimmed = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        if trimmed.count != all.count, exact.contains(Self.digest(trimmed[...], salt: salt)) { return TerraformPlan.redaction }
        guard !byLength.isEmpty else { return text }
        let bytes = all.prefix(Self.maxHunted)
        var found: [(start: Int, length: Int)] = []
        for length in byLength.keys.sorted(by: >) where length <= bytes.count {
            guard let digests = byLength[length] else { continue }
            var start = 0
            while start + length <= bytes.count {
                if digests.contains(Self.digest(bytes[start..<(start + length)], salt: salt)) {
                    found.append((start, length))
                    start += length
                } else {
                    start += 1
                }
            }
        }
        let cut = all.count > bytes.count
        guard !found.isEmpty || cut else { return text }
        found.sort { $0.start != $1.start ? $0.start < $1.start : $0.length > $1.length }
        var out: [UInt8] = []
        var at = 0
        for match in found where match.start >= at {
            out.append(contentsOf: bytes[at..<match.start])
            out.append(contentsOf: Array(TerraformPlan.redaction.utf8))
            at = match.start + match.length
        }
        out.append(contentsOf: bytes[at...])
        return String(decoding: out, as: UTF8.self) + (cut ? " (cut: too long to check)" : "")
    }
}
