import Foundation

// MARK: Health checks and the pinned contexts (docs/design/kubernetes/analysis.md, 3.9; decision 17)

extension KubernetesPageModel {
    /// The Overview's Refresh: the checks read again where they were.
    func refreshHealth() {
        guard overviewShows, let context = model.selectedName else { return }
        health.refresh(discovery: model.discovery, client: model.client(for: context))
    }

    /// A finding's object: its detail — from the Overview, its kind's list
    /// with it open; from a detail, followed as a link is.
    func openFinding(_ subject: KubeHealth.Subject) {
        if section == .overview {
            guard let context = model.selectedName, let discovery = model.knownDiscovery(of: context),
                let ref = subject.link.resolve(in: discovery, context: context)
            else { return }
            openFromOverview(kind: ref.kind.fullName, KubeRowID(namespace: ref.namespace, name: ref.name))
        } else {
            _ = follow(subject.link)
        }
    }

    /// The pinned contexts' cards, while the Overview shows: each through
    /// its proxy in a spare slot (never a browser sign-in, never a proxy
    /// closed for it), in the namespace the page would show it in.
    func showPinnedHealth() {
        let pinned = model.pinnedContexts
        let model = self.model
        pinnedHealth.show(
            by: self, pinned: pinned, contexts: model.contexts, discovery: { model.knownDiscovery(of: $0) },
            target: { context in
                guard model.enabled else { return nil }
                return (model.spareClient(for: context), model.agentDefaultScope(for: context))
            })
    }

    /// A card pressed: its context on the page, the Overview kept.
    func showPinned(_ name: String) {
        guard model.selectedName != name, model.contexts.context(named: name) != nil else { return }
        model.select(name)
    }
}
