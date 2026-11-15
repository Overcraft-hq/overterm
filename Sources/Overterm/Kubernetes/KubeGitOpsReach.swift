import Foundation

/// Has this branch's commit reached the cluster? (docs/design/kubernetes/
/// gitops.md, 4.3) — asked of a case (a) match only: an object that takes
/// its manifests from the checkout's repository. The rail shows its answer
/// under the match, beside the image's line (`KubeDeployedCommit`), never
/// ranked against it: the manifests, not the code.
///
/// - **The manifests line:** Argo CD's synced revision (the live one —
///   history's last, else the last operation's; a multi-source
///   Application's matched source), Flux's applied revision (a
///   Kustomization's `lastAppliedRevision`; a HelmRelease's newest history
///   entry's chart version, its `+<12 hex>` under the Revision strategy; an
///   OCI artifact's `org.opencontainers.image.revision` when the artifact
///   is the one applied) — a `KubeCommitCandidate` of source
///   `.gitopsRevision` answered by `KubeDeployedCommit` against the branch
///   it tracks: "manifests at a77b0d1, up to date with main; this branch is
///   1 commit ahead", "…, not in this checkout — fetch to compare", or by
///   source when it names no commit: "Argo CD's synced revision isn't a
///   commit (chart 1.4.2)".
/// - **Attempted ≠ applied:** "Flux tried c03f9aa (this branch's HEAD) and
///   failed: BuildFailed — …; a77b0d1 is still applied"; a HelmRelease
///   "…; rolled back to 1.4.2". The message is the summary's, scrubbed (5.3).
/// - **Fetched, not applied:** a Flux source's artifact the object hasn't
///   tried, Argo CD's `sync.revision` against its live one — which is
///   newer said by `merge-base --is-ancestor` when the checkout has both.
/// - **No change under the path** (Argo CD with a path): `rev-list --count
///   <live>..<remote>/<tracked> -- <pathspecs>` — "no change under apps/web
///   since a77b0d1 on origin/main", never "nothing".
/// - **Files this branch changes:** `diff --name-only <merge-base>...HEAD
///   -- <pathspecs>` against the tracked branch (the remote's, else the
///   local one): "3 files under apps/web on this branch", a review tab of
///   them, or "no change under apps/web on this branch".
/// - **The pathspecs:** the path, `manifest-generate-paths`' entries, and
///   the path's own `kustomization.yaml` `resources:` and `components:`,
///   one level deep (256 KB at most; a URL entry not followed, said) —
///   each through `KubeGitOpsPath`; the line names what it checked.
///
/// Everything cluster-supplied reaches git through `KubeGitOpsGitArgs`
/// (5.4): SHAs verified, refs checked, pathspecs literal. Nothing is
/// fetched: every answer is as of the last fetch, and says so. `Question`
/// is pure; its `key` — what git is asked about: the revisions, the paths,
/// the tracked branch, HEAD and the checkout's refs — is what an answer is
/// kept by, so an event that changes nothing git reads (a Ready flipping
/// to Progressing and back at every reconcile, a message, Stuck worked out
/// from the clock) runs no git; its words are said again from the
/// question as it is now (`labeled`).
enum KubeGitOpsReach {
    typealias Runner = KubeGitOpsCheckouts.Runner

    /// What the object applied, as a commit or not.
    enum Applied: Hashable, Sendable {
        /// A whole SHA, or a 12-character prefix (`prefix`) that must name one commit.
        case commit(String, prefix: Bool)
        /// A revision that names no commit: as shown ("chart 1.4.2", "sha256:1f2e3d4").
        case notACommit(String)
        /// Nothing applied yet.
        case none
    }

    /// Flux tried a revision and it failed.
    struct Attempt: Hashable, Sendable {
        /// As shown: `c03f9aa`, `1.5.0`.
        var shown: String
        var commit: String?
        var reason: String?
        var message: String?
        /// "a77b0d1 is still applied", "rolled back to 1.4.2".
        var after: String
    }

    /// A revision there that isn't applied: Flux's fetched artifact, Argo CD's `sync.revision`.
    struct Fetched: Hashable, Sendable {
        var shown: String
        var commit: String?
        /// The applied one it is compared with.
        var applied: String?
        var appliedShown: String?
    }

