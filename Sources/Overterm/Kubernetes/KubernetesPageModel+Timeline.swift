import Foundation

// MARK: A workload's change timeline (docs/design/kubernetes/analysis.md, 3.6)

extension KubernetesPageModel {
    /// `h`: the selected Deployment's, StatefulSet's or DaemonSet's History
    /// tab; nothing for another kind.
    @discardableResult
    func openHistory() -> Bool {
        guard let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id), ref.hasHistory else { return false }
        detailTab = .history
        open(ref, from: .list)
        detail?.showHistory()
        updateLogsReading()
        return true
    }

    /// A change's diff in the changes pane (the page steps aside). Two Helm
    /// revisions are two of the release's records read — Secrets, so on
    /// production the session's first asks, naming the context, as Show does.
    func openChange(_ change: KubeTimelineChange) {
        guard let timeline = detail?.timeline else { return }
        let context = timeline.ref.context
        let production = model.contexts.context(named: context)?.isProduction ?? true
        if case .helm = change, model.secretConsent.needsAsking(context, production: production) {
            actions?.confirm(
                "Read this release's revisions to compare them?",
                "PRODUCTION · \(context)\nHelm keeps each revision in a Secret: the two are read once, compared masked, and dropped — never written or kept. Asked once a session.",
                "Read and Compare"
            ) { [weak self] in
                self?.model.secretConsent.grant(context)
                self?.diffChange(change, in: timeline, production: production)
            }
            return
        }
        diffChange(change, in: timeline, production: production)
    }

    private func diffChange(_ change: KubeTimelineChange, in timeline: KubeTimelineSession, production: Bool) {
        // The timeline's task: navigating away cancels it, reads and all.
        timeline.startDiff(change, production: production) { [weak self] diff in
            guard let self, self.detail?.timeline === timeline else { return }
            self.actions?.showChange(diff)
        }
    }
}
