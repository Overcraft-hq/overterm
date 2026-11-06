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
    /// False: no shell or attach from Overterm on this context (rule 5);
    /// unset, they are offered after `kubectl auth can-i`.
    var shells: Bool?
    /// The image `E` debugs a pod with (and a node, when `nodeShellImage`
    /// is unset); unset, `kubernetes.debugImage`.
    var debugImage: String?
    /// The image a node is debugged with (one with the host's tools, say);
    /// unset, `debugImage`, then `kubernetes.debugImage`.
    var nodeShellImage: String?
    /// On: a node shell (`kubectl debug node/… --profile=sysadmin`) on
    /// a writable context, its name typed; unset or off, it is refused.
    var nodeShell: Bool?
    /// On: Apply from the editor (and agents' `k8s_apply`) is offered on
    /// this production context while its writes are on for the session,
    /// the name typed and never forced (decision 30); unset or off, a
    /// production context only diffs. Ignored on any other class.
    var applyOnProduction: Bool?
    /// Where usage comes from: metrics-server when served (unset), or
    /// `none` — no usage columns, and metrics.k8s.io never asked;
    /// `prometheus` (or `auto` set here) looks for Prometheus too (stage 4).
    var metrics: KubeMetricsSource?
    /// The Prometheus Service, `namespace/service:port`, instead of looking
    /// for one; it opts the context in unless `metrics` says otherwise.
    var prometheus: String?

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
        SettingField(
            name: "shells", kind: .toggle,
            help: "Off: Overterm opens no shell or attach in this context's pods. On or unset, they are offered once kubectl auth can-i allows them."),
        SettingField(
            name: "debugImage", kind: .text(placeholder: "busybox:1.36", monospaced: true),
            help: "The image a debug container (E) runs; else Kubernetes' debug image setting."),
        SettingField(
            name: "nodeShellImage", kind: .text(placeholder: "busybox:1.36", monospaced: true),
            help: "The image a node shell's privileged pod runs (E on a node; it needs chroot); else this context's debugImage, then Kubernetes' debug image setting."),
        SettingField(
            name: "nodeShell", kind: .toggle,
            help: "On: a node shell (kubectl debug node/… --profile=sysadmin, chrooted into the node) on this context when it is writable, the node's name typed. Off by default."),
        SettingField(
            name: "applyOnProduction", kind: .toggle,
            help:
                "Production only: On lets Apply from the editor (and agents' k8s_apply) change this context while its writes are on for the session — the name typed, never forced. Off by default: production only diffs."
        ),
        SettingField(
            name: "metrics", kind: .choice(KubeMetricsSource.allCases.map { SettingOption(value: $0.rawValue, label: $0.title) }),
            help:
                "Where CPU and memory come from. Unset: metrics-server, when the cluster serves metrics.k8s.io. prometheus (or auto set here): Prometheus too, found as Lens and Freelens find it — charts with a time range, PVC usage, requests and limits — reached only through a second proxy that accepts its query paths alone. metricsServer: never Prometheus. none: no usage, nothing asked."
        ),
        SettingField(
            name: "prometheus", kind: .text(placeholder: "monitoring/prometheus-server:80", monospaced: true),
            help:
                "The Prometheus Service as namespace/service:port, instead of looking for one (lens-metrics/prometheus, the Helm chart's, the operator's). Setting it opts the context in, unless metrics is none or metricsServer."
        ),
    ]

    init(
        contextClass: KubeContextClass? = nil, writable: Bool? = nil, displayName: String? = nil, defaultNamespace: String? = nil,
        accessibleNamespaces: [String] = [], favouriteNamespaces: [String] = [], terminalDirectory: String? = nil, shells: Bool? = nil,
        debugImage: String? = nil, nodeShellImage: String? = nil, nodeShell: Bool? = nil, applyOnProduction: Bool? = nil,
        metrics: KubeMetricsSource? = nil, prometheus: String? = nil
    ) {
        self.contextClass = contextClass
        self.writable = writable
        self.displayName = displayName
        self.defaultNamespace = defaultNamespace
        self.accessibleNamespaces = accessibleNamespaces
        self.favouriteNamespaces = favouriteNamespaces
        self.terminalDirectory = terminalDirectory
        self.shells = shells
        self.debugImage = debugImage
        self.nodeShellImage = nodeShellImage
        self.nodeShell = nodeShell
        self.applyOnProduction = applyOnProduction
        self.metrics = metrics
        self.prometheus = prometheus
    }

    init(fields: [String: SettingValue]) {
        contextClass = fields["class"]?.string.flatMap(KubeContextClass.init(rawValue:))
        writable = fields["writable"]?.bool
        displayName = fields["displayName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        defaultNamespace = fields["defaultNamespace"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        accessibleNamespaces = fields["accessibleNamespaces"]?.list ?? []
        favouriteNamespaces = fields["favouriteNamespaces"]?.list ?? []
        terminalDirectory = fields["terminalDirectory"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        shells = fields["shells"]?.bool
        debugImage = Self.image(fields["debugImage"])
        nodeShellImage = Self.image(fields["nodeShellImage"])
        nodeShell = fields["nodeShell"]?.bool
        applyOnProduction = fields["applyOnProduction"]?.bool
        metrics = fields["metrics"]?.string.flatMap(KubeMetricsSource.init(rawValue:))
        prometheus = fields["prometheus"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
    }

    /// An image field's value, trimmed; empty, unset.
    private static func image(_ value: SettingValue?) -> String? {
        value?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Every context's, from the setting's value.
    static func all(from value: SettingValue?) -> [String: KubeContextSettings] {
        (value?.entries ?? [:]).mapValues(KubeContextSettings.init(fields:))
    }
}