    /// Everything one answer reads, cluster- and checkout-supplied alike;
    /// `key` the part git is asked about.
    struct Question: Hashable, Sendable {
        var tool: KubeGitOpsObject.Tool
        /// `Kustomization acme-apps, Ready`.
        var said: String
        var applied: Applied
        var attempted: Attempt?
        var fetched: Fetched?
        /// The object's path in the checkout (`""`: its root); nil when not here.
        var path: String?
        /// `manifest-generate-paths`' entries, as written.
        var generatePaths: [String] = []
        /// The remote its repository is, and the branch it tracks.
        var remote: String?
        var tracked: String?
        /// "No change under the path" is Argo CD's.
        var countsUnder: Bool
        /// HEAD's commit.
        var head: String?
        /// The checkout's refs (`KubeGitOpsMatch.Checkout.refs`): a fetch that moves the tracked branch asks again.
        var refs: Int?

        /// What git is asked about: not the state's word, not the failure's
        /// reason and message — those change at every reconcile and are said
        /// from the question as it is now (`labeled`).
        var key: Key {
            Key(
                applied: applied, attempted: attempted?.commit, fetched: fetched, path: path, generatePaths: generatePaths, remote: remote,
                tracked: tracked, countsUnder: countsUnder, head: head, refs: refs)
        }
    }

    /// A question's git: an answer's key.
    struct Key: Hashable, Sendable {
        var applied: Applied
        var attempted: String?
        var fetched: Fetched?
        var path: String?
        var generatePaths: [String]
        var remote: String?
        var tracked: String?
        var countsUnder: Bool
        var head: String?
        var refs: Int?
    }

    /// The rail's lines for one match.
    struct Answer: Equatable, Sendable {
        var deployed: KubeDeployedAnswer
        /// "from Flux's applied revision (Kustomization acme-apps, Ready)".
        var source: String
        var attempted: String?
        var fetched: String?
        /// "no change under deploy/fake-dev since a77b0d1 on origin/main".
        var unchanged: String?
        var changed: KubeGitOpsChanges?
        /// What was checked, and what wasn't followed.
        var checked: [String] = []
        /// The pathspecs used.
        var pathspecs: [String] = []
        /// From applied to attempted (or to git's newer one), for Ask Why: both commits whole.
        var range: CommitRange?

        /// The manifests line's Diff Deployed…Current.
        var found: KubeDeployedAnswer.Found? { deployed.found }
    }

    struct CommitRange: Equatable, Sendable {
        var from: String
        var to: String
    }

    /// At most this many changed files kept, and commits briefed.
    static let maxFiles = 200
    static let maxCommits = 20
    /// A `kustomization.yaml` read at most this big.
    static let maxKustomization = 256 << 10

    // MARK: The question (pure)

    /// The question for a match, when it is case (a); nil otherwise.
    static func question(
        _ object: KubeGitOpsObject, why: KubeGitOpsMatch.Why, checkout: KubeGitOpsMatch.Checkout, peers: [KubeGitOpsObject.Key: KubeGitOpsObject]
    ) -> Question? {
        guard why.isRepository else { return nil }
        let index = why.source ?? 0
        var path: String?
        if case .repoAndPath(let found, _) = why { path = found }
        let tracked = KubeGitOpsMatch.tracked(object, why: why, in: checkout, objects: peers)
        var remote: String?
        switch object.role {
        case .application:
            let sources = object.sources
            let at = sources.indices.contains(index) ? index : sources.firstIndex { $0.repo.map(checkout.repos.contains) ?? false }
            remote = at.flatMap { sources[$0].repo }.flatMap(checkout.remote(for:))?.name
        default:
            if let source = upstreamSource(object, peers: peers), let repo = source.sources.first?.repo ?? source.artifactOrigin?.repo {
                remote = checkout.remote(for: repo)?.name
            }
        }
        let state = object.state.word
        return Question(
            tool: object.tool, said: "\(object.kind) \(object.ref.name), \(state)", applied: applied(object, source: index, peers: peers),
            attempted: attempted(object), fetched: fetched(object, source: index, peers: peers), path: path,
            generatePaths: object.role == .application ? object.manifestPaths : [], remote: remote, tracked: tracked,
            countsUnder: object.role == .application && path != nil, head: checkout.head, refs: checkout.refs)
    }

