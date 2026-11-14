import Foundation

/// Argo CD's `argocd.argoproj.io/tracking-id` annotation, read as Argo CD
/// reads it (docs/design/kubernetes/gitops.md, 14.1 and 14.6):
/// `<app>:<group>/<Kind>:<namespace>/<name>` — split on `:` into exactly
/// three parts, the second and third on `/` into exactly two.
///
/// - The app part is `Application.InstanceName`: `<name>` for an
///   Application in Argo CD's own namespace (unknown from here),
///   `<appNamespace>_<name>` otherwise.
/// - Core-group objects have an empty group: `shop:/Service:shop/api`.
/// - A cluster-scoped object's namespace part is the Application's
///   destination namespace, empty only when that is.
///
/// A mark counts only for the object it names (`isSelf`, Argo CD's
/// `isSelfReferencedObj`): the Deployment controller copies every
/// annotation of a Deployment onto its ReplicaSets, and operators copy
/// their resource's marks onto what they make — those name somebody else
/// and are nobody's member.
///
/// The value is the cluster's text, so it is checked before anything reads
/// it: at most 1,024 UTF-8 bytes, no control character, the app part and
/// the name at most 253 characters, the app `[a-z0-9._-]` with at most one
/// `_`, the group a DNS name or empty, the Kind `[A-Za-z0-9]` up to 63, the
/// namespace a DNS label or empty, the name a DNS subdomain. Anything else
/// is no tracking id. Pure.
struct KubeTrackingID: Equatable, Hashable, Sendable {
    /// `Application.InstanceName`: `name`, or `appNamespace_name`.
    var instance: String
    /// "" for the core group.
    var group: String
    var kind: String
    /// The object's namespace; a cluster-scoped object's is the
    /// Application's destination namespace, "" when that is empty.
    var namespace: String
    var name: String

    static let maxBytes = 1024
    static let maxName = 253
    static let maxLabel = 63

    /// The Application's own namespace, for an `<appNamespace>_<name>`
    /// app; nil means Argo CD's own namespace, unknown from here.
    var appNamespace: String? {
        guard let underscore = instance.firstIndex(of: "_") else { return nil }
        return String(instance[..<underscore])
    }

    /// The Application's name.
    var appName: String {
        guard let underscore = instance.firstIndex(of: "_") else { return instance }
        return String(instance[instance.index(after: underscore)...])
    }

    /// The app as the page names it: `payments/checkout-api`, or a bare
    /// `checkout-api` for one in Argo CD's own namespace.
    var said: String { appNamespace.map { "\($0)/\(appName)" } ?? appName }

    /// The value, checked; nil for anything Argo CD wouldn't write.
    static func parse(_ value: String) -> KubeTrackingID? {
        guard value.utf8.count <= maxBytes, !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let kindParts = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        let placeParts = parts[2].split(separator: "/", omittingEmptySubsequences: false)
        guard kindParts.count == 2, placeParts.count == 2 else { return nil }
        let id = KubeTrackingID(
            instance: String(parts[0]), group: String(kindParts[0]), kind: String(kindParts[1]), namespace: String(placeParts[0]),
            name: String(placeParts[1]))
        guard isInstance(id.instance), id.group.isEmpty || isSubdomain(id.group), isKind(id.kind), id.namespace.isEmpty || isLabel(id.namespace),
            isSubdomain(id.name)
        else { return nil }
        return id
    }

    /// The object a mark sits on, as its reader knows it: a list's kind
    /// and row, an object's own `apiVersion`, `kind` and metadata — never
    /// a row's embedded `PartialObjectMetadata`, whose kind is meta's.
    struct Identity: Equatable, Hashable, Sendable {
        /// "" for the core group.
        var group: String
        var kind: String
        /// nil for a cluster-scoped object.
        var namespace: String?
        var name: String

        var clusterScoped: Bool { namespace?.isEmpty ?? true }

