import Foundation

/// The checkout an Argo CD Application's history is read in (gitops.md
/// 2.9, G5): a tab of the window whose remotes name the Application's git
/// source (the rail's match, `KubeGitOpsMatch`), and the paths it
/// renders — its `path` and its `manifest-generate-paths`, each checked to
/// be in that checkout (`KubeGitOpsPath`).
struct KubeGitOpsHistoryCheckout: Equatable, Sendable {
    var root: URL
    /// Which of the Application's sources it is (its revisions' index).
    var source: Int
    var pathspecs: [String]

    /// "ot-kube-shop".
    var name: String { root.lastPathComponent }
}

extension KubernetesPageModel {
    /// The window's checkout of the Application's repository, if one is
    /// open; nil otherwise, or when its path isn't in it. Reads only the
    /// checkouts' remotes, once each, and looks at their files.
    func historyCheckout(_ detail: KubeGitOpsDetail) async -> KubeGitOpsHistoryCheckout? {
        guard detail.object.role == .application, !detail.history.isEmpty, let roots = actions?.checkouts(), !roots.isEmpty else { return nil }
        for (index, source) in detail.object.sources.enumerated() where !source.isValuesRef {
            guard let repo = source.repo, let checkout = await KubeGitOpsCheckouts.shared.checkout(naming: repo, among: roots) else { continue }
            let own = KubeGitOpsPath.resolve(source.path ?? "", in: checkout.root)
            guard own.relative != nil else { continue }
            let generated = detail.object.manifestPaths.map { KubeGitOpsPath.resolve(generatePath: $0, appPath: source.path, in: checkout.root) }
            return KubeGitOpsHistoryCheckout(root: checkout.root, source: index, pathspecs: KubeGitOpsGitArgs.pathspecs([own] + generated))
        }
        return nil
    }

    /// History entry `index` against the one before it, under the
    /// Application's paths, in a review tab of the checkout: both
    /// revisions verified to be commits there first (5.4) — one that isn't
    /// is said, nothing opened.
    func reviewHistory(_ detail: KubeGitOpsDetail, entry index: Int, in checkout: KubeGitOpsHistoryCheckout) {
        guard detail.history.indices.contains(index), detail.history.indices.contains(index + 1) else { return }
        func revision(_ entry: KubeGitOpsDetail.HistoryEntry) -> String? {
            let revisions = entry.revisions
            let said = revisions.indices.contains(checkout.source) ? revisions[checkout.source] : revisions.first
            return said.flatMap { KubeGitOpsRevision.parse($0).commit ?? (KubeDeployedCommit.isSHAShaped($0) ? $0 : nil) }
        }
        let newer = detail.history[index]
        let older = detail.history[index + 1]
        guard let head = revision(newer), let base = revision(older) else {
            commandProblem = "That history entry isn't a commit (\(newer.revisions.map(KubeGitOpsRevision.shown).joined(separator: " · "))): nothing to diff."
            return
        }
        commandProblem = nil
        Task { [weak self] in
            var full: [String] = []
            for sha in [base, head] {
                switch await KubeGitOpsGitArgs.resolve(sha, in: checkout.root) {
                case .commit(let commit): full.append(commit)
                case .ambiguous:
                    self?.commandProblem = "\(sha.prefix(7)) names several commits in \(checkout.name): nothing opened."
                    return
                case .missing:
                    self?.commandProblem = "Commit \(sha.prefix(7)) is not in \(checkout.name) — fetch to compare."
                    return
                case .refused:
                    self?.commandProblem = "\(sha.prefix(12)) isn't a commit: nothing opened."
                    return
                }
            }
            guard let self else { return }
            self.actions?.openReview(.paths(base: full[0], head: full[1], paths: checkout.pathspecs), checkout.root)
        }
    }
}
