import Foundation

/// What kind of cluster a context reaches, and so what Overterm may do there.
///
/// docs/design/kubernetes/analysis.md, Section 5. Production is read-only
/// and red everywhere, its writes turned on for a session only; a remote
/// context is read-only unless its `writable` flag says otherwise; a local
/// one is writable unless it says otherwise.
enum KubeContextClass: String, CaseIterable, Sendable {
    case production, remote, local

    var title: String {
        switch self {
        case .production: "Production"
        case .remote: "Remote"
        case .local: "Local"
        }
    }
}

/// Which class a context is: decision 31's precedence, first match wins —
///
/// 1. a class set by hand (`kubernetes.contexts`);
/// 2. production by name: the context's or the cluster's, so
///    `kind-prod-copy` is production although it starts with `kind-`;
/// 3. local by name: Docker Desktop, OrbStack, minikube, Rancher Desktop,
///    Colima, `kind-…`, `k3d-…`;
/// 4. remote.
///
/// The server's address never makes a context local: an SSH tunnel or a
/// bastion's forward to a remote cluster is on 127.0.0.1 too.
enum KubeClassifier {
    /// `prod`, `prd`, `production` or `live` as a word of the name, split
    /// on `-`, `_`, `/`, `.`, `:` or `@` — so EKS's ARNs
    /// (`…:cluster/acme-prod`) and kubeadm's `user@cluster`
    /// (`kubernetes-admin@prod`) match and `product-api` or `delivery` don't.
    static let productionPattern = #"(^|[-_/.:@])(prod|prd|production|live)([-_/.:@]|$)"#

    static let localNames: Set<String> = ["docker-desktop", "orbstack", "minikube", "rancher-desktop", "colima"]
    static let localPrefixes = ["kind-", "k3d-"]

    private static let production = try! NSRegularExpression(pattern: productionPattern, options: [.caseInsensitive])

    static func isProduction(name: String) -> Bool {
        production.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func isLocal(name: String) -> Bool {
        localNames.contains(name) || localPrefixes.contains { name.hasPrefix($0) }
    }

    static func classify(context: String, cluster: String?, set: KubeContextClass?) -> KubeContextClass {
        if let set { return set }
        if isProduction(name: context) || cluster.map(isProduction(name:)) == true { return .production }
        if isLocal(name: context) { return .local }
        return .remote
    }

    /// Whether Overterm may change objects through a context of `kind`.
    /// A production context ignores the `writable` flag: its writes are
    /// turned on for this session from the context's card, never by a
    /// setting (decision 4). Without a flag, local is writable and remote
    /// isn't.
    static func isWritable(_ kind: KubeContextClass, flag: Bool?, productionSession: Bool = false) -> Bool {
        switch kind {
        case .production: productionSession
        case .remote: flag ?? false
        case .local: flag ?? true
        }
    }
}

/// A context's own settings: its entry in `kubernetes.contexts`, by name.
/// The only place a context's settings live (decision 32); more fields join
/// with the stages that read them.
struct KubeContextSettings: Equatable, Sendable {
    /// Set by hand; nil: its name decides.
    var contextClass: KubeContextClass?
    /// Whether a remote or local context may be written to; ignored on production.
    var writable: Bool?
    var displayName: String?
    /// The namespace the page opens on, instead of the context's own.
    var defaultNamespace: String?
    /// When set, the namespace list is never asked for (RBAC may refuse it).
    var accessibleNamespaces: [String] = []
    /// At the top of the namespace picker.
    var favouriteNamespaces: [String] = []
    /// Where a Terminal in this context opens (`~` allowed); unset or not a
    /// folder, the home folder.
    var terminalDirectory: String?

    /// What an entry may hold, for SettingsSchema to check.
    static let fields: [SettingField] = [
        SettingField(
            name: "class", kind: .choice(KubeContextClass.allCases.map { SettingOption(value: $0.rawValue, label: $0.title) }),
            help: "production, remote or local; unset, the context's name decides."),
        SettingField(name: "writable", kind: .toggle, help: "A remote or local context Overterm may change objects in. Never a production one."),
        SettingField(name: "displayName", kind: .text(placeholder: "", monospaced: false)),
        SettingField(name: "defaultNamespace", kind: .text(placeholder: "", monospaced: true)),
        SettingField(name: "accessibleNamespaces", kind: .list(placeholder: "")),
        SettingField(name: "favouriteNamespaces", kind: .list(placeholder: "")),
        SettingField(
            name: "terminalDirectory", kind: .text(placeholder: "~/src/shop", monospaced: true),
            help: "Where Terminal in this context opens; else the home folder."),
    ]

    init(
        contextClass: KubeContextClass? = nil, writable: Bool? = nil, displayName: String? = nil, defaultNamespace: String? = nil,
        accessibleNamespaces: [String] = [], favouriteNamespaces: [String] = [], terminalDirectory: String? = nil
    ) {
        self.contextClass = contextClass
        self.writable = writable
        self.displayName = displayName
        self.defaultNamespace = defaultNamespace
        self.accessibleNamespaces = accessibleNamespaces
        self.favouriteNamespaces = favouriteNamespaces
        self.terminalDirectory = terminalDirectory
    }

    init(fields: [String: SettingValue]) {
        contextClass = fields["class"]?.string.flatMap(KubeContextClass.init(rawValue:))
        writable = fields["writable"]?.bool
        displayName = fields["displayName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        defaultNamespace = fields["defaultNamespace"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        accessibleNamespaces = fields["accessibleNamespaces"]?.list ?? []
        favouriteNamespaces = fields["favouriteNamespaces"]?.list ?? []
        terminalDirectory = fields["terminalDirectory"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every context's, from the setting's value.
    static func all(from value: SettingValue?) -> [String: KubeContextSettings] {
        (value?.entries ?? [:]).mapValues(KubeContextSettings.init(fields:))
    }
}
