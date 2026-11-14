import Foundation

/// The lines of a root's Terraform files this branch added, read from git
/// itself (analysis 3.1): `git diff -U0 <merge base> -- <root>`, whatever
/// the changes pane shows — its diffs load only while it is visible, only
/// for the scope picked (uncommitted by default) and only for the first
/// files. A tfvars line committed on this branch is still "changed in this
/// branch". The parse is pure.
enum TerraformChangedLines {
    /// Bounds: a root's diff is the checkout's, of any size.
    static let maxOutput = 4 << 20
    static let maxLines = 20_000

    /// The diff's arguments: no context, every prefix said (a user's
    /// `diff.noprefix` aside), paths relative to the checkout.
    static func arguments(base: String, root: String) -> [String] {
        [
            "diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", "--relative", "--src-prefix=a/", "--dst-prefix=b/", base, "--",
            root.isEmpty ? "." : root,
        ]
    }

    /// Each Terraform file's added lines, by path in the checkout: with
    /// `-U0` a hunk's new side is only what was added (`+c,d`).
    static func parse(_ diff: String) -> [String: Set<Int>] {
        var lines: [String: Set<Int>] = [:]
        var file: String?
        var total = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("+++ ") {
                var path = String(line.dropFirst(4))
                if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
                file = path.hasPrefix("b/") ? String(path.dropFirst(2)) : nil
                if let name = file, !TerraformRootGuess.isTerraformName((name as NSString).lastPathComponent) { file = nil }
                continue
            }
            guard let current = file, line.hasPrefix("@@ "), let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) else { continue }
            let parts = plus.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = parts.first.flatMap({ Int($0) }) else { continue }
            let count = parts.count > 1 ? Int(parts[1]) ?? 0 : 1
            guard count > 0, start > 0 else { continue }
            let added = min(count, maxLines - total)
            guard added > 0 else { break }
            lines[current, default: []].formUnion(start..<(start + added))
            total += added
        }
        return lines
    }

    /// `root`'s (its path in the checkout) added lines since `base`; empty when git can't say.
    static func read(checkout: URL, root: String, base: String) async -> [String: Set<Int>] {
        guard let diff = try? await Git.run(arguments(base: base, root: root), in: checkout, outputLimit: maxOutput) else { return [:] }
        return parse(diff)
    }

    /// The union of two readings, file by file.
    static func merged(_ a: [String: Set<Int>], _ b: [String: Set<Int>]) -> [String: Set<Int>] {
        guard !b.isEmpty else { return a }
        return a.merging(b) { $0.union($1) }
    }
}
