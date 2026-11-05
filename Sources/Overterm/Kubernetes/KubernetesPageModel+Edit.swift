import Foundation

// MARK: Edit the YAML in the editor (`y`; stage 2b — docs/design/kubernetes/analysis.md, 2.8)

/// `y` opens the object's YAML in the editor as Overterm's own copy
/// (`KubeManifestEdits`): one GET, stripped as the YAML tab strips it —
/// managedFields, status, the last-applied annotation, and what names
/// this one version of it (its resourceVersion is kept beside the copy and
/// sent with the apply) — a Secret's values and secret-looking env values
/// masked, so no value is ever written to the file. Offered on every
/// class: diffing changes nothing. Applying is the editor's own step
/// (`KubeManifestSession`), on writable contexts only.
extension KubernetesPageModel {
    static let editTitle = "Edit YAML in Editor"

    func editVerb(for ref: KubeObjectRef) -> ResourceVerb {
        ResourceVerb(
            title: Self.editTitle, label: "Edit", symbol: "pencil", place: .more, key: KubernetesKey.edit.key,
            unavailable: model.contexts.context(named: ref.context) == nil ? "The context is gone." : nil, group: 4
        ) { [weak self] in self?.editYAML(ref) }
    }

    func editVerbs(for picked: [KubeRow]) -> [ResourceVerb] {
        guard picked.count == 1, let row = picked.first, let ref = ref(for: row.id.description) else { return [] }
        return [editVerb(for: ref)]
    }

    /// `y`: the object the detail shows, else the one selected row.
    func editKey() -> Bool {
        guard let ref = writeTarget else { return false }
        editYAML(ref)
        return true
    }

    func editYAML(_ ref: KubeObjectRef) {
        writeStatus = nil
        guard let context = model.contexts.context(named: ref.context), let client = model.client(for: ref.context) else {
            writeStatus = .failed("Kubernetes is off, or the context is gone.")
            return
        }
        // Open already: its tab, with whatever is typed in it.
        let url = KubeManifestEdits.url(for: ref)
        if KubeManifestEdits.edit(at: url) != nil {
            actions?.openEditor(url)
            return
        }
        // A Secret's one GET is every value at once: on production asked
        // once a context and session, as Show is (rule 9).
        if ref.isSecret, model.secretConsent.needsAsking(context.name, production: context.isProduction) {
            actions?.confirm(
                "Read \(KubeWriteOutcome.spoken(ref)) to edit it?",
                "PRODUCTION · \(context.name)\nIts YAML opens in the editor with every value masked — the values are read once and dropped, never written. "
                    + "Asked once a session.",
                "Read and Edit"
            ) { [weak self] in
                self?.model.secretConsent.grant(context.name)
                self?.editYAML(ref)
            }
            return
        }
        let spoken = KubeWriteOutcome.spoken(ref)
        writeStatus = .working("Opening \(spoken)…")
        Task { [weak self] in
            do {
                let body = try await client.get(KubeWrites.path(ref)).body
                guard let self else { return }
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    self.writeStatus = .failed("\(spoken)'s answer couldn't be read.")
                    return
                }
                let version = (object["metadata"] as? [String: Any])?["resourceVersion"] as? String
                let text = KubeManifestEdits.header(ref, production: context.isProduction) + KubeYAML.text(KubeManifestDiff.forEditing(object))
                let url = try KubeManifestEdits.write(text, for: ref, resourceVersion: version)
                self.writeStatus = nil
                self.actions?.openEditor(url)
            } catch {
                self?.writeStatus = .failed("Couldn't open \(spoken): \(KubernetesModel.said(error))")
            }
        }
    }
}
