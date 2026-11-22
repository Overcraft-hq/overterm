import Foundation

/// What an agent may read of a pod's log lines (⌘L): the pod's own env
/// values that look secret, and what looks like a credential whoever wrote
/// it — a URL's password, a bearer token, a JWT, a PEM block's body, AWS
/// keys, a kubeconfig's `token:`, `client-key-data:` and
/// `client-certificate-data:`, `password=`/`secret:`-style pairs, base64
/// blobs — taken out (`Secrets`). Pure.
package enum KubeLogScrub {
    package static let mask = "••••••"

    /// The pod's env as the spec writes it: plain `value`s only (a
    /// `secretKeyRef`'s value is never read).
    package static func env(of pod: [String: Any]) -> [(key: String, value: String)] {
        let spec = pod["spec"] as? [String: Any] ?? [:]
        var out: [(key: String, value: String)] = []
        for key in ["initContainers", "containers", "ephemeralContainers"] {
            for container in spec[key] as? [[String: Any]] ?? [] {
                for item in container["env"] as? [[String: Any]] ?? [] {
                    if let name = item["name"] as? String, let value = item["value"] as? String { out.append((name, value)) }
                }
            }
        }
        return out
    }

    /// The env's secret values and every URL's password taken out
    /// (`Secrets.scrub`), then what looks like a credential
    /// (`Secrets.scrubCredentials`: tokens, keys, a kubeconfig's fields,
    /// base64 blobs).
    package static func scrub(_ text: String, env: [(key: String, value: String)]) -> String {
        Secrets.scrubCredentials(Secrets.scrub(text, env: env))
    }
}