    /// A Kustomization's or HelmRelease's git or OCI source (a chartRef's HelmChart's own).
    static func upstreamSource(_ object: KubeGitOpsObject, peers: [KubeGitOpsObject.Key: KubeGitOpsObject]) -> KubeGitOpsObject? {
        if let reference = object.sourceRef, let source = peers[KubeGitOpsMatch.key(reference)] {
            if source.role == .source("HelmChart"), let further = source.sourceRef { return peers[KubeGitOpsMatch.key(further)] }
            return source
        }
        if let reference = object.chartRef, let chart = peers[KubeGitOpsMatch.key(reference)] {
            if chart.role == .source("HelmChart"), let further = chart.sourceRef { return peers[KubeGitOpsMatch.key(further)] }
            return chart
        }
        return nil
    }

    /// The `index`th of several (a multi-source Application's), else the only one.
    private static func pick(_ revisions: [String], _ index: Int) -> String? {
        if revisions.indices.contains(index) { return revisions[index] }
        return revisions.count == 1 ? revisions[0] : nil
    }

    /// What is applied, by tool (2.6).
    static func applied(_ object: KubeGitOpsObject, source index: Int, peers: [KubeGitOpsObject.Key: KubeGitOpsObject]) -> Applied {
        switch object.role {
        case .application:
            guard let revision = pick(object.revisions.applied, index).flatMap(nonEmpty) else { return .none }
            return applied(revision, chart: object.sources.indices.contains(index) ? object.sources[index].chart != nil : false)
        case .kustomization:
            guard let revision = object.revisions.applied.first.flatMap(nonEmpty) else { return .none }
            let parsed = KubeGitOpsRevision.parse(revision)
            if parsed.commit == nil, parsed.digest != nil, let source = upstreamSource(object, peers: peers), source.role == .source("OCIRepository"),
                source.artifact?.revision == revision, let origin = source.artifactOrigin?.revision.flatMap(KubeGitOpsGitArgs.revision)
            {
                // The artifact applied is the one built from this commit.
                return .commit(origin, prefix: origin.count < 40)
            }
            return applied(revision, chart: false)
        case .helmRelease:
            guard let version = object.revisions.helmHistory?.chartVersion.flatMap(nonEmpty) else { return .none }
            let parsed = KubeGitOpsRevision.parse(version)
            if let commit = parsed.commit, parsed.prefix { return .commit(commit, prefix: true) }
            return .notACommit("chart \(parsed.shown)")
        case .applicationSet, .source, .markedApp:
            return .none
        }
    }

