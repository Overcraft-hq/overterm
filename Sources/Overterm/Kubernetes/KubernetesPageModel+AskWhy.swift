import Foundation

// MARK: Ask Why (stage 1e; docs/design/kubernetes/analysis.md, 3.4)

extension KubernetesPageModel {
    /// Whether a ref is something Ask Why asks about: a pod, a Deployment.
    static func asksWhy(_ ref: KubeObjectRef) -> Bool {
        ref.isPod || (ref.kind.group == "apps" && ref.kind.kind == "Deployment" && ref.namespace != nil)
    }

    /// What `a` and ⌘L act on: the detail's object while it shows a pod or
    /// a Deployment, else the list's one selected row of them.
    var askWhyRef: KubeObjectRef? {
        if let detail { return Self.asksWhy(detail.ref) ? detail.ref : nil }
        guard selection.count == 1, let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id), Self.asksWhy(ref) else {
            return nil
        }
        return ref
    }

    /// Why Ask Why can't be asked about `ref` now; nil when it can. The
    /// detail's object, once read, says it exactly (`KubeTrouble.of`);
    /// else its row — a pod's Status, a Deployment's state off its cells.
    func askWhyUnavailable(_ ref: KubeObjectRef) -> String? {
        if askingWhy == ref { return "Reading what to tell the agent…" }
        if let detail, detail.ref == ref, let json = detail.object?.json { return KubeTrouble.notFailing(object: json) }
        guard model.kind.fullName == ref.kind.fullName, let row = model.rows[KubeRowID(namespace: ref.namespace, name: ref.name)] else { return nil }
        let columns = model.rows.columns
        if ref.isPod { return KubePodSummary(row: row, columns: columns).flatMap(KubeTrouble.notFailing) }
        return KubeTrouble.notFailing(KubeDeploymentHint(row: row, columns: columns), name: ref.name)
    }

    /// Ask an Agent Why… — the detail's button and the menu's item, greyed
    /// with why while the object isn't failing — as Docker's is.
    func askWhyVerb(for ref: KubeObjectRef) -> ResourceVerb? {
        guard Self.asksWhy(ref) else { return nil }
        return ResourceVerb(
            title: "Ask an Agent Why…", label: "Ask Why", symbol: "sparkles", place: .button, key: KubernetesKey.askWhy.key,
            unavailable: askWhyUnavailable(ref), group: 3
        ) { [weak self] in self?.askWhy(ref) }
    }

    /// The one row picked: its Ask Why.
    func askWhyVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return [askWhyVerb(for: ref)].compactMap { $0 }
    }

    /// `a` (and ⌘L over the page): Ask Why on `askWhyRef`. One that isn't
    /// failing says why over the list; false with nothing to ask about.
    @discardableResult
    func askWhy() -> Bool {
        guard let ref = askWhyRef else { return false }
        if let why = askWhyUnavailable(ref) {
            commandProblem = why
            return true
        }
        askWhy(ref)
        return true
    }

    /// A failing pod's row, its Ask Why button.
    func askWhy(row id: String) {
        guard let ref = ref(for: id) else { return }
        askWhy(ref)
    }

    /// The brief read — GETs through the context's proxy, no Secret, every
    /// word scrubbed (`KubeAgentBriefing`) — and handed to the Ask Agent
    /// sheet, which shows it whole before anything is sent. What couldn't
    /// be read is said over the list (or under the detail's buttons).
    func askWhy(_ ref: KubeObjectRef) {
        commandProblem = nil
        guard askingWhy == nil else { return }
        guard let client = model.client(for: ref.context) else {
            commandProblem = "Kubernetes is off, or \(ref.context) is no longer in the kubeconfig."
            return
        }
        let known = model.contexts.context(named: ref.context)
        let context = KubeBriefContext(name: ref.context, production: known?.isProduction ?? true, writable: known?.isWritable ?? false)
        let discovery = model.knownDiscovery(of: ref.context)
        askingWhy = ref
        Task { [weak self] in
            do {
                var brief = try await KubeAgentBriefing.brief(ref, client: client, context: context, discovery: discovery)
                // A checkout bound there — the selected tab's, else another's —:
                // its deployed commit, and its agent first (3.2, 3.4).
                if let namespace = brief.namespace,
                    let bound = KubeBindingStore.shared.binding(on: ref.context, namespace: namespace, preferring: self?.actions?.selectedBinding())
                {
                    brief = await KubeAgentBriefing.withDeployedCommit(brief, checkout: URL(fileURLWithPath: bound.checkout))
                }
                guard let self else { return }
                self.askingWhy = nil
                self.actions?.askWhy(brief)
            } catch {
                guard let self else { return }
                self.askingWhy = nil
                self.commandProblem =
                    (error as? KubeBriefProblem)?.description ?? "Couldn't read \(ref.kind.singular) \(ref.namespace.map { "\($0)/" } ?? "")\(ref.name): \(KubernetesModel.said(error))"
            }
        }
    }
}
