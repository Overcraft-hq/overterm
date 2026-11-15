import Foundation

// MARK: Edit the YAML in the editor (`y`; stage 2b — docs/design/kubernetes/analysis.md, 2.8)

/// `y` opens the object's YAML in the window's editor: the resource's one
/// buffer (`KubeResourceBuffer`) — the YAML tab's, the same edits — read
/// once if nobody has yet: stripped as the tab strips it, its
/// resourceVersion kept beside it and sent with the apply, a Secret's
/// values and secret-looking env values masked. Never a file. Offered on
/// every class: diffing changes nothing. Applying is the bar's own step
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
        guard let context = model.contexts.context(named: ref.context), model.client(for: ref.context) != nil else {
            writeStatus = .failed("Kubernetes is off, or the context is gone.")
            return
        }
        let resources = model.resourceBuffers
        // Read already — the YAML tab's, or `y` before: that buffer, whatever is typed in it.
        if let open = resources.existing(ref), open.state == .loaded {
            actions?.openResource(open)
            return
        }
        // The detail has the object: its read is the text (a Secret's only after Show).
        if let detail, detail.ref == ref, let object = detail.object {
            let resource = detail.openResource(in: resources)
            if resource.state != .loaded { resource.take(object.json) }
            if resource.state == .loaded {
                actions?.openResource(resource)
                return
            }
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
        let resource = resources.buffer(for: ref)
        Task { [weak self] in
            do {
                try await resource.load(secret: ref.isSecret)
                guard let self else { return }
                self.writeStatus = nil
                self.actions?.openResource(resource)
            } catch {
                resources.dropIfUnheld(resource)
                self?.writeStatus = .failed("Couldn't open \(spoken): \(KubernetesModel.said(error))")
            }
        }
    }

    /// The YAML tab reads while it shows — the page on screen, in a window
    /// on screen: the resource's buffer made from the detail's read, and
    /// the object followed so a change on the cluster reaches it.
    func updateYAMLReading() {
        guard let detail else { return }
        let onScreen = visible && windowVisible && detailTab == .yaml
        if onScreen {
            let resource = detail.openResource(in: model.resourceBuffers)
            resource.watch(by: detail)
        } else {
            detail.resource?.unwatch(by: detail)
        }
    }

    /// The YAML tab's editor: one for the page, showing the detail's buffer.
    var yamlEditor: EditorViewController? {
        if let made = madeYAMLEditor { return made }
        madeYAMLEditor = makeYAMLEditor?()
        return madeYAMLEditor
    }
}