    private static func applied(_ revision: String, chart: Bool) -> Applied {
        let parsed = KubeGitOpsRevision.parse(revision)
        if let commit = parsed.commit { return .commit(commit, prefix: parsed.prefix) }
        if KubeDeployedCommit.isSHAShaped(revision), !KubeDeployedCommit.isDigitsOnly(revision) {
            // Argo CD's short SHA: resolved like a prefix.
            return .commit(revision.lowercased(), prefix: true)
        }
        return .notACommit(chart || parsed.digest == nil ? "chart \(parsed.shown)" : parsed.shown)
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// A revision as the attempted line says it (4.3): a commit's short SHA
    /// ("c03f9aa", not "main@c03f9aa"), else as shown ("1.5.0", "sha256:1f2e3d4").
    static func said(_ parsed: KubeGitOpsRevision.Parsed) -> String {
        if let commit = parsed.commit, !parsed.prefix { return String(commit.prefix(KubeGitOpsRevision.short)) }
        return parsed.shown
    }

    /// Flux tried something else than what is applied, and it failed.
    static func attempted(_ object: KubeGitOpsObject) -> Attempt? {
        let ready = object.condition("Ready")
        guard ready?.isFalse == true, let attempted = object.revisions.attempted.flatMap(nonEmpty) else { return nil }
        let parsed = KubeGitOpsRevision.parse(attempted)
        let message = object.lastError
        switch object.role {
        case .kustomization:
            guard let applied = object.revisions.applied.first, applied != attempted else { return nil }
            return Attempt(
                shown: said(parsed), commit: parsed.commit, reason: ready?.reason, message: message,
                after: "\(said(KubeGitOpsRevision.parse(applied))) is still applied")
        case .helmRelease:
            let history = object.revisions.helmHistory
            guard let deployed = history?.chartVersion, deployed != parsed.shown || history?.status != "deployed" else { return nil }
            let rolledBack = ready?.reason == "RollbackSucceeded"
            let after =
                rolledBack
                ? "rolled back to \(KubeGitOpsRevision.shown(deployed))" : "\(KubeGitOpsRevision.shown(deployed)) is \(history?.status ?? "deployed")"
            return Attempt(
                shown: parsed.shown, commit: parsed.prefix ? parsed.commit : nil, reason: rolledBack ? nil : ready?.reason, message: message,
                after: after)
        default:
            return nil
        }
    }

    /// Fetched or seen in git, not applied.
    static func fetched(_ object: KubeGitOpsObject, source index: Int, peers: [KubeGitOpsObject.Key: KubeGitOpsObject]) -> Fetched? {
        switch object.role {
        case .application:
            guard let wanted = pick(object.revisions.wanted, index).flatMap(nonEmpty), let live = pick(object.revisions.applied, index).flatMap(nonEmpty),
                wanted != live
            else { return nil }
            let a = KubeGitOpsRevision.parse(wanted)
            let b = KubeGitOpsRevision.parse(live)
            return Fetched(shown: a.shown, commit: a.commit, applied: b.commit, appliedShown: b.shown)
        case .kustomization, .helmRelease:
            guard let (revision, _) = KubeGitOpsLadder.unattempted(object, peers: peers) else { return nil }
            let a = KubeGitOpsRevision.parse(revision)
            let applied = object.role == .kustomization ? object.revisions.applied.first : nil
            // The source holds what is applied: nothing new fetched (the attempt is the attempted line's).
            if let applied, applied == revision { return nil }
            let b = applied.map(KubeGitOpsRevision.parse)
            return Fetched(shown: a.shown, commit: a.commit, applied: b?.commit, appliedShown: b?.shown ?? object.revisions.helmHistory?.chartVersion)
        default:
            return nil
        }
    }

    // MARK: The words (pure)

    /// "Argo CD's synced revision isn't a commit (chart 1.4.2)", "Flux hasn't applied anything yet".
    static func notACommit(_ question: Question, shown: String?) -> String {
        let source = KubeCommitSource.gitopsRevision.said(tool: question.tool)
        guard let shown else { return question.tool == .argo ? "Argo CD hasn't synced a revision yet" : "Flux hasn't applied a revision yet" }
        return "\(source) isn't a commit (\(shown))"
    }

    /// "from Flux's applied revision (Kustomization acme-apps, Ready)".
    static func sourceText(_ question: Question) -> String {
        "from \(KubeCommitSource.gitopsRevision.said(tool: question.tool)) (\(question.said))"
    }

    /// An answer's words from the question as it is now: kept by `Question.key`,
    /// its source's state and the failure's message said again, no git.
    static func labeled(_ answer: Answer, _ question: Question) -> Answer {
        var answer = answer
        answer.source = sourceText(question)
        answer.attempted = question.attempted.map { KubeMCPText.scrubbed(attemptedText($0, head: question.head)) }
        return answer
    }

    /// "Flux tried c03f9aa (this branch's HEAD) and failed: BuildFailed — …; a77b0d1 is still applied".
    static func attemptedText(_ attempt: Attempt, head: String?) -> String {
        let isHead = attempt.commit != nil && attempt.commit == head
        var text = "Flux tried \(attempt.shown)" + (isHead ? " (this branch's HEAD)" : "") + " and failed"
        // The summary's last error already leads with its reason, mostly ("BuildFailed: …").
        var words = [attempt.reason, attempt.message].compactMap { $0?.isEmpty == false ? $0 : nil }
        if let reason = attempt.reason, let message = attempt.message, message.hasPrefix(reason) { words = [message] }
        if !words.isEmpty { text += ": " + words.joined(separator: " — ") }
        return text + "; " + attempt.after
    }

    /// "Flux fetched c03f9aa, not applied yet (newer than a77b0d1)".
    static func fetchedText(_ fetched: Fetched, tool: KubeGitOpsObject.Tool, order: Order?) -> String {
        var text =
            tool == .argo
            ? "git has \(fetched.shown); Argo CD synced \(fetched.appliedShown ?? "something else")" : "Flux fetched \(fetched.shown), not applied yet"
        if let order, let applied = fetched.appliedShown {
            switch order {
            case .newer: text += " (newer than \(applied))"
            case .older: text += " (older than \(applied))"
            case .apart: text += " (not on \(applied)'s line)"
            }
        }
        return text
    }

    enum Order: Equatable, Sendable { case newer, older, apart }

    /// "deploy/fake-dev", "deploy/fake-dev, k8s/api.yaml", "deploy/fake-dev and 3 more paths".
    static func under(_ pathspecs: [String]) -> String {
        let names = pathspecs.map { $0 == "." ? "the repository's root" : $0 }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names[0]) and \(names.count - 1) more paths"
    }

