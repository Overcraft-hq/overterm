import Foundation

// MARK: Ask Why (stage 1e; docs/design/kubernetes/analysis.md, 3.4)

extension KubernetesPageModel {
    /// Whether a ref is something Ask Why asks about: a pod, a Deployment,
    /// an Argo CD Application or ApplicationSet, a Flux Kustomization or
    /// HelmRelease (gitops.md 6.2).
    static func asksWhy(_ ref: KubeObjectRef) -> Bool {
        ref.isPod || (ref.kind.group == "apps" && ref.kind.kind == "Deployment" && ref.namespace != nil)
            || (KubeGitOpsDetail.isGitOps(ref.kind) && ref.namespace != nil)
    }

    /// What `a` and ⌘L act on: the detail's object while it shows one Ask
    /// Why asks about, else the GitOps section's one row picked, else the
    /// list's one selected row of them.
    var askWhyRef: KubeObjectRef? {
        if let detail { return Self.asksWhy(detail.ref) ? detail.ref : nil }
        if section == .gitops { return gitOpsSelectedRef.flatMap { Self.asksWhy($0) ? $0 : nil } }
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
        if KubeGitOpsDetail.isGitOps(ref.kind) { return gitOpsAskWhyUnavailable(ref) }
        if let detail, detail.ref == ref, let json = detail.object?.json { return KubeTrouble.notFailing(object: json) }
        guard model.kind.fullName == ref.kind.fullName, let row = model.rows[KubeRowID(namespace: ref.namespace, name: ref.name)] else { return nil }
        let columns = model.rows.columns
        if ref.isPod { return KubePodSummary(row: row, columns: columns).flatMap(KubeTrouble.notFailing) }
        return KubeTrouble.notFailing(KubeDeploymentHint(row: row, columns: columns), name: ref.name)
    }

    /// A GitOps object's: offered while it is Failed, Blocked or Stuck —
    /// as the detail's read says, else the section's row, else its own
    /// list's cells (which can't tell Blocked or Stuck: offered unless
    /// they say Ready, the brief saying so if it isn't failing).
    private func gitOpsAskWhyUnavailable(_ ref: KubeObjectRef) -> String? {
        let now = Date()
        if let detail, detail.ref == ref, let read = detail.gitOps {
            let verdict = read.verdict(peers: gitOps.peers(context: ref.context), now: now)
            return KubeGitOpsDetail.notAsked(read.object, state: verdict.state, why: verdict.why)
        }
        let id = KubeGitOpsRow.id(resource: ref.kind.fullName, KubeRowID(namespace: ref.namespace, name: ref.name))
        if gitOps.context == ref.context, let row = (gitOps.rows.shown + gitOps.rows.notPlaced).first(where: { $0.id == id }) {
            guard !row.state.isProblem else { return nil }
            return "\(row.key.kind) \(row.ref.description) is \(row.state.word) (\(row.why)): Ask Why is for one that is Failed, Blocked or Stuck."
        }
        guard model.kind.fullName == ref.kind.fullName, let row = model.rows[KubeRowID(namespace: ref.namespace, name: ref.name)] else { return nil }
        let (state, said) = KubeGitOpsSection.cellState(resource: ref.kind.fullName, row, columns: model.rows.columns)
        guard state == .ready else { return nil }
        return "\(ref.kind.kind) \(KubeRowID(namespace: ref.namespace, name: ref.name).description) is Ready (\(said)): Ask Why is for one that is Failed, Blocked or Stuck."
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
    /// word scrubbed (`KubeAgentBriefing`), its usage where cheap
    /// (`KubeMCP.usagePart`, bounded by `usageLimit`) — and handed to the Ask Agent
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
        if KubeGitOpsDetail.isGitOps(ref.kind) {
            // Its chain from the section's summaries, what they lack read by a GET each.
            let peers = gitOps.peers(context: ref.context)
            Task { [weak self] in
                do {
                    let brief = try await KubeAgentBriefing.gitOps(ref, client: client, context: context, discovery: discovery, peers: peers)
                    guard let self else { return }
                    self.askingWhy = nil
                    self.actions?.askWhy(brief)
                } catch {
                    guard let self else { return }
                    self.askingWhy = nil
                    self.commandProblem =
                        (error as? KubeBriefProblem)?.description ?? "Couldn't read \(ref.kind.kind) \(ref.namespace.map { "\($0)/" } ?? "")\(ref.name): \(KubernetesModel.said(error))"
                }
            }
            return
        }
        Task { [weak self] in
            do {
                let read = try await KubeAgentBriefing.read(ref, client: client, context: context, discovery: discovery)
                var brief = read.brief
                // A checkout bound there — the selected tab's, else another's —:
                // its deployed commit, and its agent first (3.2, 3.4).
                if let namespace = brief.namespace,
                    let bound = KubeBindingStore.shared.binding(on: ref.context, namespace: namespace, preferring: self?.actions?.selectedBinding())
                {
                    brief = await KubeAgentBriefing.withDeployedCommit(brief, checkout: URL(fileURLWithPath: bound.checkout))
                }
                // Its usage over the last hour, where that is cheap (metrics.md 7): from what the brief read, within `usageLimit`.
                if let model = self?.model, let usage = await KubeMCP.usagePart(for: ref, reads: read.reads, kubernetes: model) { brief.parts.append(usage) }
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

// MARK: Ask Agent About This Chart (metrics.md 3.9; stage M11)

extension KubernetesPageModel {
    /// A chart's "Ask Agent About This Chart": the chart as `k8s_metrics`
    /// says it (`KubeMetricsText.about`) — its object and context first,
    /// every word through `Secrets` — in the Ask Agent sheet, shown whole
    /// before anything is sent. Nothing is read for it: what the chart
    /// already holds. Nil with no detail's Metrics tab.
    @discardableResult
    func askAboutChart(_ chart: KubePodCharts.Chart, caption: String?, now: Date = Date()) -> KubeAgentBrief? {
        guard let detail, metricsTabShows else { return nil }
        let ref = detail.ref
        // A pod's chart: its section's container, as Expand has it.
        var label = chart.data.title
        if ref.isPod, let charts = podCharts(of: ref, object: detail.object),
            let section = charts.sections.first(where: { $0.charts.contains { $0.id == chart.id } })
        {
            label = "\(KubeMetricsText.name(section.container)) · \(chart.data.title)"
        } else if ref.isPod {
            label = "pod · \(chart.data.title)"
        }
        let known = model.contexts.context(named: ref.context)
        let context = KubeBriefContext(name: ref.context, production: known?.isProduction ?? true, writable: known?.isWritable ?? false)
        let whose = "\(ref.kind.singular) \(ref.namespace.map { "\($0)/" } ?? "")\(KubeMetricsText.name(ref.name)) on \(context.said)"
        let text = KubeMCPText.scrubbed(KubeMetricsText.about(chart.data, label: label, whose: whose, caption: caption, chips: chart.chips, now: now))
        let subject = "\(chart.data.title) of \(ref.kind.singular)/\(KubeMetricsText.name(ref.name))"
        let brief = KubeAgentBrief(
            message: "Here is a chart of \(ref.kind.singular) \(ref.namespace.map { "\($0)/" } ?? "")\(ref.name): what does it say, and is anything wrong?",
            subject: KubeMCPText.scrubbed(subject), text: text, parts: [], production: context.production, context: ref.context, namespace: ref.namespace)
        actions?.askWhy(brief)
        return brief
    }
}
