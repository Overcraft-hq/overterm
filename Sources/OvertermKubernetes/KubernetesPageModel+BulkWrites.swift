import Foundation

/// Several rows' writes (K8S-G1, `KubeBulkWrite`): the same guard path as
/// one row's (`write`), for all of them at once — the class check, an
/// access review for each namespace (one no stops all of it), one
/// confirmation naming every object, the count typed on production, the
/// context checked again before anything is sent, then a request each,
/// what came of each said.
extension KubernetesPageModel {
    /// The list's picked rows as objects, when more than one is picked
    /// (the detail and the GitOps section act on one).
    package var bulkTargets: [KubeObjectRef] {
        guard section != .gitops, detail == nil, selection.count > 1 else { return [] }
        return rows.filter { selection.contains($0.id) }.compactMap { ref(for: $0.id) }
    }

    /// Several rows picked: the verbs they take together, each greyed with why.
    package func bulkWriteVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        let refs = picked.compactMap { ref(for: $0.id.description) }
        guard refs.count > 1, let first = refs.first, let context = model.contexts.context(named: first.context) else { return [] }
        return KubeBulkWrite.verbs(for: first.kind).map { verb in
            let title = verb == .restart ? "Restart \(refs.count)" : "Delete \(refs.count)"
            return ResourceVerb(
                title: title, label: title, symbol: verb.symbol, place: verb == .delete ? .remove : .button,
                key: verb == .delete ? KubernetesKey.delete.key : KubernetesKey.restart.key,
                unavailable: bulkUnavailable(verb, refs, context), group: 5
            ) { [weak self] in self?.bulkWrite(verb, on: refs) }
        }
    }

    /// Why the rows can't take `verb` now: the rows, the class, a namespace's
    /// access review known to say no (asked when unknown).
    package func bulkUnavailable(_ verb: KubeWriteVerb, _ refs: [KubeObjectRef], _ context: KubeContext) -> String? {
        if let refused = KubeBulkWrite.refusal(verb, refs) { return refused }
        guard let kind = refs.first?.kind else { return nil }
        let rule = KubeWriteCheck.rule(verb, for: context, kind: kind)
        if let refused = rule.refused { return refused }
        guard let access = rule.access else { return nil }
        for namespace in KubeBulkWrite.namespaces(refs) {
            let state = model.writeAccess.state(context.name, namespace: namespace, access)
            if state == .unknown { model.writeAccess.check(context, namespace: namespace, access) }
            if let why = state.unavailable(access, namespace: namespace, review: true) { return why }
        }
        return nil
    }

    /// ⌫ or `r` with several rows picked: their delete or restart.
    package func bulkKey(_ verb: KubeWriteVerb) -> Bool {
        let refs = bulkTargets
        guard refs.count > 1, let kind = refs.first?.kind, KubeBulkWrite.verbs(for: kind).contains(verb) else { return false }
        bulkWrite(verb, on: refs)
        return true
    }

    /// `verb` on every one of `refs`, by the guard path.
    package func bulkWrite(_ verb: KubeWriteVerb, on refs: [KubeObjectRef]) {
        guard writeChecking == nil else { return }
        writeStatus = nil
        if let refused = KubeBulkWrite.refusal(verb, refs) {
            writeStatus = .failed(refused)
            return
        }
        guard let first = refs.first, let context = model.contexts.context(named: first.context) else {
            writeStatus = .failed("No context called \(refs.first?.context ?? "?").")
            return
        }
        let rule = KubeWriteCheck.rule(verb, for: context, kind: first.kind)
        if let refused = rule.refused {
            writeStatus = .failed(refused)
            return
        }
        writeChecks += 1
        let token = writeChecks
        writeChecking = token
        let counted = KubeBulkWrite.counted(refs)
        writeStatus = .working("Checking… \(counted)")
        Task { [weak self] in
            defer { self?.endChecking(token) }
            // Every namespace's review first: nothing is asked or sent before all say yes.
            if let access = rule.access {
                for namespace in KubeBulkWrite.namespaces(refs) {
                    let answer = await self?.model.writeAccess.answer(context, namespace: namespace, access) ?? .failed("")
                    guard let self else { return }
                    if let why = KubeAccessState.answered(answer).unavailable(access, namespace: namespace, review: true) {
                        self.writeStatus = .failed(why + " Nothing was changed.")
                        return
                    }
                }
            }
            guard let self else { return }
            self.endChecking(token)
            self.confirmBulk(verb, refs, reviewed: context)
        }
    }

    private func confirmBulk(_ verb: KubeWriteVerb, _ refs: [KubeObjectRef], reviewed: KubeContext) {
        guard let first = refs.first, let context = model.contexts.context(named: first.context) else {
            writeStatus = .failed("The context is gone: nothing was changed.")
            return
        }
        guard KubernetesModel.sameAccess(reviewed, context) else {
            writeStatus = .failed(Self.writeContextChanged)
            return
        }
        let rule = KubeWriteCheck.rule(verb, for: context, kind: first.kind)
        if let refused = rule.refused {
            writeStatus = .failed(refused)
            return
        }
        writeStatus = nil
        let confirmation = KubeBulkWrite.confirmation(verb, refs, context: context, rule: rule, discovery: model.knownDiscovery(of: first.context))
        actions?.confirmWrite(confirmation) { [weak self] answer in
            guard let self else { return }
            guard confirmation.accepts(answer.typed) else {
                self.writeStatus = .failed("The count typed wasn't \(confirmation.typedName ?? "\(refs.count)"): nothing was changed.")
                return
            }
            self.sendBulk(verb, refs, reviewed: reviewed)
        }
    }

    /// A request each, in order, through the context as it is now — writes
    /// turned off while the question showed stop it before the first.
    private func sendBulk(_ verb: KubeWriteVerb, _ refs: [KubeObjectRef], reviewed: KubeContext) {
        guard let first = refs.first, let context = model.contexts.context(named: first.context), let client = model.client(for: first.context) else {
            writeStatus = .failed("The context is gone: nothing was changed.")
            return
        }
        guard KubernetesModel.sameAccess(reviewed, context) else {
            writeStatus = .failed(Self.writeContextChanged)
            return
        }
        if let refused = KubeWriteCheck.rule(verb, for: context, kind: first.kind).refused {
            writeStatus = .failed(refused)
            return
        }
        let now = clock()
        Task { [weak self] in
            var results: [(ref: KubeObjectRef, error: String?)] = []
            for (index, ref) in refs.enumerated() {
                self?.writeStatus = .working("\(verb.label)… \(index + 1) of \(refs.count)")
                let request = verb == .restart ? KubeWrites.restart(ref, at: now) : KubeWrites.delete(ref)
                do {
                    try await client.write(request)
                    results.append((ref, nil))
                } catch {
                    results.append((ref, KubeWriteOutcome.failed(verb, ref, error)))
                }
            }
            let said = KubeBulkWrite.outcome(verb, results)
            self?.writeStatus = said.done ? .done(said.said) : .failed(said.said)
        }
    }
}
