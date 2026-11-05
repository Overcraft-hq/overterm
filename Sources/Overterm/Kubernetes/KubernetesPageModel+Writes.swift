import Foundation

/// `=`: how many replicas, before the write is asked for.
struct KubeScaleDraft: Equatable {
    var ref: KubeObjectRef
    /// What the scale subresource says now; nil until read.
    var current: Int?
    var replicas: String = ""
    /// Why what is typed won't do.
    var problem: String?
}

/// What a write's reads found, carried from the access review to the
/// request: the verb as it stands (a toggle turned round), a scale's
/// replicas, the metadata, a trigger's Job, a namespace's counts.
struct KubeWriteFacts {
    var verb: KubeWriteVerb
    var meta: KubeObjectMeta?
    var from: Int?
    var to: Int?
    /// A trigger's Job: its name and the request that makes it.
    var job: String?
    var request: KubeWriteRequest?
    var contents: KubeNamespaceContents?
}

/// How a scale changes the replicas.
enum KubeScaleChange: Equatable {
    case by(Int)
    case to(Int)
}

// MARK: Writes (stage 2a — docs/design/kubernetes/analysis.md, Sections 2.4, 2.9 and 5)

/// Every write the page makes goes one way (`write`):
/// 1. the class check (`KubeWriteCheck`): only on a writable context — a
///    remote or local one's `writable` setting, production only with its
///    switch on for the session;
/// 2. the access review (SelfSubjectAccessReview through the context's
///    writable socket, `KubernetesModel.writeAccess`) — a no stops it;
/// 3. a metadata-only read where the confirmation needs one (a pod's
///    controller, the finalizers) or the scale subresource's replicas;
/// 4. the confirmation in the window naming the verb, the object, the
///    context and namespace, and the kubectl it equals; the name typed
///    where rule 4 asks it, checked here;
/// 5. the request (`KubeWrites`), its outcome said — the API's error in
///    plain words (`KubeWriteOutcome`). The list follows by its watch.
extension KubernetesPageModel {
    /// The verbs in the order a menu shows them.
    static let writeVerbOrder: [KubeWriteVerb] = [
        .restart, .scale, .pause, .resume, .trigger, .suspend, .unsuspend, .cordon, .uncordon, .recreate, .evict, .removeFinalizers, .forceDelete, .delete,
    ]

    /// What a write key means: the object the detail shows, while it
    /// shows one; else the list's one selected row.
    var writeTarget: KubeObjectRef? {
        if let detail { return detail.ref }
        guard selection.count == 1, let id = selection.first, rows.contains(where: { $0.id == id }) else { return nil }
        return ref(for: id)
    }

