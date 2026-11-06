import Foundation

// MARK: The dependency tree (docs/design/kubernetes/analysis.md, 3.7)

extension KubernetesPageModel {
    /// `x`: the selected object's Overview, its dependency tree in view;
    /// nothing for a kind without one.
    @discardableResult
    func openTree() -> Bool {
        let picked = detail?.ref ?? rows.first(where: { selection.contains($0.id) }).flatMap { ref(for: $0.id) }
        guard let ref = picked, !ref.isSecret, KubeTree.Root.of(ref.kind) != nil else { return false }
        detailTab = .overview
        if detail?.ref != ref { open(ref, from: .list) }
        detail?.showTree()
        updateLogsReading()
        revealTree += 1
        return true
    }

    /// The object a node is, as the detail's context serves its kind; nil
    /// for a container, or a kind it doesn't serve.
    func ref(for node: KubeTreeNode) -> KubeObjectRef? {
        guard let link = node.link, let context = detail?.ref.context ?? model.selectedName, let discovery = model.knownDiscovery(of: context) else {
            return nil
        }
        return link.resolve(in: discovery, context: context)
    }

    /// A node's verbs, as its object's detail has them — its right-click
    /// menu: Open first, then the detail's own buttons (forward, shell,
    /// logs, the writes, each with its guard), then Copy as kubectl.
    func treeVerbs(for node: KubeTreeNode) -> [ResourceVerb] {
        guard node.link != nil else { return [] }
        guard let ref = ref(for: node) else {
            let context = detail?.ref.context ?? model.selectedName ?? "The context"
            return [ResourceVerb(title: "Open", symbol: "arrow.up.right", place: .button, unavailable: "\(context) serves no \(node.kind).")]
        }
        let open = ResourceVerb(title: "Open", symbol: "arrow.up.right", place: .button, key: KubernetesKey.open.key) { [weak self] in
            self?.open(ref, from: .link)
        }
        let copy = ResourceVerb(title: "Copy as kubectl", symbol: "terminal", group: 9) { [weak self] in
            guard let self else { return }
            self.actions?.copy(KubectlLine.object(ref, discovery: self.model.knownDiscovery(of: ref.context)))
        }
        return [open] + detailVerbs(for: ref) + [copy]
    }

    /// A node's name pressed: its object's detail.
    func openTreeNode(_ node: KubeTreeNode) {
        guard let link = node.link else { return }
        follow(link)
    }
}