    /// "no change under deploy/fake-dev since a77b0d1 on origin/main", "2 commits under … on origin/main since a77b0d1, not synced".
    static func unchangedText(count: Int, pathspecs: [String], since: String, on ref: String) -> String {
        let since = String(since.prefix(KubeGitOpsRevision.short))
        if count == 0 { return "no change under \(under(pathspecs)) since \(since) on \(ref)" }
        return "\(KubeDeployedAnswer.commits(count)) under \(under(pathspecs)) on \(ref) since \(since), not synced"
    }

    // MARK: The pathspecs

    /// The path, `manifest-generate-paths`' entries, the path's
    /// `kustomization.yaml` entries one level deep — each in the checkout
    /// (`KubeGitOpsPath`); what wasn't followed, said.
    static func pathspecs(path: String, generatePaths: [String], in root: URL) -> (pathspecs: [String], notes: [String]) {
        var resolved: [KubeGitOpsPath.Resolved] = [KubeGitOpsPath.resolve(path, in: root)]
        guard resolved[0].relative != nil else { return ([], []) }
        var notes: [String] = []
        var refused = 0
        for entry in generatePaths {
            let entry = entry.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            let found = KubeGitOpsPath.resolve(generatePath: entry, appPath: path, in: root)
            if found.relative != nil { resolved.append(found) } else { refused += 1 }
        }
        let read = kustomizationEntries(path: path, in: root)
        resolved += read.entries
        refused += read.refused
        if read.urls > 0 { notes.append("\(read.urls) remote \(read.urls == 1 ? "entry" : "entries") of its kustomization.yaml not followed") }
        if read.tooBig { notes.append("its kustomization.yaml is over 256 KB, not read") }
        if refused > 0 { notes.append("\(refused) \(refused == 1 ? "path" : "paths") outside the checkout or not here left out") }
        // A path under another one adds nothing: left out.
        let all = KubeGitOpsGitArgs.pathspecs(resolved)
        let kept = all.filter { path in !all.contains { $0 != path && ($0 == "." || path.hasPrefix($0 + "/")) } }
        return (kept, notes)
    }

