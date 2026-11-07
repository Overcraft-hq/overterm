import Foundation

/// A context's settings in one place (the context card, the sidebar
/// context row's menu): its `kubernetes.contexts` entry — class, writable,
/// metrics and the Prometheus Service, the node shell and its image, the
/// default namespace —, whether `kubernetes.agentWrites` names it, and
/// `applyOnProduction`. Edited here, written back as settings.json's two
/// keys (`Settings.set`, through `SettingsJSON` — in place, the file's
/// comments kept, an entry's with it), the fields it writes checked by
/// `SettingsSchema` first. Built on the file's own values
/// (`Settings.fileValue`, not fitted), so the entry's other fields
/// (displayName, debugImage, the namespace lists…, and fields this build
/// doesn't know) and every other entry are kept as they are. A production
/// context made less strict — its class by name or by its entry
/// production, saved as another — needs its name typed (`typedName`).
/// Production's session write switch is not a setting (decision 4): only
/// shown, never written. Pure.
struct KubeContextSettingsDraft: Equatable, Sendable {
    let context: String
    /// The class its name gives, for "Unset: by name (…)".
    let classByName: KubeContextClass
    /// Production's switch for this session — shown, never a setting.
    let sessionWrites: Bool

    /// Nil: its name decides.
    var contextClass: KubeContextClass?
    /// Nil: its class's default (local writable, remote not).
    var writable: Bool?
    var metrics: KubeMetricsSource?
    var prometheus: String
    var nodeShell: Bool
    var nodeShellImage: String
    var defaultNamespace: String
    var agentWrites: Bool
    var applyOnProduction: Bool
    /// Why Save didn't write, until something is changed.
    var problem: String?
    /// Save asked for the name, a production context being made less strict.
    var confirmingLessStrict = false
    /// The name typed for it.
    var typedName = ""
    /// Its entry's class when the sheet opened.
    let savedClass: KubeContextClass?
    /// What its fields said when the sheet opened (`fields`): one the sheet
    /// leaves as it was is the file's to keep, a value this build can't
    /// read included.
    private(set) var opened: [String: SettingValue?] = [:]

    static let contextsKey = "kubernetes.contexts"
    static let agentWritesKey = "kubernetes.agentWrites"

    /// The draft of `context` as the settings hold it now: `contexts`,
    /// `kubernetes.contexts`'s value; `agentWrites`, the list's.
    init(context: KubeContext, contexts: SettingValue?, agentWrites: [String]) {
        self.context = context.name
        classByName = KubeClassifier.classify(context: context.name, cluster: context.cluster, set: nil)
        sessionWrites = context.sessionWrites
        let settings = KubeContextSettings(fields: contexts?.entries?[context.name] ?? [:])
        contextClass = settings.contextClass
        savedClass = settings.contextClass
        writable = settings.writable
        metrics = settings.metrics
        prometheus = settings.prometheus ?? ""
        nodeShell = settings.nodeShell ?? false
        nodeShellImage = settings.nodeShellImage ?? ""
        defaultNamespace = settings.defaultNamespace ?? ""
        self.agentWrites = agentWrites.contains(context.name)
        applyOnProduction = settings.applyOnProduction ?? false
        opened = fields
    }

