import AppKit
import Combine
import SwiftUI

/// A Kubernetes manifest in the editor (stage 2b): a cluster object's copy
/// that `y` opened, a manifest file of the checkout's (`apiVersion:` and
/// `kind:` at the top), or a kustomization (`kustomization.yaml`, its
/// folder rendered). Its bar sits where a `.sql` file's console does:
/// Diff with Cluster, Apply… — the session does both (KubeManifestSession).
extension EditorViewController {
    func attachManifest(_ buffer: EditorBuffer) {
        guard Settings.shared.kubernetesEnabled, buffer.sqlConsole == nil, let url = buffer.url, buffer.document.unavailable == nil,
            KubeManifest.isYAML(url)
        else { return }
        let source: KubeManifestSession.Source
        if let edit = KubeManifestEdits.edit(at: url) {
            source = .object(edit.ref)
        } else if KubeManifest.isKustomization(url) {
            source = .kustomization(url.deletingLastPathComponent())
        } else if KubeManifest.looksLikeManifest(buffer.storage.string) {
            source = .file(url)
        } else {
            return
        }
        let session = KubeManifestSession(source: source, file: url, model: .shared)
        session.text = { [weak buffer] in buffer?.storage.string ?? "" }
        bindManifest(buffer, session)
        // Overterm's copy is never saved: a value retyped in it stays in memory.
        if case .object = source { buffer.document.unsaveable = KubeManifestEdits.unsaved }
        // A template's copy neither: a Secret's value typed into it never reaches a file.
        if KubeManifestEdits.isTemplate(url) {
            buffer.document.unsaveable = KubeManifestEdits.templateUnsaved
            // Applied, it is closed: a Secret's value typed into it isn't kept open (2.18).
            session.onApplied = { [weak self, weak buffer] said in
                guard let self, let buffer, let index = self.buffers.firstIndex(where: { $0 === buffer }) else { return }
                self.removeBuffer(at: index)
                self.kubernetesHost?.manifestTemplateApplied(said)
            }
        }
        session.host = kubernetesHost
        buffer.kubeManifest = session
    }

    /// The manifest's session asks this editor — where its caret is, which
    /// files are unsaved, the window to ask in: a cluster object's YAML is
    /// shown by two editors, and the one showing it last answers.
    func bindManifest(_ buffer: EditorBuffer, _ session: KubeManifestSession) {
        session.caret = { [weak self, weak buffer] in
            guard let self, let buffer else { return 0 }
            return buffer === self.active ? self.textView.selectedRange().location : buffer.selection.first?.location ?? 0
        }
        session.onDocsRead = { [weak self, weak buffer] in
            guard let self, let buffer else { return }
            self.refreshKubeFieldMarks(buffer)
        }
        session.unsaved = { [weak self] in
            self?.buffers.filter { $0.document.isDirty && $0.document.unsaveable == nil }.compactMap(\.url) ?? []
        }
        if let kubernetesHost { session.host = kubernetesHost }
    }

    /// The manifest's bar, under its text.
    func showManifestBar(_ session: KubeManifestSession) {
        session.host = session.host ?? kubernetesHost
        consoleHost.rootView = AnyView(KubeManifestBar(session: session, theme: chrome))
        let banner: AnyPublisher<Bool, Never> = session.resource.map { $0.$clusterChange.map { $0 != nil }.eraseToAnyPublisher() } ?? Just(false).eraseToAnyPublisher()
        consoleObserver = session.$state.combineLatest(session.$applyRefusal, banner)
            .map { state, refusal, banner in KubeManifestBar.height(status: state.text != nil || (refusal != nil && session.ref != nil), banner: banner) }
            .removeDuplicates()
            .sink { [weak self] height in self?.consoleHeight.constant = height }
    }

