import Foundation

extension Settings {
    /// Each context's own settings, by its name.
    package var kubernetesContexts: [String: KubeContextSettings] { KubeContextSettings.all(from: value("kubernetes.contexts")) }
}
