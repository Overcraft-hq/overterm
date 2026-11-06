import Foundation

// MARK: What is deployed, compared with the checkout (docs/design/kubernetes/analysis.md, 3.2)

/// Where a deployed commit was read, in the design's order of trust.
enum KubeCommitSource: Int, Comparable, Sendable, Equatable {
    /// The image's `org.opencontainers.image.revision` label or annotation,
    /// read through `docker buildx imagetools` only when asked.
    case revisionLabel = 1
    /// A tag shaped like a commit SHA, full or short: shown at once.
    case tag = 2
    /// A Helm release's chart `appVersion`, when it is SHA-shaped.
    case appVersion = 3

    static func < (lhs: KubeCommitSource, rhs: KubeCommitSource) -> Bool { lhs.rawValue < rhs.rawValue }

    var said: String {
        switch self {
        case .revisionLabel: "the image's revision label"
        case .tag: "the image's tag"
        case .appVersion: "the chart's appVersion"
        }
    }
}

/// A commit one source gave, before the checkout is asked about it.
struct KubeCommitCandidate: Equatable, Sendable {
    var sha: String
    var source: KubeCommitSource
    /// The image it came from (nil for an appVersion).
    var image: String?
}

/// The checkout's answer about a deployed commit. Pure words.
enum KubeDeployedAnswer: Equatable, Sendable {
    struct Found: Equatable, Sendable {
        /// The commit, as git has it whole.
        var sha: String
        var source: KubeCommitSource
        /// The branch the comparison is with (`main`), when the checkout has one.
        var base: String?
        /// Commits `base` has that the deployed one doesn't.
        var behind: Int?
        /// The checkout's branch (nil when detached).
        var branch: String?
        /// Commits HEAD has that the deployed one doesn't: not out yet.
        var ahead: Int
        /// Commits the deployed one has that HEAD doesn't: deployed from elsewhere.
        var elsewhere: Int
        /// Whether the deployed commit is HEAD itself.
        var isHead: Bool

        var short: String { String(sha.prefix(7)) }
    }

    case found(Found)
    /// The commit no source gave a checkout has.
    case missing(sha: String, source: KubeCommitSource)
    /// No source gave a commit.
    case none

    var found: Found? { if case .found(let found) = self { found } else { nil } }

    /// As the rail says it: "deployed abc1234, 4 commits behind main; this
    /// branch is 2 commits ahead", "commit abc1234 is not in this
    /// checkout", "no commit found in the image".
    var text: String {
        switch self {
        case .none: return "no commit found in the image"
        case .missing(let sha, _): return "commit \(sha.prefix(7)) is not in this checkout"
        case .found(let found):
            var text = "deployed \(found.short)"
            if let base = found.base, let behind = found.behind {
                text += behind == 0 ? ", up to date with \(base)" : ", \(Self.commits(behind)) behind \(base)"
            }
            let onBase = found.branch != nil && found.branch == found.base
            let here = found.branch == nil ? "HEAD" : "this branch"
            if found.isHead {
                if !onBase { text += "; \(here) is at it" }
            } else if !onBase || found.behind == nil {
                text += found.ahead == 0 ? "; nothing on \(here) is newer" : "; \(here) is \(Self.commits(found.ahead)) ahead"
            }
            if found.elsewhere > 0 { text += "; it has \(Self.commits(found.elsewhere)) \(here) doesn't" }
            return text
        }
    }

    /// Where it was read, for the line under it.
    var sourceSaid: String? {
        switch self {
        case .found(let found): "from \(found.source.said)"
        case .missing(_, let source): "from \(source.said)"
        case .none: nil
        }
    }

    static func commits(_ count: Int) -> String { count == 1 ? "1 commit" : "\(count) commits" }
}

/// The sources, in order, and the checkout asked about the one that
/// wins (`Git.run`; nothing is fetched).
enum KubeDeployedCommit {
    /// A commit SHA's shape: 7–40 hex digits.
    static func isSHAShaped(_ text: String) -> Bool {
        (7...40).contains(text.count) && text.allSatisfy { $0.isHexDigit }
    }

    /// Digits alone: a short SHA can be (one in 25), but so is a build
    /// number (`20241105`) — such a one counts only when the checkout has it.
    static func isDigitsOnly(_ sha: String) -> Bool { sha.allSatisfy(\.isNumber) }

    /// The commit a tag is shaped like: the whole tag, or its last part
    /// after a `-`, `_` or `.` (`main-1a2b3c4`, `v1.2.0-1a2b3c4`, `sha-…`).
    static func commit(inTag tag: String) -> String? {
        if isSHAShaped(tag) { return tag.lowercased() }
        guard let last = tag.split(whereSeparator: { "-_.".contains($0) }).last.map(String.init), last.count < tag.count, isSHAShaped(last) else {
            return nil
        }
        return last.lowercased()
    }

