import Foundation

/// A revision as Argo CD and Flux write it, read for what is shown and for
/// the commit it names, if any (docs/design/kubernetes/gitops.md, 2.6):
///
/// | Written | Shown | Commit |
/// |---|---|---|
/// | `main@sha1:<40>`, `refs/heads/main@sha1:…`, `v1.2.3@sha1:…` | `main@a77b0d1` | the SHA |
/// | Flux's legacy `main/<40>` | `main@a77b0d1` | the SHA |
/// | `sha1:<40>` | `a77b0d1` | the SHA |
/// | `…@sha256:<64>`, `sha256:…` (OCI, Bucket, a SHA-256 repository) | `sha256:1f2e3d4` | none |
/// | a chart version `1.2.3`, `1.2.3+<12 hex>` | `1.2.3` | the 12 after `+`, to be verified |
/// | Argo CD's `a77b0d1…` | `a77b0d1` | the SHA |
///
/// A commit here is a candidate only: it reaches git through
/// `KubeGitOpsGitArgs`, which verifies it. Pure.
enum KubeGitOpsRevision {
    struct Parsed: Equatable, Sendable {
        /// What a row shows, 7 hex digits of a SHA.
        var shown: String
        /// The commit, when the revision names one: a whole SHA (40 hex), or
        /// a Helm chart version's 12-character prefix (`prefix` true).
        var commit: String?
        /// Whether `commit` is a prefix that must resolve to one commit first.
        var prefix = false
        /// The branch or tag it was fetched from, `refs/heads/` dropped.
        var ref: String?
        /// A content digest (`sha256:…`), which names no commit.
        var digest: String?
    }

    /// How many hex digits a row shows.
    static let short = 7

    static func parse(_ text: String) -> Parsed {
        let text = text.trimmingCharacters(in: .whitespaces)
        // `<ref>@sha1:<40>` / `<ref>@sha256:<64>`, and the bare digests.
        if let at = text.range(of: "@", options: .backwards) {
            let ref = String(text[..<at.lowerBound])
            let digest = String(text[at.upperBound...])
            var parsed = parseDigest(digest)
            if parsed.digest != nil || parsed.commit != nil {
                parsed.ref = trimmedRef(ref)
                if let ref = parsed.ref, parsed.commit != nil { parsed.shown = "\(ref)@\(parsed.shown)" }
                return parsed
            }
        }
        if text.hasPrefix("sha1:") || text.hasPrefix("sha256:") { return parseDigest(text) }
        // Flux's legacy `main/<40 hex>`.
        if let slash = text.range(of: "/", options: .backwards) {
            let sha = String(text[slash.upperBound...])
            if sha.count == 40, isHex(sha) {
                let ref = trimmedRef(String(text[..<slash.lowerBound]))
                return Parsed(shown: "\(ref.map { "\($0)@" } ?? "")\(sha.prefix(short).lowercased())", commit: sha.lowercased(), ref: ref)
            }
        }
        // A whole or short SHA alone (Argo CD's): shown short.
        if KubeDeployedCommit.isSHAShaped(text), !KubeDeployedCommit.isDigitsOnly(text) {
            return Parsed(shown: String(text.prefix(short)).lowercased(), commit: text.count == 40 ? text.lowercased() : nil)
        }
        // A chart version, `+<12 hex>` its commit under Flux's Revision strategy.
        if let plus = text.firstIndex(of: "+") {
            let version = String(text[..<plus])
            let build = String(text[text.index(after: plus)...])
            if build.count == 12, isHex(build) { return Parsed(shown: version, commit: build.lowercased(), prefix: true) }
            return Parsed(shown: version)
        }
        return Parsed(shown: text)
    }

    /// `main@a77b0d1`, `a77b0d1`, `sha256:1f2e3d4`, `1.2.3`.
    static func shown(_ text: String) -> String { parse(text).shown }

    /// The commit a revision names, else nil (a digest, a chart version without a build).
    static func commit(_ text: String) -> String? { parse(text).commit }

    /// `sha1:<40>` or `sha256:<64>`.
    private static func parseDigest(_ text: String) -> Parsed {
        if text.hasPrefix("sha1:") {
            let sha = String(text.dropFirst(5))
            if sha.count == 40, isHex(sha) { return Parsed(shown: String(sha.prefix(short)).lowercased(), commit: sha.lowercased()) }
        }
        if text.hasPrefix("sha256:") {
            let digest = String(text.dropFirst(7))
            if digest.count == 64, isHex(digest) { return Parsed(shown: "sha256:\(digest.prefix(short).lowercased())", digest: text.lowercased()) }
        }
        return Parsed(shown: text)
    }

    /// `refs/heads/main` is `main`, `refs/tags/v1` is `v1`; "" is none.
    private static func trimmedRef(_ ref: String) -> String? {
        var ref = ref
        for prefix in ["refs/heads/", "refs/tags/"] where ref.hasPrefix(prefix) { ref.removeFirst(prefix.count) }
        return ref.isEmpty ? nil : ref
    }

    private static func isHex(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy(\.isHexDigit) }

    /// A row's Revision column: Argo CD's `live → target` while OutOfSync
    /// (each source's, `·` between, for several); Flux's applied revision;
    /// a Source's artifact. "" when nothing is known.
    static func column(_ object: KubeGitOpsObject) -> String {
        let revisions = object.revisions
        switch object.role {
        case .application:
            let live = revisions.applied.map(shown).filter { !$0.isEmpty }.joined(separator: " · ")
            let wanted = revisions.wanted.map(shown).filter { !$0.isEmpty }.joined(separator: " · ")
            if object.sync == "OutOfSync", !wanted.isEmpty, wanted != live { return live.isEmpty ? "→ \(wanted)" : "\(live) → \(wanted)" }
            return live.isEmpty ? wanted : live
        case .kustomization:
            return revisions.applied.first.map(shown) ?? ""
        case .helmRelease:
            return revisions.helmHistory?.chartVersion ?? revisions.attempted.map(shown) ?? ""
        case .source:
            return object.artifact?.revision.map(shown) ?? ""
        case .applicationSet, .markedApp:
            return ""
        }
    }
}
