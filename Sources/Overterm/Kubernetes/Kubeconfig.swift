import Foundation

/// One kubeconfig file, as far as Overterm reads it: the contexts, the
/// clusters' servers, and how each user signs in — never with what.
///
/// kubectl does the signing in (the proxy, `exec` plugins, certificates);
/// Overterm only has to say which context is which. So the credential
/// fields — `client-key-data`, `token`, `password`, an auth provider's
/// tokens and secret — are blanked in the text before it is parsed
/// (`redacted`; a key on a line of its own, as kubectl writes them — one
/// inside a one-line `{…}` is dropped with the parser's copy), and only the
/// fields below ever leave the parser. A user's
/// auth is its kind; an `exec` plugin's arguments are kept to be shown
/// (an `aws sso login --profile` to offer), never to be logged
/// (`KubeExec.description` names the command alone).
struct Kubeconfig: Equatable, Sendable {
    struct Cluster: Equatable, Sendable {
        let name: String
        /// `server`, as written: `https://…`, `http://127.0.0.1:…`.
        let server: String?
        let file: URL?
    }

    struct User: Equatable, Sendable {
        let name: String
        let auth: KubeAuth
        let file: URL?
    }

    struct Context: Equatable, Sendable {
        let name: String
        let cluster: String
        let user: String
        /// The context's own namespace; nil when it names none ("default").
        let namespace: String?
        let file: URL?
    }

    var clusters: [Cluster] = []
    var users: [User] = []
    var contexts: [Context] = []
    var currentContext: String?

