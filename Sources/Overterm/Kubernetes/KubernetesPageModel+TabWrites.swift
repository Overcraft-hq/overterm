import Foundation

// MARK: Writes in a tab (stage 2a, part 3 — docs/design/kubernetes/analysis.md, Sections 2.4, 2.9, 2.15 and 5)

/// Drain, rollback, debug, a node's shell — and Argo CD's sync and Flux's
/// reconcile with its source, argocd's and flux's (stage 4) — are processes in a terminal tab, not
/// requests (`KubeTabWrite`). Each goes one way (`runTabWrite`), as the
/// page's writes do:
/// 1. the process class check (`KubeProcessCheck`): refused on a
///    read-only context — any class set `writable: false`; a node shell also needs the
///    context's `nodeShell`;
/// 2. the access review of what the command does (SelfSubjectAccessReview
///    through the context's writable socket, `KubernetesModel.writeAccess`);
/// 3. what it needs read: a pod's containers (one picked when several), a
///    Deployment's ReplicaSets (a revision picked, each with its image),
///    the namespace of Argo CD's argocd-cm (a sync's pin), a Flux object's
///    sources — and what those add reviewed in turn;
/// 4. the confirmation in the window naming the context and namespace and
///    the command; the name typed where rule 4 says, checked here;
/// 5. the class check again against the context as it is now, then the
///    command typed into a new tab pinned to the context — in a scenario,
///    recorded instead (`kubernetesCommandRecorder`).
extension KubernetesPageModel {
    static let contextChanged = "The context changed while it was asked: nothing was run."

    /// The object's tab writes — its detail's buttons and its right-click
    /// menu — each greyed with why: a read-only context, the access
    /// review's no (asked as they are shown).
    func tabWriteVerbs(for ref: KubeObjectRef) -> [ResourceVerb] {
        guard let context = model.contexts.context(named: ref.context) else { return [] }
        return KubeTabWrite.verbs.filter { KubeTabWrite.offered($0, on: ref.kind) }.map { verb in
            ResourceVerb(
                title: KubeTabWrite.title(verb), label: KubeTabWrite.label(verb), symbol: KubeTabWrite.symbol(verb), place: .more,
                key: verb == .debug || verb == .nodeShell ? KubernetesKey.debug.key : verb == .argoSync ? KubernetesKey.trigger.key : nil, unavailable: tabWriteUnavailable(verb, context, ref),
                group: 6
            ) { [weak self] in self?.runTabWrite(verb, on: ref) }
        }
    }