        /// From an object as the API gives it: its `apiVersion`, `kind` and
        /// metadata; nil when it doesn't say its kind.
        static func of(_ object: [String: Any]?) -> Identity? {
            guard let object, let kind = object["kind"] as? String, !kind.isEmpty, let apiVersion = object["apiVersion"] as? String else { return nil }
            let metadata = object["metadata"] as? [String: Any]
            guard let name = metadata?["name"] as? String, !name.isEmpty else { return nil }
            let group = apiVersion.contains("/") ? String(apiVersion.split(separator: "/").first ?? "") : ""
            let namespace = (metadata?["namespace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Identity(group: group, kind: kind, namespace: namespace, name: name)
        }
    }

    /// Whether the mark names the object it sits on: its group, Kind and
    /// name, and its namespace unless the object is cluster-scoped — Argo
    /// CD's `isSelfReferencedObj`.
    func isSelf(group: String, kind: String, namespace: String?, name: String, clusterScoped: Bool) -> Bool {
        guard self.group == group, self.kind == kind, self.name == name else { return false }
        return clusterScoped || self.namespace == (namespace ?? "")
    }

    func isSelf(_ object: Identity) -> Bool {
        isSelf(group: object.group, kind: object.kind, namespace: object.namespace, name: object.name, clusterScoped: object.clusterScoped)
    }

    /// Which app a member belongs to: Argo CD's installation id (two Argo
    /// CDs deploying into one cluster are told apart by it) and the
    /// instance name.
    struct AppKey: Equatable, Hashable, Sendable, Comparable {
        /// "" when the mark carries none.
        var installation: String
        var instance: String

        static func < (a: AppKey, b: AppKey) -> Bool { (a.installation, a.instance) < (b.installation, b.instance) }
    }

    /// This mark's app under `installation`, the object's
    /// `argocd.argoproj.io/installation-id`; nil when that is malformed.
    func appKey(installation: String?) -> AppKey? {
        guard let installation, !installation.isEmpty else { return AppKey(installation: "", instance: instance) }
        guard let checked = Self.installation(installation) else { return nil }
        return AppKey(installation: checked, instance: instance)
    }

    static let installationAnnotation = "argocd.argoproj.io/installation-id"

    /// An app's instance name as a label carries it
    /// (`argocd.argoproj.io/instance`, `app.kubernetes.io/instance`),
    /// checked as the tracking id's app part is, and at most 63 characters
    /// — a label value's bound; nil for anything else.
    static func instanceLabel(_ value: String) -> String? {
        value.utf8.count <= maxLabel && isInstance(value) ? value : nil
    }

    /// An installation id, checked as the app part is: at most 63
    /// characters of `[a-z0-9._-]`.
    static func installation(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= maxLabel, value.utf8.allSatisfy({ isLowerAlphanumeric($0) || $0 == dot || $0 == dash || $0 == underscore })
        else { return nil }
        return value
    }

    // MARK: Character rules

    private static let dot = UInt8(ascii: "."), dash = UInt8(ascii: "-"), underscore = UInt8(ascii: "_")

    private static func isLowerAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// The app part: `[a-z0-9._-]`, at most one `_` with a name on each
    /// side, at most 253 characters.
    private static func isInstance(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= maxName else { return false }
        guard bytes.allSatisfy({ isLowerAlphanumeric($0) || $0 == dot || $0 == dash || $0 == underscore }) else { return false }
        let underscores = bytes.indices.filter { bytes[$0] == underscore }
        guard underscores.count <= 1 else { return false }
        if let at = underscores.first { return at > 0 && at < bytes.count - 1 }
        return true
    }

    /// A Kind: `[A-Za-z0-9]`, 1 to 63 characters.
    private static func isKind(_ text: String) -> Bool {
        let bytes = text.utf8
        return !bytes.isEmpty && bytes.count <= maxLabel
            && bytes.allSatisfy { isLowerAlphanumeric($0) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }
    }

    /// `[a-z0-9]([-a-z0-9]*[a-z0-9])?`: one part of a DNS name.
    private static func isPart(_ text: Substring) -> Bool {
        let bytes = text.utf8
        guard let first = bytes.first, let last = bytes.last else { return false }
        return isLowerAlphanumeric(first) && isLowerAlphanumeric(last) && bytes.allSatisfy { isLowerAlphanumeric($0) || $0 == dash }
    }

    /// A DNS label (RFC 1123), as a namespace is: one part, at most 63.
    static func isLabel(_ text: String) -> Bool { text.utf8.count <= maxLabel && isPart(Substring(text)) }

    /// A DNS subdomain (RFC 1123), as most objects' names are: parts
    /// joined by `.`, at most 253 in all — Kubernetes caps no part alone.
    static func isSubdomain(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maxName else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { isPart($0) }
    }
}