    /// The entry's fields the sheet holds, as the draft says them now: nil
    /// takes the field out. `writable` isn't one on production (no switch).
    var fields: [String: SettingValue?] {
        func text(_ value: String) -> SettingValue? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .string(trimmed)
        }
        var said: [String: SettingValue?] = [
            "class": contextClass.map { .string($0.rawValue) },
            "metrics": metrics.map { .string($0.rawValue) },
            "prometheus": text(prometheus),
            "nodeShell": nodeShell ? .bool(true) : nil,
            "nodeShellImage": text(nodeShellImage),
            "defaultNamespace": text(defaultNamespace),
            "applyOnProduction": applyOnProduction ? .bool(true) : nil,
        ]
        // Ignored on production; kept out of a production entry so it can't read as a switch.
        if resolvedClass != .production { said["writable"] = .some(writable.map { .bool($0) }) }
        return said
    }

    /// The class it will have.
    var resolvedClass: KubeContextClass { contextClass ?? classByName }
    var isProduction: Bool { resolvedClass == .production }

    /// What writable means for it, as the page will treat it.
    var writableSaid: String {
        switch resolvedClass {
        case .production:
            sessionWrites
                ? "Production: writes are on for this session, until Overterm quits — never by a setting."
                : "Production: read-only. Writes are turned on for a session from the context card, never by a setting."
        case .remote: (writable ?? false) ? "Writable." : "Read-only" + (writable == nil ? " (a remote context's default)." : ".")
        case .local: (writable ?? true) ? "Writable" + (writable == nil ? " (a local context's default)." : ".") : "Read-only."
        }
    }

    /// Whether saving makes a production context — by its name, or by
    /// `entry`'s class (the one opened, or as the file has it now) —
    /// something else: what Section 5 lets only an explicit act do, so it
    /// is asked in red with the name typed, as rule 4 asks it.
    func lessStrict(entry: [String: SettingValue]?) -> Bool {
        guard resolvedClass != .production else { return false }
        return classByName == .production || savedClass == .production || entry?["class"]?.string == KubeContextClass.production.rawValue
    }

    /// What making it less strict leads to, said before the name is typed.
    var lessStrictSaid: String {
        let becomes = resolvedClass.title.lowercased()
        let writes =
            switch resolvedClass {
            case .production: ""
            case .local:
                (writable ?? true)
                    ? "it is writable — by this setting, every day, not by a switch turned on for a session"
                    : "it stays read-only until Writes says otherwise, no longer asked for a session"
            case .remote:
                (writable ?? false)
                    ? "it is writable — by this setting, every day, not by a switch turned on for a session"
                    : "it stays read-only until Writes says otherwise, no longer asked for a session"
            }
        return "\(context) is production. Saved as \(becomes), it no longer is: \(writes), its page and tabs lose the red band"
            + (agentWrites ? ", and agents may change it (kubernetes.agentWrites)" : "")
            + ". Type \(context) to confirm."
    }

    /// Why the draft won't do, before anything is written; nil when it will.
    var validation: String? {
        let prometheus = prometheus.trimmingCharacters(in: .whitespaces)
        if !prometheus.isEmpty, KubePrometheusService(setting: prometheus) == nil {
            return "The Prometheus Service is namespace/service:port — \(prometheus) isn't."
        }
        let image = nodeShellImage.trimmingCharacters(in: .whitespaces)
        if !image.isEmpty, DockerImageReference(image) == nil { return "\(image) isn't an image reference (name[:tag][@digest])." }
        let namespace = defaultNamespace.trimmingCharacters(in: .whitespaces)
        if !namespace.isEmpty, let problem = KubeNamespaceName.problem(namespace) { return "Default namespace: \(problem)" }
        return nil
    }

    /// The two settings with the draft in them: `kubernetes.contexts` with
    /// this context's entry changed — its other fields, and every other
    /// entry, as they were; an entry left empty taken out — and
    /// `kubernetes.agentWrites` naming it or not. A failure says why, and
    /// nothing is written.
    func applied(contexts: SettingValue?, agentWrites: [String]) -> Result<(contexts: SettingValue, agentWrites: [String]), KubeCommands.Refused> {
        if let validation { return .failure(KubeCommands.Refused(reason: validation)) }
        var entries = contexts?.entries ?? [:]
        var fields = entries[context] ?? [:]
        if lessStrict(entry: fields), typedName.trimmingCharacters(in: .whitespaces) != context {
            return .failure(
                KubeCommands.Refused(
                    reason: "\(context) is production: making it \(resolvedClass.title.lowercased()) needs its name typed. Nothing was written."))
        }
        // The fields the draft changed, checked below; the others are the file's, as they were.
        var said: [String: SettingValue] = [:]
        for (name, value) in self.fields where opened[name] != .some(value) {
            fields[name] = value
            if let value { said[name] = value }
        }
        if fields.isEmpty { entries[context] = nil } else { entries[context] = fields }
        let value = SettingValue.entries(entries)
        // SettingsSchema's own check of this entry: what the page and the file are held to.
        if let spec = SettingsSchema.byKey[Self.contextsKey] {
            if let problem = spec.problem(with: value) { return .failure(KubeCommands.Refused(reason: problem)) }
            let (_, problems) = spec.fitted(.entries([context: said]))
            if let first = problems.first { return .failure(KubeCommands.Refused(reason: first)) }
        }
        var names = agentWrites.filter { $0 != context }
        if self.agentWrites {
            names = agentWrites.contains(context) ? agentWrites : agentWrites + [context]
        }
        if let spec = SettingsSchema.byKey[Self.agentWritesKey], let problem = spec.problem(with: .list(names)) {
            return .failure(KubeCommands.Refused(reason: problem))
        }
        return .success((value, names))
    }
}
