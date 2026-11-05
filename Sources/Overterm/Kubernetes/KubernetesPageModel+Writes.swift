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
    static let writeVerbOrder: [KubeWriteVerb] = [.restart, .scale, .recreate, .evict, .removeFinalizers, .forceDelete, .delete]

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
                default: nil
                }
            let place: ResourceVerb.Place =
                switch verb {
                case .delete: .remove
                case .restart, .scale: .button
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

    /// `verb` on the object, by the one path every write takes.
    func write(_ verb: KubeWriteVerb, on ref: KubeObjectRef, scale: KubeScaleChange? = nil) {
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
        Task { [weak self] in
            // The access review first: nothing is read or asked before it says yes.
            if let access = first.access {
                let answer = await self?.model.writeAccess.answer(context, namespace: namespace, access) ?? .failed("")
                guard let self else { return }
                if let why = KubeAccessState.answered(answer).unavailable(access, namespace: namespace, review: true) {
                    self.writeStatus = .failed(why)
                    return
                }
            }
            // What the confirmation says: metadata only (never a Secret's values), or the replicas.
            var meta: KubeObjectMeta?
            var from: Int?
            var to: Int?
            do {
                switch verb {
                case .recreate, .removeFinalizers: meta = try await client.metadata(ref)
                case .scale:
                    let current = try await client.replicas(ref)
                    from = current
                    switch scale {
                    case .by(let step): to = max(0, current + step)
                    case .to(let count): to = count
                    case nil: to = current
                    }
                default: break
                }
            } catch {
                self?.writeStatus = .failed("Couldn't read \(object): \(KubernetesModel.said(error))")
                return
            }
            guard let self else { return }
            if verb == .removeFinalizers, meta?.finalizers.isEmpty == true {
                self.writeStatus = .failed("\(object) has no finalizers.")
                return
            }
            if verb == .scale, let from, from == to {
                self.writeStatus = .failed("\(object) has \(from) replicas already.")
                return
            }
            self.confirm(verb, ref, from: from, to: to, meta: meta)
        }
    }

    /// The confirmation, made against the context as it stands now (its
    /// switch may have changed while the review was asked).
    private func confirm(_ verb: KubeWriteVerb, _ ref: KubeObjectRef, from: Int?, to: Int?, meta: KubeObjectMeta?) {
        guard let context = model.contexts.context(named: ref.context) else { return }
        let rule = KubeWriteCheck.rule(verb, for: context, kind: ref.kind, replicas: to)
        if let refused = rule.refused {
            writeStatus = .failed(refused)
            return
        }
        let confirmation = KubeWriteConfirmation.make(
            verb, ref, context: context, rule: rule, from: from, to: to, meta: meta, discovery: model.knownDiscovery(of: ref.context))
        actions?.confirmWrite(confirmation) { [weak self] typed in
            guard let self else { return }
            guard confirmation.accepts(typed) else {
                self.writeStatus = .failed("The name typed wasn't \(confirmation.typedName ?? ref.name): nothing was changed.")
                return
            }
            self.send(verb, ref, from: from, to: to, meta: meta)
        }
    }

    /// The request, through the context as it is now: writes turned off
    /// while the confirmation showed stop it here (and at the proxies).
    private func send(_ verb: KubeWriteVerb, _ ref: KubeObjectRef, from: Int?, to: Int?, meta: KubeObjectMeta?) {
        guard let context = model.contexts.context(named: ref.context), let client = model.client(for: ref.context) else {
            writeStatus = .failed("The context is gone: nothing was changed.")
            return
        }
        if let refused = KubeWriteCheck.rule(verb, for: context, kind: ref.kind, replicas: to).refused {
            writeStatus = .failed(refused)
            return
        }
        let request: KubeWriteRequest =
            switch verb {
            case .delete, .recreate: KubeWrites.delete(ref)
            case .forceDelete: KubeWrites.delete(ref, gracePeriod: 0)
            case .removeFinalizers: KubeWrites.removeFinalizers(ref, finalizers: meta?.finalizers ?? [])
            case .evict: KubeWrites.evict(ref)
            case .restart: KubeWrites.restart(ref, at: clock())
            case .scale: KubeWrites.scale(ref, replicas: to ?? 0)
            }
        writeStatus = .working("\(verb.label)… \(KubeWriteOutcome.spoken(ref))")
        Task { [weak self] in
            do {
                try await client.write(request)
                self?.writeStatus = .done(KubeWriteOutcome.done(verb, ref, from: from, replicas: to))
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
