import Foundation

/// One kind the cluster serves, as discovery says it: where its objects
/// are, whether they live in a namespace, what may be done with them.
struct KubeResourceKind: Hashable, Sendable, CustomStringConvertible {
    /// "" for the core group.
    var group: String
    var version: String
    /// The plural in paths: `pods`, `deployments`.
    var resource: String
    var kind: String
    var singular: String
    var namespaced: Bool
    var verbs: [String]
    var shortNames: [String] = []
    var categories: [String] = []
    /// `log`, `exec`, `status`, `scale`…
    var subresources: [String] = []

    var groupVersion: String { group.isEmpty ? version : "\(group)/\(version)" }
    /// `deployments.apps`, `pods`: kubectl's full name.
    var fullName: String { group.isEmpty ? resource : "\(resource).\(group)" }
    var description: String { fullName }

    var canList: Bool { verbs.contains("list") }
    var canWatch: Bool { verbs.contains("watch") }

    /// The collection's path (in `namespace` when the kind lives in one and
    /// one is given), or one object's.
    func path(namespace: String? = nil, name: String? = nil) -> String {
        var path = group.isEmpty ? "/api/\(version)" : "/apis/\(group)/\(version)"
        if namespaced, let namespace { path += "/namespaces/\(KubePath.segment(namespace))" }
        path += "/\(resource)"
        if let name { path += "/\(KubePath.segment(name))" }
        return path
    }

    static let pods = KubeResourceKind(
        group: "", version: "v1", resource: "pods", kind: "Pod", singular: "pod", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"], shortNames: ["po"], categories: ["all"],
        subresources: ["attach", "binding", "ephemeralcontainers", "eviction", "exec", "log", "portforward", "proxy", "resize", "status"])
    static let namespaces = KubeResourceKind(
        group: "", version: "v1", resource: "namespaces", kind: "Namespace", singular: "namespace", namespaced: false,
        verbs: ["create", "delete", "get", "list", "patch", "update", "watch"], shortNames: ["ns"], subresources: ["finalize", "status"])
}

/// What the cluster serves: every kind of every group's preferred version,
/// and the groups that couldn't say (an aggregated API that is down
/// answers 503; the rest of the cluster still works).
struct KubeDiscovery: Equatable, Sendable {
    var kinds: [KubeResourceKind]
    /// By group version, what it answered.
    var failedGroups: [String: String] = [:]
    /// Read from aggregated discovery (one request each for `/api` and
    /// `/apis`), not the legacy walk.
    var aggregated = false

    /// A kind by any of kubectl's names for it: `po`, `pod`, `pods`, `Pod`,
    /// `deployments.apps`, `deploy`. The core group first, then the order
    /// the server listed them in — as kubectl resolves `events`.
    func kind(_ name: String) -> KubeResourceKind? {
        let wanted = name.lowercased()
        if let dot = wanted.firstIndex(of: "."), !kinds.contains(where: { $0.resource == wanted }) {
            let resource = String(wanted[..<dot])
            let group = String(wanted[wanted.index(after: dot)...])
            return kinds.first { $0.group == group && ($0.resource == resource || $0.singular == resource || $0.kind.lowercased() == resource) }
        }
        let ordered = kinds.filter { $0.group.isEmpty } + kinds.filter { !$0.group.isEmpty }
        return ordered.first { $0.resource == wanted } ?? ordered.first { $0.singular == wanted } ?? ordered.first { $0.shortNames.contains(wanted) }
            ?? ordered.first { $0.kind.lowercased() == wanted }
    }

    // MARK: Reading

    /// What a discovery answer is: aggregated (`APIGroupDiscoveryList`),
    /// legacy core (`APIVersions`), a legacy group list (`APIGroupList`).
    enum Answer: Equatable {
        /// The kinds, and the group versions marked `Stale`.
        case aggregated([KubeResourceKind], stale: [String: String])
        case coreVersions([String])
        /// Each group's preferred group version.
        case groups([String])
    }

    static func answer(_ data: Data) throws -> Answer {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KubeTableReader.Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        switch object["kind"] as? String {
        case "APIGroupDiscoveryList":
            let (kinds, stale) = aggregatedKinds(object)
            return .aggregated(kinds, stale: stale)
        case "APIVersions": return .coreVersions(object["versions"] as? [String] ?? [])
        case "APIGroupList":
            let groups = (object["groups"] as? [[String: Any]] ?? []).compactMap { group -> String? in
                let preferred = group["preferredVersion"] as? [String: Any]
                let first = (group["versions"] as? [[String: Any]])?.first
                return (preferred?["groupVersion"] ?? first?["groupVersion"]) as? String
            }
            return .groups(groups)
        case let kind: throw KubeTableReader.Malformed(detail: kind ?? "no kind")
        }
    }

