import Foundation

/// One test run's containers, as Testcontainers made them: its session,
/// what each library writes on everything it starts.
package struct TestcontainersSession: Identifiable, Equatable, Sendable {
    /// The session as written: a UUID from Java, Node, Python and .NET, a
    /// hash from Go. Empty for the containers in no session — kept for
    /// reuse, which no reaper is told of.
    package var id: String
    /// By when they were made, then name; Ryuk last.
    package var containers: [ContainerSummary]

    /// The test's own containers, Ryuk left out: what its row counts and a
    /// selection of it means.
    package var members: [ContainerSummary] { containers.filter { !Testcontainers.isReaper($0) } }
    package var reaper: ContainerSummary? { containers.first(where: Testcontainers.isReaper) }
    /// `java`, `go`, `node`, `python`, `dotnet`.
    package var lang: String? { label(Testcontainers.langLabel) }
    /// The library's version.
    package var version: String? { label(Testcontainers.versionLabel) }
    /// When its first container was made — Ryuk, usually.
    package var started: Int { containers.map(\.Created).min() ?? 0 }
    package var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(started)) }
    package var running: Int { members.filter { $0.state == .running }.count }
    /// No session, and every one of it kept for reuse.
    package var reused: Bool { id.isEmpty && !members.isEmpty && members.allSatisfy(Testcontainers.isReused) }
    package var shortID: String { String(id.prefix(8)) }
    /// What its row says after "Testcontainers": the library, the run.
    package var subtitle: String { [lang, reused ? "reused" : id.isEmpty ? "no session" : shortID].compactMap { $0 }.joined(separator: " · ") }

    /// The first container's that says it. A loop, read once: a lazy
    /// `compactMap.first` reads it twice (CLAUDE.md).
    private func label(_ key: String) -> String? {
        for container in containers {
            if let value = container.labels[key], !value.isEmpty { return value }
        }
        return nil
    }
}

/// A test run's containers are found by their labels, as Ryuk finds them.
/// Every library marks what it starts `org.testcontainers=true`, with its
/// language and version; the session's key is the library's own: Java and
/// Go write `org.testcontainers.sessionId`, Node, Python and .NET
/// `org.testcontainers.session-id` (.NET `…resource-reaper-session` too).
/// Ryuk, the reaper, carries no session where Java and Python start it,
/// and is named after the session instead: `testcontainers-ryuk-<session>`,
/// Go's `reaper_<session>`. Pure.
package enum Testcontainers {
    package static let marker = "org.testcontainers"
    package static let sessionLabels = ["org.testcontainers.sessionId", "org.testcontainers.session-id", "org.testcontainers.resource-reaper-session"]
    package static let langLabel = "org.testcontainers.lang"
    package static let versionLabel = "org.testcontainers.version"
    /// What a container kept for reuse carries: Java's, Node's, .NET's.
    package static let reuseLabels = ["org.testcontainers.hash", "org.testcontainers.container-hash", "org.testcontainers.reuse-hash"]
    package static let reaperNamePrefixes = ["testcontainers-ryuk-", "reaper_"]

    /// `testcontainers/ryuk:0.14.0`, from Docker Hub or a mirror of it
    /// (`TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX`), by tag or digest.
    package static func isRyukImage(_ image: String) -> Bool {
        var name = Substring(image)
        if let at = name.firstIndex(of: "@") { name = name[..<at] }
        // A tag is after the last slash; a colon before it is a registry's port.
        if let colon = name.lastIndex(of: ":"), name.lastIndex(of: "/").map({ colon > $0 }) ?? true { name = name[..<colon] }
        let lower = name.lowercased()
        return lower == "testcontainers/ryuk" || lower.hasSuffix("/testcontainers/ryuk")
    }

    /// Ryuk: by Go's labels, its image, or its name (a custom image).
    package static func isReaper(_ container: ContainerSummary) -> Bool {
        let labels = container.labels
        return labels["org.testcontainers.ryuk"] == "true" || labels["org.testcontainers.reaper"] == "true" || isRyukImage(container.Image)
            || container.name.hasPrefix("testcontainers-ryuk-")
    }

    package static func isMember(_ container: ContainerSummary) -> Bool {
        container.labels[marker]?.lowercased() == "true" || isReaper(container)
    }

    package static func isReused(_ container: ContainerSummary) -> Bool {
        reuseLabels.contains { container.labels[$0]?.isEmpty == false }
    }

    /// The session a container's or a network's labels say.
    package static func session(labels: [String: String]) -> String? {
        for key in sessionLabels {
            if let value = labels[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// Its labels' session, else, for Ryuk, the one its name says.
    package static func session(of container: ContainerSummary) -> String? {
        if let session = session(labels: container.labels) { return session }
        guard isReaper(container) else { return nil }
        for prefix in reaperNamePrefixes where container.name.hasPrefix(prefix) && container.name.count > prefix.count {
            return String(container.name.dropFirst(prefix.count))
        }
        return nil
    }

    /// Which run's block it goes in: its session, "" for one of
    /// Testcontainers' in none, nil for one that isn't Testcontainers'.
    package static func groupID(of container: ContainerSummary) -> String? {
        guard isMember(container) else { return nil }
        return session(of: container) ?? ""
    }

    /// Testcontainers' containers taken out, a run each — the newest run
    /// first, those in no run last — and the rest as they came.
    package static func sessions(_ containers: [ContainerSummary]) -> (sessions: [TestcontainersSession], rest: [ContainerSummary]) {
        var bySession: [String: [ContainerSummary]] = [:]
        var rest: [ContainerSummary] = []
        for container in containers {
            if let id = groupID(of: container) {
                bySession[id, default: []].append(container)
            } else {
                rest.append(container)
            }
        }
        let sessions = bySession.map { id, members in TestcontainersSession(id: id, containers: members.sorted(by: order)) }
            .sorted { a, b in
                if a.id.isEmpty != b.id.isEmpty { return !a.id.isEmpty }
                return a.started != b.started ? a.started > b.started : a.id < b.id
            }
        return (sessions, rest)
    }

    /// The networks a run made: labelled with its session, as Ryuk finds
    /// them. None for the containers in no run.
    package static func networks(of session: String, in networks: [NetworkSummary]) -> [NetworkSummary] { labelled(session, networks, \.Labels) }

    /// Its volumes (Go's `VolumeMount`, .NET's `VolumeBuilder`), found the
    /// same way: Ryuk removes them after the networks.
    package static func volumes(of session: String, in volumes: [VolumeSummary]) -> [VolumeSummary] { labelled(session, volumes, \.Labels) }

    /// The images it built from a Dockerfile, unless told to keep them:
    /// Ryuk removes them last. A pulled image carries no session.
    package static func images(of session: String, in images: [ImageSummary]) -> [ImageSummary] { labelled(session, images, \.Labels) }

    private static func labelled<Resource>(_ session: String, _ resources: [Resource], _ labels: (Resource) -> [String: String]?) -> [Resource] {
        guard !session.isEmpty else { return [] }
        return resources.filter { Self.session(labels: labels($0) ?? [:]) == session }
    }

    private static func order(_ a: ContainerSummary, _ b: ContainerSummary) -> Bool {
        let (reaperA, reaperB) = (isReaper(a), isReaper(b))
        if reaperA != reaperB { return reaperB }
        return a.Created != b.Created ? a.Created < b.Created : a.name < b.name
    }
}