    /// The file's text read; nil when it isn't YAML (or JSON) holding a
    /// mapping. Sections it lacks are empty, as kubectl reads them.
    static func parse(_ text: String, file: URL? = nil) -> Kubeconfig? {
        guard let root = YAMLReader.parse(redacted(text)) as? [String: Any] else {
            // An empty file is an empty kubeconfig, as kubectl has it.
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Kubeconfig() : nil
        }
        var config = Kubeconfig()
        config.currentContext = (root["current-context"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        for item in root["clusters"] as? [Any] ?? [] {
            guard let item = item as? [String: Any], let name = item["name"] as? String else { continue }
            let cluster = item["cluster"] as? [String: Any] ?? [:]
            config.clusters.append(Cluster(name: name, server: cluster["server"] as? String, file: file))
        }
        for item in root["users"] as? [Any] ?? [] {
            guard let item = item as? [String: Any], let name = item["name"] as? String else { continue }
            config.users.append(User(name: name, auth: KubeAuth(user: item["user"] as? [String: Any] ?? [:]), file: file))
        }
        for item in root["contexts"] as? [Any] ?? [] {
            guard let item = item as? [String: Any], let name = item["name"] as? String else { continue }
            let context = item["context"] as? [String: Any] ?? [:]
            let namespace = (context["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            config.contexts.append(
                Context(
                    name: name, cluster: context["cluster"] as? String ?? "", user: context["user"] as? String ?? "",
                    namespace: namespace, file: file))
        }
        return config
    }

    /// kubectl's merge of the KUBECONFIG list: a context, cluster or user
    /// the first file to name it wins — later files never change it — and
    /// the current context is the first file's that sets one.
    static func merged(_ files: [Kubeconfig]) -> Kubeconfig {
        var out = Kubeconfig()
        var clusters = Set<String>()
        var users = Set<String>()
        var contexts = Set<String>()
        for file in files {
            if out.currentContext == nil { out.currentContext = file.currentContext }
            for cluster in file.clusters where clusters.insert(cluster.name).inserted { out.clusters.append(cluster) }
            for user in file.users where users.insert(user.name).inserted { out.users.append(user) }
            for context in file.contexts where contexts.insert(context.name).inserted { out.contexts.append(context) }
        }
        return out
    }

    /// The keys whose values sign a user in. Blanked before parsing, so no
    /// credential is ever in a value Overterm holds.
    static let credentialKeys = [
        "client-key-data", "token", "password", "id-token", "refresh-token", "access-token", "client-secret",
    ]

    /// `text` with every credential key's value on its line replaced by
    /// `""` — the key is kept, so the kind of auth still reads. A block
    /// scalar (`token: |`) is left for the parser, which drops it with the
    /// rest of what isn't read.
    static func redacted(_ text: String) -> String {
        let keys = credentialKeys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // key: value — the key on its own, or after a sequence's "- "; a
        // quoted key too. Not a block scalar's header (| or >).
        let pattern = #"(?m)^([ \t]*(?:-[ \t]+)?["']?(?:"# + keys + #")["']?[ \t]*:)[ \t]*(?![|>])(?=\S)[^\r\n]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1 \"\"")
    }
}

/// How a kubeconfig user signs in — the kind, never the secret.
enum KubeAuth: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// A credential plugin: `aws eks get-token`, `kubectl oidc-login`.
    case exec(KubeExec)
    /// A legacy auth provider (`oidc`; gcp and azure left kubectl in 1.26).
    case authProvider(String)
    /// A bearer token, in the file or in a `tokenFile`.
    case token
    /// A client certificate and key, in the file or beside it.
    case clientCertificate
    /// A user name and password.
    case basic
    /// Nothing the file says: an anonymous user, or one kubectl can't sign in.
    case none

    init(user: [String: Any]) {
        if let exec = user["exec"] as? [String: Any], let command = exec["command"] as? String, !command.isEmpty {
            self = .exec(KubeExec(exec: exec, command: command))
        } else if let provider = user["auth-provider"] as? [String: Any] {
            self = .authProvider(provider["name"] as? String ?? "")
        } else if user["token"] != nil || user["tokenFile"] != nil {
            self = .token
        } else if user["client-certificate-data"] != nil || user["client-certificate"] != nil || user["client-key-data"] != nil
            || user["client-key"] != nil
        {
            self = .clientCertificate
        } else if user["username"] != nil || user["password"] != nil {
            self = .basic
        } else {
            self = .none
        }
    }

    /// For the context card: "exec: aws", "client certificate".
    var description: String {
        switch self {
        case .exec(let exec): exec.description
        case .authProvider(let name): name.isEmpty ? "auth provider" : "auth provider: \(name)"
        case .token: "token"
        case .clientCertificate: "client certificate"
        case .basic: "user name and password"
        case .none: "none"
        }
    }

    var debugDescription: String { description }
}

/// A user's credential plugin, as the kubeconfig names it.
struct KubeExec: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// As written: `aws`, `/opt/homebrew/bin/aws`, `kubectl`.
    let command: String
    /// Shown where the user asks to see them, never logged: an argument
    /// can name an account, a role, a profile.
    let arguments: [String]
    /// The names of the variables the plugin is given; their values are not
    /// kept (an `AWS_SECRET_ACCESS_KEY` could be one).
    let environmentNames: [String]
    /// `client.authentication.k8s.io/v1beta1`, `…/v1`.
    let apiVersion: String?
    /// `Never`, `IfAvailable` or `Always`; nil when the file says none.
    /// `Always` needs a terminal, which a proxy started by Overterm lacks.
    let interactiveMode: String?
    /// What the plugin says to do when it isn't installed.
    let installHint: String?

    init(
        command: String, arguments: [String] = [], environmentNames: [String] = [], apiVersion: String? = nil,
        interactiveMode: String? = nil, installHint: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.environmentNames = environmentNames
        self.apiVersion = apiVersion
        self.interactiveMode = interactiveMode
        self.installHint = installHint
    }

    fileprivate init(exec: [String: Any], command: String) {
        let arguments = (exec["args"] as? [Any] ?? []).map { "\($0)" }
        let names = (exec["env"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String }
        self.init(
            command: command, arguments: arguments, environmentNames: names, apiVersion: exec["apiVersion"] as? String,
            interactiveMode: exec["interactiveMode"] as? String, installHint: exec["installHint"] as? String)
    }

    /// The plugin's own name: `aws`, `kubectl oidc-login`, `gke-gcloud-auth-plugin`
    /// — kubectl's first word when kubectl is the command (it is a
    /// subcommand, not an argument of the user's).
    var name: String {
        let tool = (command as NSString).lastPathComponent
        if tool == "kubectl", let first = arguments.first, !first.hasPrefix("-") { return "kubectl \(first)" }
        return tool
    }

    /// kubelogin, which opens a browser and listens on 127.0.0.1:8000: its
    /// proxies start one at a time.
    var isOIDCLogin: Bool { name == "kubectl oidc-login" || name == "kubectl-oidc_login" }

    var description: String { "exec: \(name)" }
    var debugDescription: String { description }
}
