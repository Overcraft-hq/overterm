import Foundation

/// Kubernetes' part in the shell under it, set once (`OvertermFeatures`).
package enum KubernetesFeature {
    package static func install() {
        KubernetesEditor.install()
        // A kubectl-family command: the files its context comes from are
        // read the first time, never per command.
        PaneBlocks.commandNoticedStorage.append { title, cwd, kubeconfig in KubeAmbientContexts.shared.noticed(title, cwd: cwd, kubeconfig: kubeconfig) }
        SettingsSchema.entryFieldsStorage["kubernetes.contexts"] = KubeContextSettings.fields
        Tab.kubeBadgeHook = { @MainActor tab in KubeTabBadge.of(tab.terminals.map { KubeTabBadge.Pane(pin: $0.kubePin, lost: $0.kubePinLost) }) }
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { $0.hasPrefix(KubeMCP.prefix) }, enabled: { $0.kubernetesAgentAccess },
                unavailable: "Kubernetes isn't available to agents — Settings ▸ Kubernetes.",
                tools: { KubeMCP.tools }, instructions: { KubeMCP.instructions },
                // Kubernetes' writes while kubernetes.agentWrites names a context —
                // a setting, not the contexts' state now, which changes after the
                // list was read (it isn't announced again): each call is refused
                // where the context isn't writable for agents.
                listed: { _, kubernetes in
                    let writes = await MainActor.run { !((kubernetes as? KubernetesModel) ?? KubernetesModel.shared).agentWrites.isEmpty }
                    return writes ? KubeMCP.writeTools : []
                },
                call: { name, arguments, pane, kubernetes in
                    let model = await MainActor.run { (kubernetes as? KubernetesModel) ?? KubernetesModel.shared }
                    return try await KubeMCP.call(name, arguments, kubernetes: model, pane: pane)
                },
                said: { error in KubeMCPText.scrubbed(KubernetesModel.said(error)) }))
    }
}