    /// One row picked: its writes.
    func writeVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return writeVerbs(for: ref)
    }

    /// The object's writes — its detail's buttons and its right-click
    /// menu — each greyed with why: a read-only context, production without
    /// its switch, the access review's no (asked as the verbs are shown).
    func writeVerbs(for ref: KubeObjectRef) -> [ResourceVerb] {
        guard let context = model.contexts.context(named: ref.context) else { return [] }
        return Self.writeVerbOrder.filter { KubeWriteCheck.offered($0, on: ref.kind) }.map { verb in
            let key: String? =
                switch verb {
                case .delete: KubernetesKey.delete.key
                case .restart, .recreate: KubernetesKey.restart.key
                case .scale: KubernetesKey.scaleTo.key
                case .pause, .resume, .suspend, .unsuspend: KubernetesKey.pause.key
                case .trigger: KubernetesKey.trigger.key
                case .cordon, .uncordon: KubernetesKey.cordon.key
                default: nil
                }
            let place: ResourceVerb.Place =
                switch verb {
                case .delete: .remove
                case .restart, .scale, .pause, .resume, .trigger, .suspend, .unsuspend, .cordon, .uncordon: .button
                default: .more
                }
            return ResourceVerb(
                title: verb.title, label: verb.label, symbol: verb.symbol, place: place, key: key, unavailable: writeUnavailable(verb, context, ref),
                group: 5
            ) { [weak self] in
                guard let self else { return }
                if verb == .scale { self.openScaleSheet(ref) } else { self.write(verb, on: ref) }
            }
        }
    }

    /// Why `verb` can't be done on the object now; nil when it can. Asks
    /// the access review when its answer isn't known.
    func writeUnavailable(_ verb: KubeWriteVerb, _ context: KubeContext, _ ref: KubeObjectRef) -> String? {
        let rule = KubeWriteCheck.rule(verb, for: context, kind: ref.kind)
        if let refused = rule.refused { return refused }
        if let (toggle, on) = verb.toggle, let state = knownState(toggle, of: ref), state == on {
            return toggle.already(on, KubeWriteOutcome.spoken(ref))
        }
        guard let access = rule.access else { return nil }
        let namespace = ref.namespace ?? ""
        let state = model.writeAccess.state(context.name, namespace: namespace, access)
        if state == .unknown { model.writeAccess.check(context, namespace: namespace, access) }
        return state.unavailable(access, namespace: namespace, review: true)
    }

    /// One row picked on a writable context: its verbs' reviews asked,
    /// so the menu is ready.
    func askWriteAccess(for ids: Set<String>) {
        guard ids.count == 1, let id = ids.first, let ref = ref(for: id), let context = model.contexts.context(named: ref.context),
            context.isWritable
        else { return }
        for verb in Self.writeVerbOrder where KubeWriteCheck.offered(verb, on: ref.kind) {
            if let access = KubeWriteCheck.rule(verb, for: context, kind: ref.kind).access {
                model.writeAccess.check(context, namespace: ref.namespace ?? "", access)
            }
        }
    }

    // MARK: Keys

    /// ⌫: delete the object.
    func deleteKey() -> Bool {
        guard let ref = writeTarget, KubeWriteCheck.offered(.delete, on: ref.kind) else { return false }
        write(.delete, on: ref)
        return true
    }

    /// `r`: a rollout restarted; a pod deleted so its controller makes it again.
    func restartKey() -> Bool {
        guard let ref = writeTarget else { return false }
        if KubeWriteCheck.offered(.recreate, on: ref.kind) {
            write(.recreate, on: ref)
        } else if KubeWriteCheck.offered(.restart, on: ref.kind) {
            write(.restart, on: ref)
        } else {
            return false
        }
        return true
    }

    /// `+`, `-`: by one; `=` (nil): the sheet.
    func scaleKey(_ change: KubeScaleChange?) -> Bool {
        guard let ref = writeTarget, KubeWriteCheck.offered(.scale, on: ref.kind) else { return false }
        if let change { write(.scale, on: ref, scale: change) } else { openScaleSheet(ref) }
        return true
    }

    /// `p`: a Deployment's rollout paused or resumed, a CronJob suspended
    /// or resumed — whichever it isn't, as far as is known now (a CronJob's
    /// row says; a Deployment's is read after its access review).
    func pauseKey() -> Bool {
        guard let ref = writeTarget else { return false }
        let pair: KubeWriteVerb
        if KubeWriteCheck.offered(.pause, on: ref.kind) {
            pair = .pause
        } else if KubeWriteCheck.offered(.suspend, on: ref.kind) {
            pair = .suspend
        } else {
            return false
        }
        toggleWrite(pair, on: ref)
        return true
    }

    /// `s`: a CronJob run now — a Job made from its template.
    func triggerKey() -> Bool {
        guard let ref = writeTarget, KubeWriteCheck.offered(.trigger, on: ref.kind) else { return false }
        write(.trigger, on: ref)
        return true
    }

    /// `u`: a node cordoned, or uncordoned if it is.
    func cordonKey() -> Bool {
        guard let ref = writeTarget, KubeWriteCheck.offered(.cordon, on: ref.kind) else { return false }
        toggleWrite(.cordon, on: ref)
        return true
    }

    /// `verb` or its opposite, by the state known now; either way turned
    /// round if the object read says otherwise (the access review is the
    /// same for both) — the row may be behind it: the watch's coalescing,
    /// a watch stale after sleep.
    private func toggleWrite(_ verb: KubeWriteVerb, on ref: KubeObjectRef) {
        guard let (toggle, on) = verb.toggle, let opposite = verb.opposite else { return write(verb, on: ref) }
        let state = knownState(toggle, of: ref)
        write(state == on ? opposite : verb, on: ref, toggles: true)
    }

    /// What the page already knows of a state: the row's cells, where the
    /// server's columns say it — they follow the watch. Not the detail's
    /// object: it is read once as the detail opens, and a pause from its
    /// own button would leave it saying the opposite.
    func knownState(_ toggle: KubeWriteToggle, of ref: KubeObjectRef) -> Bool? {
        guard ref.context == model.selectedName, ref.kind.fullName == model.kind.fullName,
            let row = model.rows[KubeRowID(namespace: ref.namespace, name: ref.name)]
        else { return nil }
        let columns = model.rows.columns
        var cells: [String: String] = [:]
        for name in ["Suspend", "Status"] { if let cell = row.cell(name, in: columns) { cells[name] = cell.text } }
        return toggle.state(cells: cells)
    }

    // MARK: The namespace sheet

    /// The namespaces kind as the context serves it (its verbs).
    var namespacesKind: KubeResourceKind {
        model.selectedName.flatMap { model.knownDiscovery(of: $0)?.kind("namespaces") } ?? .namespaces
    }

    /// `N`, the palette's New Namespace…: the sheet, on a context that
    /// may take one — refused with why on one that can't.
    @discardableResult
    func openNamespaceSheet() -> Bool {
        writeStatus = nil
        guard let context = model.selected else { return false }
        if let refused = KubeWriteCheck.rule(.createNamespace, for: context, kind: namespacesKind).refused {
            writeStatus = .failed(refused)
            return true
        }
        namespaceDraft = KubeNamespaceDraft(context: context.name)
        return true
    }

    func closeNamespaceSheet() {
        namespaceDraft = nil
        giveListTheKeyboard()
    }

    /// The sheet's Create: a DNS label — then the write's own confirmation.
    func confirmNamespace() {
        guard let draft = namespaceDraft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if let problem = KubeNamespaceName.problem(name) {
            namespaceDraft?.problem = problem
            return
        }
        namespaceDraft = nil
        giveListTheKeyboard()
        write(.createNamespace, on: KubeObjectRef(context: draft.context, kind: namespacesKind, namespace: nil, name: name))
    }

    // MARK: The scale sheet

    func openScaleSheet(_ ref: KubeObjectRef) {
        writeStatus = nil
        guard let context = model.contexts.context(named: ref.context) else { return }
        if let refused = KubeWriteCheck.rule(.scale, for: context, kind: ref.kind).refused {
            writeStatus = .failed(refused)
            return
        }
        scaleDraft = KubeScaleDraft(ref: ref)
        guard let client = model.client(for: ref.context) else { return }
        Task { [weak self] in
            let current = try? await client.replicas(ref)
            guard let self, self.scaleDraft?.ref == ref, self.scaleDraft?.current == nil else { return }
            self.scaleDraft?.current = current
            if self.scaleDraft?.replicas.isEmpty == true, let current { self.scaleDraft?.replicas = String(current) }
        }
    }

    func closeScaleSheet() {
        scaleDraft = nil
        giveListTheKeyboard()
    }

    /// The sheet's Scale: a whole number, 0 to 10,000 — then the write's
    /// own confirmation.
    func confirmScale() {
        guard let draft = scaleDraft else { return }
        guard let replicas = Int(draft.replicas.trimmingCharacters(in: .whitespaces)), (0...10_000).contains(replicas) else {
            scaleDraft?.problem = "A whole number of replicas, 0 to 10000."
            return
        }
        scaleDraft = nil
        giveListTheKeyboard()
        write(.scale, on: draft.ref, scale: .to(replicas))
    }

    // MARK: The guard path

    /// `verb` on the object, by the one path every write takes. `toggles`:
    /// a key's pause, suspend or cordon, turned to its opposite when the
    /// object read says it is so already. While another write is between
    /// its key and its confirmation, nothing.
    func write(_ verb: KubeWriteVerb, on ref: KubeObjectRef, scale: KubeScaleChange? = nil, toggles: Bool = false) {
        guard writeChecking == nil else { return }
        writeStatus = nil
        guard let context = model.contexts.context(named: ref.context) else {
            writeStatus = .failed("No context called \(ref.context).")
            return
        }
        let first = KubeWriteCheck.rule(verb, for: context, kind: ref.kind)
        if let refused = first.refused {
            writeStatus = .failed(refused)
            return
        }
        guard let client = model.client(for: ref.context) else {
            writeStatus = .failed("Kubernetes is off, or the context is gone.")
            return
        }
        let namespace = ref.namespace ?? ""
        let object = KubeWriteOutcome.spoken(ref)
        let discovery = model.knownDiscovery(of: ref.context)
        let suffix = jobSuffix
        writeChecks += 1
        let token = writeChecks
        writeChecking = token
        writeStatus = .working("Checking… \(object)")
        Task { [weak self] in
            defer { self?.endChecking(token) }
            // The access review first: nothing is read or asked before it says yes.
            if let access = first.access {
                let answer = await self?.model.writeAccess.answer(context, namespace: namespace, access) ?? .failed("")
                guard let self else { return }
                if let why = KubeAccessState.answered(answer).unavailable(access, namespace: namespace, review: true) {
                    self.writeStatus = .failed(why)
                    return
                }
            }
            // What the confirmation says: metadata only (never a Secret's
            // values), the replicas, a state's spec field, a CronJob's
            // template, a namespace's counts.
            var facts = KubeWriteFacts(verb: verb)
            do {
                switch verb {
                case .recreate, .removeFinalizers: facts.meta = try await client.metadata(ref)
                case .scale:
                    let current = try await client.replicas(ref)
                    facts.from = current
                    switch scale {
                    case .by(let step): facts.to = max(0, current + step)
                    case .to(let count): facts.to = count
                    case nil: facts.to = current
                    }
                case .pause, .resume, .suspend, .unsuspend, .cordon, .uncordon:
                    guard let (toggle, on) = verb.toggle else { break }
                    if toggle.state(of: try await client.spec(ref)) == on {
                        // Its access review is the opposite's too.
                        guard toggles, let opposite = verb.opposite else {
                            self?.writeStatus = .failed(toggle.already(on, object))
                            return
                        }
                        facts.verb = opposite
                    }
                case .trigger:
                    let job = KubeWrites.manualJobName(ref.name, suffix: suffix())
                    guard let request = KubeWrites.trigger(ref, cronJob: try await client.spec(ref), job: job) else {
                        self?.writeStatus = .failed("\(object) has no jobTemplate to make a Job from.")
                        return
                    }
                    facts.job = job
                    facts.request = request
                case .delete where KubeWriteCheck.isNamespace(ref.kind):
                    facts.contents = await client.contents(of: ref.name, discovery: discovery)
                default: break
                }
            } catch {
                self?.writeStatus = .failed("Couldn't read \(object): \(KubernetesModel.said(error))")
                return
            }
            guard let self else { return }
            if verb == .removeFinalizers, facts.meta?.finalizers.isEmpty == true {
                self.writeStatus = .failed("\(object) has no finalizers.")
                return
            }
            if verb == .scale, let from = facts.from, from == facts.to {
                self.writeStatus = .failed("\(object) has \(from) replicas already.")
                return
            }
            self.endChecking(token)
            self.confirm(ref, facts)
        }
    }

    private func endChecking(_ token: Int) {
        if writeChecking == token { writeChecking = nil }
    }

    /// The confirmation, made against the context as it stands now (its
    /// switch may have changed while the review was asked).
    private func confirm(_ ref: KubeObjectRef, _ facts: KubeWriteFacts) {
        guard let context = model.contexts.context(named: ref.context) else {
            writeStatus = .failed("The context is gone: nothing was changed.")
            return
        }
        let rule = KubeWriteCheck.rule(facts.verb, for: context, kind: ref.kind, replicas: facts.to)
        if let refused = rule.refused {
            writeStatus = .failed(refused)
            return
        }
        writeStatus = nil
        let confirmation = KubeWriteConfirmation.make(
            facts.verb, ref, context: context, rule: rule, from: facts.from, to: facts.to, meta: facts.meta, job: facts.job, contents: facts.contents,
            discovery: model.knownDiscovery(of: ref.context))
        actions?.confirmWrite(confirmation) { [weak self] typed in
            guard let self else { return }
            guard confirmation.accepts(typed) else {
                self.writeStatus = .failed("The name typed wasn't \(confirmation.typedName ?? ref.name): nothing was changed.")
                return
            }
            self.send(ref, facts)
        }
    }

    /// The request, through the context as it is now: writes turned off
    /// while the confirmation showed stop it here (and at the proxies).
    private func send(_ ref: KubeObjectRef, _ facts: KubeWriteFacts) {
        let verb = facts.verb
        guard let context = model.contexts.context(named: ref.context), let client = model.client(for: ref.context) else {
            writeStatus = .failed("The context is gone: nothing was changed.")
            return
        }
        if let refused = KubeWriteCheck.rule(verb, for: context, kind: ref.kind, replicas: facts.to).refused {
            writeStatus = .failed(refused)
            return
        }
        let request: KubeWriteRequest
        switch verb {
        case .delete, .recreate: request = KubeWrites.delete(ref)
        case .forceDelete: request = KubeWrites.delete(ref, gracePeriod: 0)
        case .removeFinalizers: request = KubeWrites.removeFinalizers(ref, finalizers: facts.meta?.finalizers ?? [])
        case .evict: request = KubeWrites.evict(ref)
        case .restart: request = KubeWrites.restart(ref, at: clock())
        case .scale: request = KubeWrites.scale(ref, replicas: facts.to ?? 0)
        case .pause, .resume, .suspend, .unsuspend, .cordon, .uncordon:
            guard let (toggle, on) = verb.toggle else { return }
            request = KubeWrites.toggle(ref, toggle, on: on)
        case .trigger:
            guard let made = facts.request else { return }
            request = made
        case .createNamespace: request = KubeWrites.createNamespace(ref)
        }
        writeStatus = .working("\(verb.label)… \(KubeWriteOutcome.spoken(ref))")
        Task { [weak self] in
            do {
                try await client.write(request)
                self?.writeStatus = .done(KubeWriteOutcome.done(verb, ref, from: facts.from, replicas: facts.to, job: facts.job))
            } catch {
                self?.writeStatus = .failed(KubeWriteOutcome.failed(verb, ref, error))
            }
        }
    }

    // MARK: Production's switch (rule 2)

    /// Whether the context shown is production with its writes on.
    var productionWritesOn: Bool { model.selected?.sessionWrites == true }

    /// The context card's Allow Writes Until Quit: asked first, naming the
    /// context; its proxy then runs without the method filter.
    func allowProductionWrites() {
        guard let context = model.selected, context.isProduction, !context.sessionWrites else { return }
        actions?.confirm(
            "Allow writes to \(context.displayName) until you quit?",
            "PRODUCTION · \(context.name)\nOverterm's page may then change objects in this cluster: each change is still asked first, naming the "
                + "context and namespace, and a destructive one asks for the object's name. Its socket stops refusing writes until Overterm quits or "
                + "you turn writes off. Agents get no write tool from this.",
            "Allow Writes Until Quit"
        ) { [weak self] in
            guard let self else { return }
            Task { await self.model.setProductionWrites(true, for: context.name) }
        }
    }

    /// Writes off again: the proxy back to refusing them.
    func endProductionWrites() {
        guard let context = model.selected, context.sessionWrites else { return }
        writeStatus = nil
        Task { await model.setProductionWrites(false, for: context.name) }
    }
}
