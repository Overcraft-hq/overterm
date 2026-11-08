import Foundation

// MARK: New from a template (KubeTemplates), and saved filters (KubeSavedFilters)

extension KubernetesPageModel {
    /// Where a template goes: the namespace shown — of several, the
    /// context's own when it is one, else the first — else the context's own.
    var templateNamespace: String {
        if let shown = shownNamespace { return shown }
        guard let context = model.selected else { return "default" }
        let own = KubernetesModel.defaultScope(context).one()
        return model.scope.one(preferring: own) ?? own ?? "default"
    }

    /// A template as Overterm's copy in the editor, its namespace the one
    /// shown; the manifest's bar diffs it with the page's context and
    /// applies it by 2b's path. Nothing is sent from here.
    @discardableResult
    func newFromTemplate(_ template: KubeTemplate) -> URL? {
        writeStatus = nil
        guard let text = KubeTemplates.read(template.file) else {
            writeStatus = .failed("Couldn't read the template \(template.file.lastPathComponent).")
            return nil
        }
        let context = model.selected
        let copy = KubeTemplates.text(
            text, kind: template.kind, context: context?.name, production: context?.isProduction == true, namespace: templateNamespace)
        do {
            let url = try KubeManifestEdits.writeTemplate(copy, name: template.name)
            actions?.openEditor(url)
            return url
        } catch {
            writeStatus = .failed("Couldn't open the template: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Saved filters

    /// The filter as it is, kept by `name` (its text, unnamed) for the
    /// context, kind and namespace shown.
    @discardableResult
    func saveFilter(named name: String? = nil, in store: KubeSavedFilters = .shared) -> KubeSavedFilter? {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context = model.selectedName else { return nil }
        let saved = KubeSavedFilter(name: name ?? text, context: context, kind: KubeSavedFilter.Kind(model.kind), scope: model.scope, filter: text)
        guard store.save(saved) else { return nil }
        return store.filters(on: context).first { $0.name == saved.name }
    }

    /// Its context, kind and namespace shown, its text the filter — its
    /// `label:` and `field:` asked of the server again.
    func applySavedFilter(_ saved: KubeSavedFilter) {
        guard model.contexts.context(named: saved.context) != nil else {
            commandProblem = "No context called \(saved.context) any more."
            return
        }
        if model.selectedName != saved.context { model.select(saved.context) }
        let kind = model.catalog.kind(fullName: saved.kind.fullName) ?? saved.kind.resourceKind
        if kind.namespaced {
            model.setScope(saved.scope)
        }
        showKind(kind)
        filter = saved.filter
        applySelector()
    }
}
