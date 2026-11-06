import Foundation

// MARK: Kubernetes snippets in the verb menu (decision 18; KubeSnippet)

extension KubernetesPageModel {
    static let snippetsTitle = "Snippets"

    /// The one object picked: its snippets, a submenu.
    func snippetVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return snippetVerbs(for: ref)
    }

    func snippetVerbs(for ref: KubeObjectRef) -> [ResourceVerb] {
        let offered = (actions?.snippets() ?? []).filter { KubeSnippet.offered($0, on: ref, shownNamespace: shownNamespace) }
        guard !offered.isEmpty else { return [] }
        let children = offered.map { snippet in
            ResourceVerb(title: snippet.name, symbol: "text.insert") { [weak self] in self?.runSnippet(snippet, on: ref) }
        }
        return [ResourceVerb(title: Self.snippetsTitle, symbol: "text.insert", group: 5, children: children)]
    }

    /// The snippet filled from `ref` — its default container read when it
    /// names `${container}` (one GET of the pod; a picker for several) —,
    /// its own `{{…}}` asked for, on production asked first with the line
    /// shown, then typed into a tab pinned to the context and namespace.
    func runSnippet(_ snippet: Snippet, on ref: KubeObjectRef) {
        commandProblem = nil
        guard let context = model.contexts.context(named: ref.context) else {
            commandProblem = "No context called \(ref.context)."
            return
        }
        let namespace = KubeSnippet.namespace(of: ref, shown: shownNamespace)
        let discovery = model.knownDiscovery(of: ref.context)
        let go = { [weak self] (container: String?) in
            self?.typeSnippet(
                snippet, KubeSnippet.values(for: ref, namespace: namespace, container: container, discovery: discovery), context: context,
                namespace: namespace)
        }
        guard KubeSnippet.uses(snippet.command).contains("container"), let podNamespace = ref.namespace else {
            go(nil)
            return
        }
        guard let client = model.client(for: ref.context) else {
            commandProblem = "Kubernetes is off, or the context is gone."
            return
        }
        Task { [weak self] in
            let pick: KubeContainerPick
            do {
                pick = KubeContainerPick.of(try await client.object(ref.kind, namespace: podNamespace, name: ref.name).json, for: .followLogs)
            } catch {
                self?.commandProblem = "Couldn't read pod \(podNamespace)/\(ref.name): \(KubernetesModel.said(error))"
                return
            }
            switch pick {
            case .none: go(nil)
            case .one(let container): go(container)
            case .several(let containers, let chosen):
                self?.actions?.choose(
                    "Which container?", "\(snippet.name) — pod \(podNamespace)/\(ref.name) in \(context.displayName).",
                    containers.map { $0 == chosen ? "\($0) (default)" : $0 }
                ) { index in
                    guard containers.indices.contains(index) else { return }
                    go(containers[index])
                }
            }
        }
    }

    private func typeSnippet(_ snippet: Snippet, _ values: [String: String], context: KubeContext, namespace: String?) {
        if let missing = KubeSnippet.missing(snippet.command, values: values).first {
            commandProblem = "\(snippet.name) needs ${\(missing)}, which \(context.displayName)'s object here doesn't have."
            return
        }
        let filled = Snippet(id: snippet.id, name: snippet.name, command: KubeSnippet.fill(snippet.command, values: values))
        let tabNamespace = namespace ?? context.settings.defaultNamespace ?? context.namespace ?? "default"
        actions?.fillSnippet(filled) { [weak self] line in
            guard let self else { return }
            guard context.isProduction else {
                self.actions?.runInTab(line, context, tabNamespace)
                return
            }
            self.actions?.confirm(
                "Run “\(snippet.name)” on production?",
                "PRODUCTION · \(context.name) · namespace \(tabNamespace)\n\(line)\nTyped into a tab pinned to \(context.displayName): "
                    + "your own command, with your own credentials and rights. Overterm's read-only doesn't reach into a terminal.",
                "Run in \(context.displayName)"
            ) { [weak self] in self?.actions?.runInTab(line, context, tabNamespace) }
        }
    }
}
