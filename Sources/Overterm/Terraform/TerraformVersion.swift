import Foundation

/// A Terraform version and what a root asks of it (analysis 2.8, the
/// version pill): `required_version`'s constraints (`>= 1.5, < 2.0`,
/// `~> 1.9`, `= 1.9.0`, `!= 1.10.0`) and the pins a version manager reads
/// (`.terraform-version`, `.tool-versions`, `mise.toml`). Pure.
struct TerraformVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    var parts: [Int]
    /// `-alpha20260101`, `-rc1`: a pre-release sorts before its release.
    var prerelease: String?

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        let split = text.split(separator: "-", maxSplits: 1)
        guard let numbers = split.first else { return nil }
        let parts = numbers.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.map { $0! }
        prerelease = split.count > 1 ? String(split[1]) : nil
    }

    var description: String { parts.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "") }

    private func padded(_ count: Int) -> [Int] { parts + Array(repeating: 0, count: max(0, count - parts.count)) }

    static func < (a: TerraformVersion, b: TerraformVersion) -> Bool {
        let (x, y) = (a.padded(3), b.padded(3))
        if x != y { return x.lexicographicallyPrecedes(y) }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let p?, let q?): return p < q
        }
    }

    static func == (a: TerraformVersion, b: TerraformVersion) -> Bool { a.padded(3) == b.padded(3) && a.prerelease == b.prerelease }
    func hash(into hasher: inout Hasher) {
        hasher.combine(padded(3))
        hasher.combine(prerelease)
    }

    /// Whether this version satisfies every comma-separated constraint of
    /// `constraint`; nil when one can't be read (said as unknown, never a
    /// mismatch).
    func satisfies(_ constraint: String) -> Bool? {
        var all = true
        for piece in constraint.split(separator: ",") {
            let term = piece.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            var op = "="
            var rest = Substring(term)
            for candidate in ["~>", ">=", "<=", "!=", ">", "<", "="] where rest.hasPrefix(candidate) {
                op = candidate
                rest = rest.dropFirst(candidate.count)
                break
            }
            guard let wanted = TerraformVersion(String(rest)) else { return nil }
            let ok: Bool
            switch op {
            case "=": ok = self == wanted
            case "!=": ok = self != wanted
            case ">": ok = self > wanted
            case ">=": ok = self >= wanted
            case "<": ok = self < wanted
            case "<=": ok = self <= wanted
            case "~>":
                // `~> 1.9` allows 1.x from 1.9; `~> 1.9.2`, 1.9.x from 1.9.2.
                let fixed = Array(wanted.parts.dropLast())
                ok = self >= wanted && Array(padded(3).prefix(fixed.count)) == fixed
            default: return nil
            }
            if !ok { all = false }
        }
        return all
    }

    /// Whether a pin (`1.9`, `1.9.3`) names this version: equal on every
    /// part it gives. `latest`, `min-required` and the like say nothing.
    func matchesPin(_ pin: String) -> Bool? {
        guard let wanted = TerraformVersion(pin) else { return nil }
        return Array(parts.prefix(wanted.parts.count)) == wanted.parts && (wanted.prerelease == nil || wanted.prerelease == prerelease)
    }
}

/// Where a root's version is asked for, and what each says.
struct TerraformVersionPins: Equatable, Sendable {
    /// `required_version`.
    var required: String?
    /// The pin a version manager reads, and its file: `1.9.0 (.terraform-version)`.
    var pin: String?
    var pinFile: String?

    /// `.terraform-version`'s first line.
    static func terraformVersionFile(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `.tool-versions`' `terraform 1.9.0` line.
    static func toolVersions(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            if words.count >= 2, words[0] == "terraform" { return String(words[1]) }
        }
        return nil
    }

    /// `mise.toml`'s `terraform = "1.9"` under `[tools]`.
    static func miseToml(_ text: String) -> String? {
        var inTools = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inTools = line == "[tools]"
                continue
            }
            guard inTools, line.hasPrefix("terraform") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "terraform" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// What the pill says against `version`: nil when nothing is asked or
    /// all agree; else "1.17.1 ≠ required ~> 1.9".
    func mismatch(_ version: TerraformVersion?) -> String? {
        guard let version else { return nil }
        if let required, version.satisfies(required) == false { return "\(version) ≠ required \(required)" }
        if let pin, version.matchesPin(pin) == false { return "\(version) ≠ \(pin) (\(pinFile ?? "pinned"))" }
        return nil
    }
}