    /// The path's `kustomization.yaml` (`.yml`, `Kustomization`): its
    /// `resources:` and `components:` that are paths in the checkout.
    static func kustomizationEntries(path: String, in root: URL) -> (entries: [KubeGitOpsPath.Resolved], urls: Int, refused: Int, tooBig: Bool) {
        guard case .inCheckout(let relative) = KubeGitOpsPath.resolve(path, in: root) else { return ([], 0, 0, false) }
        let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
        for name in ["kustomization.yaml", "kustomization.yml", "Kustomization"] {
            let file = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), (attributes[.type] as? FileAttributeType) == .typeRegular
            else { continue }
            if let size = attributes[.size] as? Int, size > maxKustomization { return ([], 0, 0, true) }
            guard let text = try? String(contentsOf: file, encoding: .utf8), let document = YAMLReader.parse(text) as? [String: Any] else {
                return ([], 0, 0, false)
            }
            return entries(document, base: relative, in: root)
        }
        return ([], 0, 0, false)
    }

    /// A kustomization's `resources:` and `components:` relative to `base`, one level deep.
    static func entries(_ document: [String: Any], base: String, in root: URL) -> (entries: [KubeGitOpsPath.Resolved], urls: Int, refused: Int, tooBig: Bool) {
        var found: [KubeGitOpsPath.Resolved] = []
        var urls = 0
        var refused = 0
        for key in ["resources", "components"] {
            for case let entry as String in document[key] as? [Any] ?? [] {
                let entry = entry.trimmingCharacters(in: .whitespaces)
                guard !entry.isEmpty else { continue }
                if isRemote(entry) {
                    urls += 1
                    continue
                }
                let resolved = KubeGitOpsPath.resolve(base.isEmpty ? entry : "\(base)/\(entry)", in: root)
                if resolved.relative != nil { found.append(resolved) } else { refused += 1 }
            }
        }
        return (found, urls, refused, false)
    }

    /// A kustomize remote: a URL, `github.com/…`, `git@…`, anything with `?ref=`.
    static func isRemote(_ entry: String) -> Bool {
        entry.contains("://") || entry.hasPrefix("git@") || entry.contains("?ref=") || entry.hasPrefix("github.com/") || entry.hasPrefix("gitlab.com/")
    }

    // MARK: The checkout (git, through `KubeGitOpsGitArgs`)

    /// The answer, against the checkout: every git call through `git`, nothing fetched.
    static func answer(_ question: Question, in root: URL, git: @escaping Runner) async -> Answer {
        func run(_ arguments: [String]?, success: Set<Int32> = [0]) async -> String? {
            guard let arguments else { return nil }
            return (try? await git(arguments, root, success))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The tracked branch, the remote's first, else the local one.
        var trackedRef: KubeDeployedCommit.Base?
        if let tracked = question.tracked {
            var refs: [KubeDeployedCommit.Base] = []
            if let remote = question.remote, let ref = KubeGitOpsGitArgs.remoteRef(remote: remote, tracked) { refs.append(.init(ref: ref, said: "\(remote)/\(tracked)")) }
            if let local = KubeGitOpsGitArgs.ref(tracked) {
                refs.append(.init(ref: "refs/heads/\(local)", said: local))
                refs.append(.init(ref: "refs/tags/\(local)", said: "tag \(local)"))
            }
            for candidate in refs where trackedRef == nil {
                if let sha = await run(KubeGitOpsGitArgs.refArguments(candidate.ref), success: [0, 1]), sha.count == 40 { trackedRef = candidate }
            }
        }
        var answer = Answer(deployed: .none, source: sourceText(question))
        // The branch it tracks isn't here: said, and nothing compared with another one.
        if let tracked = question.tracked, trackedRef == nil, KubeGitOpsGitArgs.ref(tracked) != nil {
            answer.checked.append("\(question.remote.map { "\($0)/" } ?? "")\(tracked) isn't in this checkout — fetch to compare")
        }

        // The manifests line.
        var applied: String?
        switch question.applied {
        case .none:
            answer.deployed = .notACommit(notACommit(question, shown: nil))
        case .notACommit(let shown):
            answer.deployed = .notACommit(notACommit(question, shown: shown))
        case .commit(let sha, let prefix):
            switch await KubeGitOpsGitArgs.resolve(sha, in: root, git: git) {
            case .commit(let full):
                applied = full
                // The branch it tracks; none when it isn't here (never main for an app that tracks release).
                let bases: [KubeDeployedCommit.Base]? = question.tracked == nil ? nil : trackedRef.map { [$0] } ?? []
                let candidate = KubeCommitCandidate(sha: full, source: .gitopsRevision, image: nil)
                answer.deployed = await KubeDeployedCommit.answer([candidate], in: root, bases: bases, git: git)
            case .ambiguous:
                answer.deployed = .notACommit("manifests at \(sha.prefix(12)), which names several commits here (ambiguous)")
            case .missing, .refused:
                answer.deployed = .missing(sha: prefix ? String(sha.prefix(12)) : sha, source: .gitopsRevision)
            }
        }

        // Attempted ≠ applied.
        if let attempt = question.attempted {
            answer.attempted = labeled(answer, question).attempted
            if let from = applied, let to = attempt.commit, case .commit(let full) = await KubeGitOpsGitArgs.resolve(to, in: root, git: git) {
                answer.range = CommitRange(from: from, to: full)
            }
        }

        // Fetched, not applied.
        if let fetched = question.fetched {
            var order: Order?
            var fetchedFull: String?
            if let commit = fetched.commit, case .commit(let full) = await KubeGitOpsGitArgs.resolve(commit, in: root, git: git) { fetchedFull = full }
            // Only verified commits reach git (5.4): the applied one resolved above, never the cluster's text.
            if let a = applied, let b = fetchedFull, a != b {
                if await run(KubeGitOpsGitArgs.ancestorArguments(a, b), success: [0]) != nil {
                    order = .newer
                } else if await run(KubeGitOpsGitArgs.ancestorArguments(b, a), success: [0]) != nil {
                    order = .older
                } else {
                    order = .apart
                }
            }
            answer.fetched = fetchedText(fetched, tool: question.tool, order: order)
            if answer.range == nil, let from = applied, let to = fetchedFull, order == .newer { answer.range = CommitRange(from: from, to: to) }
        }

        // The pathspecs, and what changed under them.
        guard let path = question.path else { return answer }
        let specs = pathspecs(path: path, generatePaths: question.generatePaths, in: root)
        answer.pathspecs = specs.pathspecs
        answer.checked += specs.notes
        guard !specs.pathspecs.isEmpty, let trackedRef else { return answer }
        if question.countsUnder, let live = applied,
            let count = await run(KubeGitOpsGitArgs.countArguments(from: live, to: trackedRef.ref, pathspecs: specs.pathspecs)).flatMap({ Int($0) })
        {
            answer.unchanged = unchangedText(count: count, pathspecs: specs.pathspecs, since: live, on: trackedRef.said)
        }
        // Not trimmed: NUL-separated names, as they are on disk.
        if let base = await run(KubeGitOpsGitArgs.mergeBaseArguments(trackedRef.ref)), base.count == 40, let head = question.head,
            let arguments = KubeGitOpsGitArgs.changedArguments(base: base, pathspecs: specs.pathspecs), let output = try? await git(arguments, root, [0])
        {
            let files = KubeGitOpsGitArgs.changedFiles(output)
            answer.changed = KubeGitOpsChanges(
                files: Array(files.prefix(maxFiles)), more: max(0, files.count - maxFiles), under: under(specs.pathspecs), against: trackedRef.said, base: base,
                head: head)
        }
        return answer
    }

    /// Ask Why's commits: `git log --oneline` from applied to attempted, at most 20.
    static func commits(_ range: CommitRange, in root: URL, git: @escaping Runner) async -> [String] {
        guard let arguments = KubeGitOpsGitArgs.logArguments(from: range.from, to: range.to, limit: maxCommits),
            let output = try? await git(arguments, root, [0])
        else { return [] }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// What the rail adds to Ask Why's brief, with a matched checkout
    /// (gitops.md 6.2): the lines above, the commits between applied and
    /// attempted, the changed files — every word through `Secrets`.
    static func briefParts(_ answer: Answer, commits: [String], checkout: URL) -> [AskAgentModel.Part] {
        var lines = ["Checkout \(checkout.lastPathComponent): " + answer.deployed.text + " (\(answer.source))."]
        for line in [answer.attempted, answer.fetched, answer.unchanged].compactMap({ $0 }) { lines.append(line + ".") }
        if let changed = answer.changed { lines.append(changed.text + " (against \(changed.against)).") }
        lines += answer.checked.map { $0 + "." }
        lines.append("Every git answer is as of the checkout's last fetch.")
        var parts = [AskAgentModel.Part(title: "checkout", text: KubeMCPText.scrubbed(lines.joined(separator: "\n")))]
        if !commits.isEmpty, let range = answer.range {
            let head = "Commits from \(range.from.prefix(7)) (applied) to \(range.to.prefix(7)), newest first, at most \(maxCommits):"
            parts.append(.init(title: "commits", text: KubeMCPText.scrubbed(([head] + commits).joined(separator: "\n"))))
        }
        if let changed = answer.changed, !changed.files.isEmpty {
            let head = "Files this branch changes under \(changed.under), against \(changed.against):"
            let more = changed.more > 0 ? ["and \(changed.more) more"] : []
            parts.append(.init(title: "changed files", text: KubeMCPText.scrubbed(([head] + changed.files + more).joined(separator: "\n"))))
        }
        return parts
    }
}

/// The files this branch changes under a match's pathspecs, against the
/// branch it tracks: "3 files under apps/web on this branch", opening a
/// review of them (`ReviewSource.paths`, from their merge base to HEAD).
struct KubeGitOpsChanges: Equatable, Sendable {
    var files: [String]
    var more = 0
    /// "deploy/fake-dev, k8s/api.yaml".
    var under: String
    /// "origin/main".
    var against: String
    /// The merge base and HEAD, whole.
    var base: String
    var head: String

    var count: Int { files.count + more }

    var text: String {
        count == 0 ? "no change under \(under) on this branch" : "\(count == 1 ? "1 file" : "\(count) files") under \(under) on this branch"
    }

    var review: ReviewSource? { files.isEmpty ? nil : .paths(base: base, head: head, paths: files) }
}