    /// What an aggregated list's version that is down says.
    static let staleMessage = "Stale: the aggregated API isn't answering."

    /// An aggregated list's kinds: each group's first version that isn't
    /// `Stale` (the server lists them by preference), subresources folded
    /// into their kind; and the versions that are. The apiserver marks an
    /// aggregated API that is down (metrics.k8s.io's, often) `Stale` rather
    /// than leaving it out, as client-go reads it.
    static func aggregatedKinds(_ object: [String: Any]) -> (kinds: [KubeResourceKind], stale: [String: String]) {
        var kinds: [KubeResourceKind] = []
        var stale: [String: String] = [:]
        for item in object["items"] as? [[String: Any]] ?? [] {
            let group = (item["metadata"] as? [String: Any])?["name"] as? String ?? ""
            var chosen: (version: [String: Any], name: String)?
            for version in item["versions"] as? [[String: Any]] ?? [] {
                guard let name = version["version"] as? String else { continue }
                if version["freshness"] as? String == "Stale" {
                    stale[group.isEmpty ? name : "\(group)/\(name)"] = staleMessage
                } else if chosen == nil {
                    chosen = (version, name)
                }
            }
            guard let (version, name) = chosen else { continue }
            for resource in version["resources"] as? [[String: Any]] ?? [] {
                guard let plural = resource["resource"] as? String else { continue }
                let response = resource["responseKind"] as? [String: Any]
                let kind = response?["kind"] as? String ?? ""
                kinds.append(
                    KubeResourceKind(
                        group: group, version: name, resource: plural, kind: kind,
                        singular: (resource["singularResource"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? kind.lowercased(),
                        namespaced: resource["scope"] as? String == "Namespaced", verbs: resource["verbs"] as? [String] ?? [],
                        shortNames: resource["shortNames"] as? [String] ?? [], categories: resource["categories"] as? [String] ?? [],
                        subresources: (resource["subresources"] as? [[String: Any]] ?? []).compactMap { $0["subresource"] as? String }))
            }
        }
        return (kinds, stale)
    }

    /// A legacy `APIResourceList`: `pods/log` and the like are its kinds'
    /// subresources, not kinds.
    static func resourceList(_ data: Data) throws -> [KubeResourceKind] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["kind"] as? String == "APIResourceList",
            let groupVersion = object["groupVersion"] as? String
        else { throw KubeTableReader.Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self)) }
        let parts = groupVersion.split(separator: "/", maxSplits: 1).map(String.init)
        let (group, version) = parts.count == 2 ? (parts[0], parts[1]) : ("", parts.first ?? "")
        let resources = object["resources"] as? [[String: Any]] ?? []
        var kinds: [KubeResourceKind] = []
        var subresources: [String: [String]] = [:]
        for resource in resources {
            guard let name = resource["name"] as? String else { continue }
            if let slash = name.firstIndex(of: "/") {
                subresources[String(name[..<slash]), default: []].append(String(name[name.index(after: slash)...]))
                continue
            }
            let kind = resource["kind"] as? String ?? ""
            kinds.append(
                KubeResourceKind(
                    group: group, version: version, resource: name, kind: kind,
                    singular: (resource["singularName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? kind.lowercased(),
                    namespaced: resource["namespaced"] as? Bool ?? false, verbs: resource["verbs"] as? [String] ?? [],
                    shortNames: resource["shortNames"] as? [String] ?? [], categories: resource["categories"] as? [String] ?? []))
        }
        return kinds.map { kind in
            var kind = kind
            kind.subresources = subresources[kind.resource] ?? []
            return kind
        }
    }
}

/// Paths and queries as the API server reads them. Pure.
enum KubePath {
    /// What may stand unescaped: RFC 3986's unreserved characters.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// One path segment: a `/` in a name can't make it another path.
    static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// `path?name=value&…`, every value escaped (a selector's `=` and `,` too).
    static func query(_ path: String, _ items: [(String, String?)]) -> String {
        let pairs = items.compactMap { name, value in value.map { "\(segment(name))=\(segment($0))" } }
        return pairs.isEmpty ? path : path + "?" + pairs.joined(separator: "&")
    }
}