    /// The buffer of `url`'s manifest, while it is open.
    func manifestSession(for url: URL) -> KubeManifestSession? {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        return buffers.first { $0.url?.standardizedFileURL.resolvingSymlinksInPath() == key }?.kubeManifest
    }

    // MARK: The cluster's docs (3.15)

    /// The fields the docs don't know, marked as warnings — from what is
    /// cached alone: nothing is read for them.
    func refreshKubeFieldMarks(_ buffer: EditorBuffer) {
        guard let manifest = buffer.kubeManifest else { return }
        let marks = Settings.shared.kubernetesEnabled ? manifest.fieldMarks(in: buffer.storage.string) : []
        let diagnostics = marks.map { EditorDiagnostic(range: $0.range, severity: .warning, message: $0.message, source: "kubernetes") }
        guard diagnostics != buffer.kubeDiagnostics else { return }
        buffer.kubeDiagnostics = diagnostics
        guard buffer === active else { return }
        textView.diagnostics = buffer.diagnostics
        updateProblemLines()
        updateStatus()
    }

    /// Once typing pauses.
    func scheduleKubeFieldMarks(_ buffer: EditorBuffer) {
        pendingKubeMarks?.cancel()
        let work = DispatchWorkItem { [weak self, weak buffer] in
            MainActor.assumeIsolated {
                guard let self, let buffer else { return }
                self.refreshKubeFieldMarks(buffer)
            }
        }
        pendingKubeMarks = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The fields a key typed at the caret could be, from the manifest's
    /// cluster's docs: as cached, or — `manual` (⌃Space) — read first, the
    /// list shown when they come; when they don't (a server without
    /// OpenAPI v3, a sign-in failing) or offer nothing, the regular
    /// completion instead. False when there is nothing to offer.
    @discardableResult
    func updateKubeCompletion(manual: Bool) -> Bool {
        guard Settings.shared.kubernetesEnabled, let buffer = active, let manifest = buffer.kubeManifest, textView.selectedRanges.count == 1,
            textView.selectedRange().length == 0, let window = view.window
        else { return false }
        let text = textView.string
        let caret = textView.selectedRange().location
        guard let slot = KubeManifestFields.slot(at: caret, in: text as NSString), let gvk = slot.document.gvk else { return false }
        guard let cached = manifest.cachedDocs(gvk) else {
            guard manual else { return false }
            let version = buffer.version
            Task { [weak self] in
                _ = await manifest.fieldCompletions(at: caret, in: text)
                guard let self, buffer === self.active, buffer.version == version, self.textView.selectedRange().location == caret else { return }
                if manifest.cachedDocs(gvk) != nil, self.updateKubeCompletion(manual: false) { return }
                self.triggerCompletion(manual: true, skipKube: true)
            }
            return true
        }
        let fields = KubeManifestFields.candidates(slot, in: cached.document, gvk: gvk).prefix(200)
        guard !fields.isEmpty else { return false }
        let color = theme.style(for: "property")?.color ?? theme.info
        let candidates = fields.map { field in
            CompletionState.Candidate(
                label: field.name, filterText: field.name, insertText: slot.atLineEnd ? field.name + ": " : field.name, isSnippet: false,
                badge: "fld", badgeColor: color, detail: "<\(field.type)>" + (field.required ? " required" : ""), edit: nil, additionalEdits: [],
                sortText: field.name, fromServer: false)
        }
        completionRequests += 1
        var state = CompletionState(
            anchor: slot.prefixRange.location, requestedAt: caret, buffer: buffer, candidates: Array(candidates), generation: completionRequests)
        state.isKube = true
        state.shown = Array(state.candidates.indices)
        completion = state
        let items = state.candidates.map { EditorListItem(title: $0.label, detail: $0.detail, badge: $0.badge, badgeColor: $0.badgeColor, matched: []) }
        completionPopup.show(items, details: state.candidates.map(\.detail), at: textView.screenRect(forCharacterAt: slot.prefixRange.location), in: window)
        return true
    }
}
