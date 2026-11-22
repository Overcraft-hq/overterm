import Foundation

/// What a tab and a pane hold for Kubernetes, kept by the shell untyped
/// (it sits under this module) and read here as what they are.
extension Tab {
    /// What its checkout deploys has failed (attention marks, 3.13): the
    /// newest first — Ask Why on the mark asks about the first.
    package var kubeAlerts: [KubeAttentionAlert] {
        get { kubeAlertsStorage.compactMap { $0.base as? KubeAttentionAlert } }
        set { kubeAlertsStorage = newValue.map(AnyHashable.init) }
    }

    /// The Kubernetes context the focused pane is pinned to — Terminal in
    /// this context. A pane moved in from another tab keeps its own, so
    /// the tab as a whole is `kubeBadge`.
    package var kubePin: KubeTerminalPin? { terminal.kubePin }
}

extension TerminalView {
    /// The Kubernetes context this pane's `KUBECONFIG` pins, if any — what
    /// a plain kubectl there reaches now: followed when the pin's file
    /// changes (a `use-context` typed in the pane; `KubeTerminalFollow`).
    package var kubePin: KubeTerminalPin? {
        get { kubePinStorage as? KubeTerminalPin }
        set { kubePinStorage = newValue }
    }

    /// A pin that couldn't be restored: the pane's `KUBECONFIG` reaches no
    /// cluster, and its header says so (`KubeTerminalLost`).
    package var kubePinLost: KubeTerminalLost? { kubePinLostStorage as? KubeTerminalLost }
}
