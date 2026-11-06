import Foundation

/// Why a context can't be reached, in words a person can act on.
///
/// The proxy hands the server's own errors (401, 403, 404, 409…) through
/// as Status JSON; its own failures — an exec plugin that failed, a dial
/// that didn't connect — are a 500 with the error as plain text. The spike
/// on the dev clusters: with an expired AWS SSO session every request was
/// such a 500 ("getting credentials: exec: executable aws failed with exit
/// code 255"), and kubectl ran `aws` again for each one, 1.3–4.6 s apiece.
/// So a credential failure stops that context's requests (`stopsRequests`)
/// until the user signs in again (`KubeProxies.retry`); a network failure
/// doesn't — the VPN comes back.
enum KubeProxyProblem: Error, Equatable, Sendable, LocalizedError {
    /// `aws eks get-token` failed: the SSO session expired.
    case awsSignIn(profile: String?)
    /// kubelogin's browser sign-in nobody finished (it waited 181 s in the spike).
    case signInTimedOut
    /// kubelogin failed some other way.
    case signInFailed(String)
    /// The kubeconfig's credential plugin isn't installed, with the kubeconfig's hint.
    case pluginMissing(String, hint: String?)
    /// The plugin wants a terminal (`interactiveMode: Always`), which a
    /// proxy Overterm starts doesn't have: sign in in a tab first.
    case needsTerminal(context: String)
    /// Another credential failure, as kubectl said it.
    case credentials(String)
    /// The cluster didn't answer: a dial error, a VPN that is down.
    case unreachable(String)
    /// Another failure of the proxy's own (a certificate, a TLS handshake).
    case transport(String)
    /// No kubectl was found (an isolated run uses only `kubernetes.kubectlPath`).
    case noKubectl
    /// No kubeconfig this run may read (an isolated run without `OVERTERM_KUBECONFIG`).
    case noKubeconfig
    /// The socket's folder or path.
    case socket(String)
    /// Every proxy allowed is busy, and none is the background's to give up.
    case noSlot(max: Int)
    /// kubectl proxy didn't start.
    case proxyFailed(String)
    /// The context's proxy was closed (for another's slot, a retry, a
    /// change of class) while this request waited for it: try again.
    case closedWhileOpening
    /// An attention watch on a context that signs in in the browser, before
    /// anyone has: it never opens a sign-in nobody asked for.
    case needsPageSignIn

    /// Whether the context's requests stop until the user signs in again:
    /// each one would run the failing plugin again.
    var stopsRequests: Bool {
        switch self {
        case .awsSignIn, .signInTimedOut, .signInFailed, .pluginMissing, .needsTerminal, .credentials: true
        case .unreachable, .transport, .noKubectl, .noKubeconfig, .socket, .noSlot, .proxyFailed, .closedWhileOpening, .needsPageSignIn: false
        }
    }

    /// What to run in a terminal tab to put it right, when something does.
    var command: String? {
        switch self {
        case .awsSignIn(let profile): "aws sso login" + (profile.map { " --profile \(Self.shellQuoted($0))" } ?? "")
        case .needsTerminal(let context): "kubectl --context \(Self.shellQuoted(context)) version"
        default: nil
        }
    }

    var reason: String {
        switch self {
        case .awsSignIn: "Sign in again: \(command ?? "aws sso login")"
        case .signInTimedOut: "The browser sign-in timed out. Try again to sign in."
        case .signInFailed(let detail): "The sign-in failed: \(detail)"
        case .pluginMissing(let plugin, let hint): "\(plugin) isn't installed." + (hint.map { " \($0)" } ?? "")
        case .needsTerminal: "This context signs in at a terminal: run \(command ?? "kubectl version") in a tab, then try again."
        case .credentials(let detail): "kubectl couldn't get credentials: \(detail)"
        case .unreachable: "The cluster can't be reached (VPN?)."
        case .transport(let detail): detail
        case .noKubectl: "No kubectl found. Install it, or set Settings ▸ Kubernetes ▸ kubectl."
        case .noKubeconfig: "No kubeconfig this run may read."
        case .socket(let detail): detail
        case .noSlot(let max): "\(max) contexts are connected and busy; close one, or allow more in Settings ▸ Kubernetes."
        case .proxyFailed(let detail): detail
        case .closedWhileOpening: "The connection to the cluster was closed while it opened. Try again."
        case .needsPageSignIn: "Sign in on the page first: this context signs in in the browser, and the background never opens a sign-in."
        }
    }

    var errorDescription: String? { reason }

    /// What a response from the proxy means, or nil when it is the server's
    /// own answer (anything but a 500, or a 500 with Status JSON). `text` is
    /// its body; `stderr` kubectl's, where the plugin's own words are
    /// ("Token has expired").
    static func classify(status: Int, contentType: String?, text: String, stderr: String, signIn: KubeSignIn) -> KubeProxyProblem? {
        guard status == 500, contentType?.lowercased().contains("json") != true else { return nil }
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.hasPrefix("{") else { return nil }
        let lower = said.lowercased()
        let detail = String(said.prefix(300))
        if lower.contains("getting credentials") || lower.hasPrefix("exec:") || lower.contains("exec plugin") {
            let plugin = (lower + "\n" + stderr.lowercased())
            if plugin.contains("executable file not found") || plugin.contains("not found in $path") || plugin.contains("no such file or directory") {
                return .pluginMissing(signIn.pluginName ?? "The credential plugin", hint: nil)
            }
            switch signIn {
            case .oidc:
                let timedOut = ["deadline exceeded", "timed out", "timeout"].contains { plugin.contains($0) }
                return timedOut ? .signInTimedOut : .signInFailed(detail)
            case .aws(let profile): return .awsSignIn(profile: profile)
            case .none, .plugin: return .credentials(detail)
            }
        }
        let network = ["dial tcp", "no such host", "i/o timeout", "connection refused", "network is unreachable", "no route to host"]
        if network.contains(where: lower.contains) { return .unreachable(detail) }
        return .transport(detail.isEmpty ? "kubectl proxy failed." : detail)
    }

    /// A stream's error answer, read as `classify` reads a response: its
    /// `Content-Type` and body when the transport kept them (a JSON
    /// Status's message is not the proxy's plain text), else its message.
    static func classify(_ error: HTTPError, stderr: String, signIn: KubeSignIn) -> KubeProxyProblem? {
        guard let response = error.response else {
            return classify(status: error.status, contentType: nil, text: error.message, stderr: stderr, signIn: signIn)
        }
        return classify(
            status: response.status, contentType: response.header("Content-Type"), text: String(decoding: response.body.prefix(4096), as: UTF8.self),
            stderr: stderr, signIn: signIn)
    }

    /// The last line that says something.
    static func lastLine(of text: String) -> String? {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@=+,"))
        if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A Kubernetes version's minor, as `/version` and `kubectl version
/// --client -o json` say it: `"30"`, EKS's `"30+"`.
enum KubeVersion {
    static func minor(_ data: Data, under key: String? = nil) -> Int? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let key {
            guard let inner = object[key] as? [String: Any] else { return nil }
            object = inner
        }
        guard let minor = object["minor"] as? String else { return nil }
        return Int(minor.prefix { $0.isNumber })
    }
}
