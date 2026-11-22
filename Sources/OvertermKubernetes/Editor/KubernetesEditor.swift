import AppKit

/// What an editor buffer and the editor hold for Kubernetes — kept by the
/// shell's editor untyped, read here as what they are.
extension EditorBuffer {
    /// A Kubernetes manifest — a cluster object's copy (`y`), a checkout's
    /// file, a kustomization: the bar under it (Diff with Cluster, Apply).
    package var kubeManifest: KubeManifestSession? {
        get { manifestPart as? KubeManifestSession }
        set { manifestPart = newValue }
    }

    /// A cluster object's YAML (`KubeResourceBuffer`): one buffer for the
    /// resource, shown by the detail's YAML tab and by the editor's tab `y`
    /// opens — never a file.
    package var resource: KubeResourceBuffer? {
        get { resourcePart as? KubeResourceBuffer }
        set { resourcePart = newValue }
    }
}

extension EditorViewController {
    /// The window: a Kubernetes manifest's confirmations and its diff.
    package var kubernetesHost: KubeManifestHost? {
        get { kubernetesHostStorage as? KubeManifestHost }
        set { kubernetesHostStorage = newValue }
    }
}

extension KubeManifestSession: EditorManifest {}

extension KubeResourceBuffer: EditorResource {
    package var contextName: String { ref.context }
}

/// Kubernetes' part in the editor, set once (`OvertermFeatures`).
package enum KubernetesEditor {
    package static func install() {
        EditorViewController.hooksStorage.resourceAt.append { url in KubernetesModel.shared.resourceBuffers.resource(at: url) }
        EditorViewController.hooksStorage.attach.append { editor, buffer in editor.attachManifest(buffer) }
        // The detail's YAML tab draws its bar over the editor itself.
        EditorViewController.hooksStorage.panel.append { editor, buffer in
            guard let manifest = buffer.kubeManifest else { return false }
            editor.showManifestBar(manifest)
            return true
        }
        EditorViewController.hooksStorage.rebind.append { editor, buffer, requireResource in
            guard let manifest = buffer.kubeManifest, !requireResource || buffer.resource != nil else { return }
            editor.bindManifest(buffer, manifest)
        }
        // A manifest's key: its cluster's fields (read on ⌃Space, else as cached).
        EditorViewController.hooksStorage.trigger.append { editor, buffer, manual, character, skip in
            !skip && buffer.kubeManifest != nil && character == nil && editor.updateKubeCompletion(manual: manual)
        }
        EditorViewController.hooksStorage.refilter.append { editor, state in
            guard state.isKube else { return false }
            if !editor.updateKubeCompletion(manual: false) { editor.dismissCompletion() }
            return true
        }
        EditorViewController.hooksStorage.didChange.append { editor, buffer in
            if buffer.kubeManifest != nil { editor.scheduleKubeFieldMarks(buffer) }
        }
        // A Kubernetes manifest's field: the cluster's own docs first (3.15).
        EditorViewController.hooksStorage.hover.append { editor, buffer, index, unasked, fallback, still, present in
            guard let manifest = buffer.kubeManifest, Settings.shared.kubernetesEnabled else { return false }
            let version = buffer.version
            let text = buffer.storage.string
            Task { @MainActor [weak editor] in
                // The mouse resting there asks nothing that signs in or closes a proxy.
                let found = await manifest.fieldHover(at: index, in: text, unasked: unasked)
                guard let editor, buffer.version == version, buffer === editor.active else { return }
                editor.refreshKubeFieldMarks(buffer)
                guard let found else { return fallback() }
                guard still() else { return }
                present(found.text)
            }
            return true
        }
    }
}