    /// An image's tag (`ghcr.io/acme/web:1a2b3c4` → `1a2b3c4`), nil when
    /// it has none or is pinned by digest alone.
    static func tag(of image: String) -> String? {
        guard let reference = DockerImageReference(image), let tag = reference.tag else { return nil }
        // `nginx` alone reads as `:latest`; only a tag written says anything.
        return image.contains(":" + tag) ? tag : nil
    }

    /// Every commit the sources give, most trusted first: the revision
    /// labels asked for (image → revision), each image's SHA-shaped tag,
    /// then the appVersion.
    static func candidates(images: [String], revisions: [String: String] = [:], appVersion: String? = nil) -> [KubeCommitCandidate] {
        var found: [KubeCommitCandidate] = []
        for image in images {
            if let revision = revisions[image], isSHAShaped(revision) { found.append(.init(sha: revision.lowercased(), source: .revisionLabel, image: image)) }
        }
        for image in images {
            if let sha = tag(of: image).flatMap(commit(inTag:)) { found.append(.init(sha: sha, source: .tag, image: image)) }
        }
        if let appVersion, let sha = commit(inTag: appVersion) { found.append(.init(sha: sha, source: .appVersion, image: nil)) }
        return found.sorted { $0.source < $1.source }
    }

    /// The revision an image's `buildx imagetools inspect --format '{{json .}}'`
    /// names: its config's label or its manifest's annotation
    /// `org.opencontainers.image.revision`, the first SHA-shaped one.
    static func revision(inInspect output: String) -> String? {
        let pattern = #""org\.opencontainers\.image\.revision"\s*:\s*"([0-9A-Fa-f]{7,40})""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        for match in expression.matches(in: output, range: range) {
            guard let found = Range(match.range(at: 1), in: output) else { continue }
            let sha = String(output[found])
            if isSHAShaped(sha) { return sha.lowercased() }
        }
        return nil
    }

    /// The images of a workload's row (its Table's `Images` cell, comma separated).
    static func images(inCell cell: String?) -> [String] {
        (cell ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "<none>" }
    }

    // MARK: The checkout

    /// The first candidate the checkout has, compared with it; the first
    /// one missing when none is there; `.none` with no candidate.
    static func answer(_ candidates: [KubeCommitCandidate], in checkout: URL) async -> KubeDeployedAnswer {
        guard !candidates.isEmpty else { return .none }
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.sha).inserted {
            if let found = await compare(candidate, in: checkout) { return .found(found) }
        }
        // A tag of digits the checkout hasn't is a build number, not a commit.
        guard let first = candidates.first(where: { !isDigitsOnly($0.sha) }) else { return .none }
        return .missing(sha: first.sha, source: first.source)
    }

    /// The candidate looked up in the checkout: nil when it hasn't it.
    static func compare(_ candidate: KubeCommitCandidate, in checkout: URL) async -> KubeDeployedAnswer.Found? {
        func git(_ arguments: [String]) async -> String? {
            let output = try? await Git.run(arguments, in: checkout, success: [0, 1, 128], timeout: 15)
            return output?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard isSHAShaped(candidate.sha), let full = await git(["rev-parse", "--verify", "--quiet", "\(candidate.sha)^{commit}"]), full.count == 40,
            full.lowercased().hasPrefix(candidate.sha.lowercased())
        else { return nil }
        let head = await git(["rev-parse", "--verify", "--quiet", "HEAD"])
        let branch = await git(["symbolic-ref", "--quiet", "--short", "HEAD"])
        var base: String?
        for name in ["main", "master"] where base == nil {
            if await git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]) != nil { base = name }
        }
        if base == nil, let remote = await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) { base = remote }
        let behind = base == nil ? nil : await git(["rev-list", "--count", "\(full)..\(base!)"]).flatMap { Int($0) }
        let sides = await git(["rev-list", "--left-right", "--count", "\(full)...HEAD"])?.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return KubeDeployedAnswer.Found(
            sha: full, source: candidate.source, base: behind == nil ? nil : base, behind: behind, branch: branch, ahead: sides?.last ?? 0,
            elsewhere: sides?.first ?? 0, isHead: head == full)
    }

    /// `base...head` for "Diff deployed…current": what the checkout has
    /// that is not deployed yet, as a review tab reads it.
    static func review(_ found: KubeDeployedAnswer.Found) -> ReviewSource { .range(base: found.sha, head: "HEAD") }

    // MARK: Asked: the revision label, the appVersion

    /// `docker buildx imagetools inspect <image> --format '{{json .}}'`:
    /// the label and the annotation, from the registry, through the user's
    /// own docker (its credentials) — only when asked.
    static func inspectRevision(_ image: String, cli: DockerCLI) async -> String? {
        guard let output = try? await cli.run(["buildx", "imagetools", "inspect", image, "--format", "{{json .}}"], timeout: 30) else { return nil }
        return revision(inInspect: output)
    }
}