    func tabWriteVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return tabWriteVerbs(for: ref)
    }

    /// The namespace a tab write's command and tab name: the object's;
    /// for a node, the one shown, else the context's own.
    func tabNamespace(for ref: KubeObjectRef, in context: KubeContext) -> String {
        ref.namespace ?? shownNamespace ?? context.namespace ?? "default"
    }

    /// Why `verb` can't be done on the object now; nil when it can.
    func tabWriteUnavailable(_ verb: KubeProcessVerb, _ context: KubeContext, _ ref: KubeObjectRef) -> String? {
        if let refused = KubeProcessCheck.rule(verb, for: context).refused { return refused }
        for (access, namespace) in KubeTabWrite.accesses(verb, namespace: tabNamespace(for: ref, in: context), kind: ref.kind) {
            let place = namespace ?? ""
            let state = model.writeAccess.state(context.name, namespace: place, access)
            if state == .unknown { model.writeAccess.check(context, namespace: place, access) }
            if let why = state.unavailable(access, namespace: place, review: true) { return why }
        }
        return nil
    }

    /// `E`: a debug container in the pod, or a shell on the node — the
    /// detail's object while it shows one, else the list's selected row.
    func debugKey() -> Bool {
        guard let ref = writeTarget else { return false }
        if KubeTabWrite.offered(.debug, on: ref.kind) {
            runTabWrite(.debug, on: ref)
        } else if KubeTabWrite.offered(.nodeShell, on: ref.kind) {
            runTabWrite(.nodeShell, on: ref)
        } else {
            return false
        }
        return true
    }

    /// `verb` on the object, by the one path every tab write takes.
    func runTabWrite(_ verb: KubeProcessVerb, on ref: KubeObjectRef) {
        guard writeChecking == nil else { return }
        writeStatus = nil
        guard let context = model.contexts.context(named: ref.context) else {
            writeStatus = .failed("No context called \(ref.context).")
            return
        }
        guard KubeTabWrite.offered(verb, on: ref.kind) else {
            writeStatus = .failed("\(KubeWriteOutcome.spoken(ref)) has no \(KubeTabWrite.label(verb).lowercased()).")
            return
        }
        if let refused = KubeProcessCheck.rule(verb, for: context).refused {
            writeStatus = .failed(refused)
            return
        }
        guard let client = model.client(for: ref.context) else {
            writeStatus = .failed("Kubernetes is off, or the context is gone.")
            return
        }
        let namespace = tabNamespace(for: ref, in: context)
        let image = model.debugImage(for: context)
        let nodeImage = model.nodeShellImage(for: context)
        let object = KubeWriteOutcome.spoken(ref)
        let replicaSets = model.knownDiscovery(of: ref.context)?.kind("rs") ?? .replicaSets
        writeChecks += 1
        let token = writeChecks
        writeChecking = token
        writeStatus = .working("Checking… \(object)")
        Task { [weak self] in
            defer { self?.endChecking(token) }
            // The access review first: nothing is read or asked before it says yes.
            guard await self?.reviewTabWrite(KubeTabWrite.accesses(verb, namespace: namespace, kind: ref.kind), in: context) == true else { return }
            switch verb {
            case .drain:
                self?.endChecking(token)
                self?.confirmTabWrite(.drain(node: ref.name, namespace: namespace), reviewed: context, pin: namespace)
            case .argoSync:
                // Core mode reads Argo CD's settings in the context's namespace: the tab is
                // pinned to Argo CD's own, found by its argocd-cm, which may not be the
                // Application's (apps in any namespace).
                let configMaps = self?.model.knownDiscovery(of: ref.context)?.kind("cm") ?? KubeHelm.configMaps
                let named = KubeListOptions(fieldSelector: "metadata.name=" + KubeGitOps.argoConfigMap)
                var installs: [String] = []
                if let table = try? await client.list(configMaps, in: .all, options: named) {
                    installs = table.rows.compactMap(\.id.namespace)
                } else if let table = try? await client.list(configMaps, in: .namespace(namespace), options: named) {
                    installs = table.rows.isEmpty ? [] : [namespace]
                }
                let write = KubeTabWrite.argoSync(
                    app: ref.name, namespace: namespace, controlPlane: KubeGitOps.argoNamespace(installs: installs, application: namespace))
                guard case .argoSync(_, _, let controlPlane) = write, await self?.reviewTabWrite(write.accesses, in: context) == true else { return }
                self?.endChecking(token)
                self?.confirmTabWrite(write, reviewed: context, pin: controlPlane)
            case .fluxReconcile:
                guard let flux = KubeGitOps.flux(ref.kind) else { return }
                // flux annotates the object's source before the object: read it for which, and review that too.
                var sources: [KubeGitOps.FluxSource]
                do {
                    let json = try await client.object(ref.kind, namespace: namespace, name: ref.name).json
                    guard let found = KubeGitOps.sources(of: json, resource: ref.kind.fullName) else {
                        self?.writeStatus = .failed("\(object) names no source flux can fetch: nothing was run.")
                        return
                    }
                    sources = found
                } catch {
                    self?.writeStatus = .failed("Couldn't read \(object): \(KubernetesModel.said(error))")
                    return
                }
                // A chart given by chartRef: its own source is the chart's to say.
                if sources.count == 1, let chart = sources.first, chart.kind == "HelmChart",
                    let kind = self?.model.knownDiscovery(of: ref.context)?.kinds.first(where: { $0.fullName == chart.resource }),
                    let json = try? await client.object(kind, namespace: chart.namespace, name: chart.name).json
                {
                    sources += KubeGitOps.chartSources(of: json, at: chart.namespace)
                }
                let write = KubeTabWrite.fluxReconcile(
                    words: flux.words, resource: ref.kind.fullName, name: ref.name, namespace: namespace, sources: sources)
                guard await self?.reviewTabWrite(write.accesses, in: context) == true else { return }
                self?.endChecking(token)
                self?.confirmTabWrite(write, reviewed: context, pin: namespace)
            case .nodeShell:
                self?.endChecking(token)
                self?.confirmTabWrite(.nodeShell(node: ref.name, namespace: namespace, image: nodeImage), reviewed: context, pin: namespace)
            case .debug:
                let pick: KubeContainerPick
                do {
                    pick = KubeContainerPick.of(try await client.object(ref.kind, namespace: namespace, name: ref.name).json, for: .shell)
                } catch {
                    self?.writeStatus = .failed("Couldn't read \(object): \(KubernetesModel.said(error))")
                    return
                }
                guard let self else { return }
                self.endChecking(token)
                self.writeStatus = nil
                self.pickContainer(pick, of: ref.name, namespace: namespace, in: context) { [weak self] container in
                    self?.confirmTabWrite(
                        .debug(pod: ref.name, namespace: namespace, container: container, image: image), reviewed: context, pin: namespace)
                }
            case .rolloutUndo:
                let revisions: [KubeRevision]
                do {
                    let deployment = try await client.object(ref.kind, namespace: namespace, name: ref.name).json
                    let selector = KubeForwardResolve.labelSelector(KubeAgentText.map(deployment["spec"])["selector"] as? [String: Any])
                    guard let selector else {
                        self?.writeStatus = .failed("\(object) has no selector to find its ReplicaSets by.")
                        return
                    }
                    let path = KubePath.query(replicaSets.path(namespace: namespace), [("labelSelector", selector), ("limit", "100")])
                    revisions = KubeRevision.of(KubeAgentBriefing.items(try await client.get(path).body), deployment: deployment)
                } catch {
                    self?.writeStatus = .failed("Couldn't read \(object)'s history: \(KubernetesModel.said(error))")
                    return
                }
                guard let self else { return }
                self.endChecking(token)
                let choices = KubeRevision.choices(revisions)
                guard !choices.isEmpty else {
                    self.writeStatus = .failed("\(object) has no earlier revision to roll back to.")
                    return
                }
                self.writeStatus = nil
                let now = self.clock()
                self.actions?.choose(
                    "Roll back to which revision?",
                    "Deployment \(namespace)/\(ref.name) in \(context.displayName), at revision "
                        + (revisions.first(where: \.current).map { String($0.revision) } ?? "?") + " now. Each kept revision, newest first.",
                    choices.map { $0.label(now: now) }
                ) { [weak self] index in
                    guard choices.indices.contains(index) else { return }
                    let chosen = choices[index]
                    self?.confirmTabWrite(
                        .rolloutUndo(deployment: ref.name, namespace: namespace, revision: chosen.revision, images: chosen.images), reviewed: context,
                        pin: namespace)
                }
            default:
                self?.writeStatus = .failed("\(verb.title) isn't a write Overterm runs in a tab.")
            }
        }
    }

    /// Each access reviewed in turn (answers kept a minute, so asking one
    /// again is free); false, with why said, at the first no.
    private func reviewTabWrite(_ accesses: [(access: KubeAccess, namespace: String?)], in context: KubeContext) async -> Bool {
        for (access, place) in accesses {
            let answer = await model.writeAccess.answer(context, namespace: place ?? "", access)
            if let why = KubeAccessState.answered(answer).unavailable(access, namespace: place ?? "", review: true) {
                writeStatus = .failed(why)
                return false
            }
        }
        return true
    }

    private func pickContainer(
        _ pick: KubeContainerPick, of pod: String, namespace: String, in context: KubeContext, then: @escaping (String?) -> Void
    ) {
        switch pick {
        case .none: then(nil)
        case .one(let container): then(container)
        case .several(let containers, let chosen):
            actions?.choose(
                "Debug which container?", "The debug container sees its processes — pod \(namespace)/\(pod) in \(context.displayName).",
                containers.map { $0 == chosen ? "\($0) (default)" : $0 }
            ) { index in
                guard containers.indices.contains(index) else { return }
                then(containers[index])
            }
        }
    }

    /// Asked in the window, against the context as it stands now — the
    /// same cluster, user and class as `reviewed`, the one the access
    /// review answered for; the name typed checked here; then the command,
    /// checked once more against the context as it is after the answer
    /// (still the cluster reviewed: the tab's kubectl reaches it by name),
    /// typed into a tab pinned to the context in `pin`.
    func confirmTabWrite(_ write: KubeTabWrite, reviewed: KubeContext, pin: String) {
        confirmTabCommand(write, reviewed: reviewed, pin: pin)
    }

    /// `confirmTabWrite`'s path, for any write a tab runs (helm's too).
    func confirmTabCommand(_ write: some KubeTabCommand, reviewed: KubeContext, pin: String) {
        let name = reviewed.name
        guard let context = model.contexts.context(named: name) else {
            writeStatus = .failed("The context is gone: nothing was run.")
            return
        }
        guard KubernetesModel.sameAccess(reviewed, context) else {
            writeStatus = .failed(KubernetesPageModel.contextChanged)
            return
        }
        let rule = KubeProcessCheck.rule(write.verb, for: context)
        if let refused = rule.refused {
            writeStatus = .failed(refused)
            return
        }
        let confirmation = write.confirmation(context: context, rule: rule)
        actions?.confirmWrite(confirmation) { [weak self] answer in
            guard let self else { return }
            guard confirmation.accepts(answer.typed) else {
                self.writeStatus = .failed("The name typed wasn't \(confirmation.typedName ?? write.name): nothing was run.")
                return
            }
            // The image field's, checked as an image reference: the settings' only prefilled it.
            // Another one than the line showed is asked again with its own line (rule 3: the
            // command confirmed is the command run), the name typed again on production.
            if let prefilled = write.image {
                switch KubeTabWrite.image(from: answer.image ?? prefilled) {
                case .success(let image) where image != prefilled:
                    self.confirmTabCommand(write.with(image: image), reviewed: reviewed, pin: pin)
                    return
                case .success: break
                case .failure(let refused):
                    self.writeStatus = .failed(refused.reason)
                    return
                }
            }
            // Writes turned off, or the name now another cluster or user, while it asked stop it here.
            guard let now = self.model.contexts.context(named: name) else {
                self.writeStatus = .failed("The context is gone: nothing was run.")
                return
            }
            guard KubernetesModel.sameAccess(reviewed, now) else {
                self.writeStatus = .failed(KubernetesPageModel.contextChanged)
                return
            }
            do {
                let command = try KubeCommands.command(write, in: now)
                self.writeStatus = .done(write.opened(context: now.name))
                self.actions?.runInTab(command, now, pin)
            } catch {
                self.writeStatus = .failed("\(error)")
            }
        }
    }
}
