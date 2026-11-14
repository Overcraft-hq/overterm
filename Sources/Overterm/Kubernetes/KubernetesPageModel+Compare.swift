import Foundation

// MARK: Diff across contexts (docs/design/kubernetes/analysis.md, 3.10)

/// "Compare with…" on any object: the same kind and name in another
/// context — or another namespace — picked as `c` picks a context, each
/// side one GET through its own context's proxy (the other in a
/// background slot), both stripped and masked (`KubeCompare`), the diff in
/// the changes pane. A Secret is compared by its keys and keyed hashes of
/// its values; its GET on production is asked first, once a context and
/// session, as Show is (rule 9). Reads only.
extension KubernetesPageModel {
    static let compareTitle = "Compare with…"

    func compareVerb(for ref: KubeObjectRef) -> ResourceVerb {
        let others = model.contexts.contexts.contains { $0.name != ref.context }
        let why: String? =
            model.contexts.context(named: ref.context) == nil
            ? "The context is gone." : !others && !ref.kind.namespaced ? "There is no other context to compare it with." : nil
        return ResourceVerb(title: Self.compareTitle, label: "Compare", symbol: "arrow.left.arrow.right.square", unavailable: why, group: 4) {
            [weak self] in self?.openCompare(ref)
        }
    }

    func compareVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return [compareVerb(for: ref)]
    }

    /// The picker of the other side: every other context in the object's
    /// namespace, then the context's other namespaces; one typed.
    func openCompare(_ ref: KubeObjectRef) {
        endCompare()
        compareRef = ref
        openPicker(.compare(context: ref.context, namespace: ref.namespace))
    }

    func comparePicker(_ ref: KubeObjectRef) -> KubePicker {
        KubePicker.compare(
            context: ref.context, namespace: ref.namespace, contexts: model.contexts, namespaces: ref.context == model.selectedName ? model.namespaces : [])
    }

    /// `ref` against the same kind and name in `other` (in `namespace`, or
    /// the object's own): read, diffed, shown in the changes pane.
    func compare(_ ref: KubeObjectRef, with other: String, namespace: String?) {
        endCompare()
        // The last write's outcome, done or failed, gives way to what was asked now.
        if let status = writeStatus, !status.isWorking { writeStatus = nil }
        guard model.enabled, let here = model.contexts.context(named: ref.context), let there = model.contexts.context(named: other) else {
            compareStatus = KubeCompareStatus(ref: ref, text: "Kubernetes is off, or the context is gone.")
            return
        }
        let otherNamespace = ref.kind.namespaced ? (namespace ?? ref.namespace) : nil
        guard other != ref.context || otherNamespace != ref.namespace else {
            compareStatus = KubeCompareStatus(ref: ref, text: "That is the object itself: pick another context or namespace.")
            return
        }
        let from = KubeCompare.Side(context: here.name, namespace: ref.namespace, production: here.isProduction)
        let to = KubeCompare.Side(context: there.name, namespace: otherNamespace, production: there.isProduction)
        if ref.isSecret {
            let asked = [here, there].filter { model.secretConsent.needsAsking($0.name, production: $0.isProduction) }.map(\.name)
            let names = Array(NSOrderedSet(array: asked)) as? [String] ?? asked
            if !names.isEmpty {
                actions?.confirm(
                    "Read this Secret on both sides to compare it?",
                    "PRODUCTION · \(names.joined(separator: ", "))\nOne GET a side returns every value: each is replaced at once by a hash made for this comparison alone — no value is shown, written or kept. Asked once a context and session.",
                    "Read and Compare"
                ) { [weak self] in
                    for name in names { self?.model.secretConsent.grant(name) }
                    self?.readComparison(ref, from: from, to: to)
                }
                return
            }
        }
        readComparison(ref, from: from, to: to)
    }

    private func readComparison(_ ref: KubeObjectRef, from: KubeCompare.Side, to: KubeCompare.Side) {
        guard let left = model.client(for: from.context, role: from.context == model.selectedName ? .page : .background),
            let right = model.client(for: to.context, role: to.context == model.selectedName ? .page : .background)
        else {
            compareStatus = KubeCompareStatus(ref: ref, text: "Kubernetes is off, or the context is gone.")
            return
        }
        // The detail's own answer, when it is this object's — never a
        // Secret's: the detail doesn't read one.
        let read = !ref.isSecret && detail?.ref == ref ? detail?.object?.data : nil
        let kind = detail?.ref == ref ? (detail?.object?.kind ?? ref.kind.kind) : ref.kind.kind
        let spoken = "\(kind.lowercased())/\(ref.name)"
        compareStatus = KubeCompareStatus(ref: ref, text: "Reading \(spoken) in \(to.said)…")
        comparing?.cancel()
        comparing = Task { [weak self] in
            do {
                let here: Data
                if let read {
                    here = read
                } else {
                    here = try await left.get(ref.kind.path(namespace: from.namespace, name: ref.name)).body
                }
                var there: Data?
                do {
                    there = try await right.get(ref.kind.path(namespace: to.namespace, name: ref.name)).body
                } catch let error as KubeAPIError where error.status == 404 {
                    there = nil
                }
                try Task.checkCancellation()
                let other = there
                let diff = await KubeBlocking.run { KubeCompare.diff(ref: ref, kind: kind, left: here, right: other, from: from, to: to) }
                guard let self, !Task.isCancelled else { return }
                guard let diff else {
                    self.compareStatus = KubeCompareStatus(ref: ref, text: "\(spoken) couldn't be read as an object.")
                    return
                }
                self.compareStatus = nil
                self.comparing = nil
                self.actions?.showChange(diff)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.compareStatus = KubeCompareStatus(ref: ref, text: "Couldn't compare \(spoken): \(KubernetesModel.said(error))")
            }
        }
    }

    /// The comparison ended — the detail closed, another object, context or
    /// namespace, the page hidden: nothing read for it comes back, and
    /// nothing said of it stays.
    func endCompare() {
        comparing?.cancel()
        comparing = nil
        if compareStatus != nil { compareStatus = nil }
    }
}

/// How a comparison stands, for the object it compares.
struct KubeCompareStatus: Equatable {
    var ref: KubeObjectRef
    var text: String
}
