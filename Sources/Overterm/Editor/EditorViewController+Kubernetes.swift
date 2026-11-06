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
        session.unsaved = { [weak self] in
            self?.buffers.filter { $0.document.isDirty && $0.document.unsaveable == nil }.compactMap(\.url) ?? []
        }
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

    /// The manifest's bar, under its text.
    func showManifestBar(_ session: KubeManifestSession) {
        session.host = session.host ?? kubernetesHost
        consoleHost.rootView = AnyView(KubeManifestBar(session: session, theme: chrome))
        consoleObserver = session.$state.map { $0.text != nil }.removeDuplicates().sink { [weak self] status in
            self?.consoleHeight.constant = status ? KubeManifestBar.statusHeight : KubeManifestBar.height
        }
    }

    /// The buffer of `url`'s manifest, while it is open.
    func manifestSession(for url: URL) -> KubeManifestSession? {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        return buffers.first { $0.url?.standardizedFileURL.resolvingSymlinksInPath() == key }?.kubeManifest
    }
}
