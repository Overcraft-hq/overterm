import Foundation

/// Kept with the feature it is for; AppEnvironment holds the shell's.
extension AppEnvironment {
    /// The kubeconfig files Overterm reads, in kubectl's order: the shell's
    /// KUBECONFIG list (else ~/.kube/config), then `extra`
    /// (`kubernetes.kubeconfigs`). OVERTERM_KUBECONFIG — a scenario's fake
    /// clusters — replaces them all. An isolated run or a unit test reads
    /// only OVERTERM_KUBECONFIG's files, never one under ~/.kube, and
    /// without it none: it never asks the shell, so an inherited KUBECONFIG
    /// is never seen either. Blocking the first time (the shell is asked):
    /// off the main thread.
    package static func kubeconfigs(extra: [String]) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let overterm = env["OVERTERM_KUBECONFIG"]
        let guarded = guardsKubeconfig
        let hasOwn = !(overterm ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let variable = guarded || hasOwn ? nil : ShellEnvironment.environment()["KUBECONFIG"]
        return KubeconfigSources.paths(overterm: overterm, guarded: guarded, kubeconfig: variable, extra: extra, home: home)
    }
}
