import Foundation

extension KubeClient {
    /// Metadata only: no Secret's data comes with a list (Section 4, Helm
    /// releases). No plain-JSON fallback — a server that can't answer
    /// this way would send every record's data.
    static let metadataListAccept = "application/json;as=PartialObjectMetadataList;v=v1;g=meta.k8s.io"

    /// Helm's records in one storage, as their metadata says them — the
    /// labels — paged; an expired `continue` lists again from the start.
    /// With `release`, that release's alone (its `name` label too).
    func helmRecords(_ storage: KubeHelmStorage, in scope: KubeScope, release: String? = nil) async throws -> [KubeHelmRecord] {
        let kind = storage.kind
        let selector = storage.labelSelector + (release.map { ",\(storage == .tiller ? "NAME" : "name")=\($0)" } ?? "")
        // Tiller keeps every release's ConfigMaps in its own namespace and
        // their labels don't say the release's: listed across the cluster.
        if storage != .tiller, case .namespaces = scope {
            // A list each (past the cap, across the cluster), kept to the picked ones.
            var records: [KubeHelmRecord] = []
            for namespace in scope.reads(for: kind) {
                records += try await helmRecords(storage, in: namespace.map { .namespace($0) } ?? .all, release: release)
            }
            return records.filter { scope.includes($0.namespace) }
        }
        let namespace = storage == .tiller ? nil : scope.namespace(for: kind)
        var restarts = 0
        restart: while true {
            var records: [KubeHelmRecord] = []
            var token: String?
            repeat {
                let path = KubePath.query(
                    kind.path(namespace: namespace),
                    [
                        ("limit", String(pageSize)), ("continue", token), ("labelSelector", selector), ("fieldSelector", storage.fieldSelector),
                    ])
                do {
                    let page = try KubeHelm.records(try await get(path, accept: Self.metadataListAccept).body, storage: storage)
                    records += page.records
                    token = page.continueToken
                } catch let error as KubeAPIError where error.isGone && token != nil && restarts < 3 {
                    restarts += 1
                    continue restart
                }
            } while token != nil
            return records
        }
    }

    /// One record — the one GET of its Secret or ConfigMap — decoded and
    /// masked on Helm's own queue (`KubeHelm.decoding`), never a
    /// Swift-concurrency thread: up to 32 MB inflated, parsed and masked.
    /// Cancelled, it stops between steps. The answer itself is not kept.
    func helmRelease(_ record: KubeHelmRecord) async throws -> KubeHelmDetail {
        let response = try await get(record.storage.kind.path(namespace: record.namespace, name: record.object))
        try Task.checkCancellation()
        return try await KubeHelm.decodeOffPool(response.body, storage: record.storage)
    }
}

extension KubeHelm {
    /// Where records are decoded: one at a time, so releases opened in a
    /// row don't decode side by side — a cancelled one stops at its next step.
    static let decoding = DispatchQueue(label: "overterm.kubernetes.helm-decode", qos: .userInitiated)

    nonisolated static func decodeOffPool(_ body: Data, storage: KubeHelmStorage) async throws -> KubeHelmDetail {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueDecode(body, storage: storage, cancellation: cancellation, continuation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// The block is spelled `@Sendable () -> Void` (CLAUDE.md: a block for
    /// a queue), built here, outside any actor.
    private nonisolated static func enqueueDecode(
        _ body: Data, storage: KubeHelmStorage, cancellation: Cancellation, _ continuation: CheckedContinuation<KubeHelmDetail, Error>
    ) {
        let work: @Sendable () -> Void = {
            continuation.resume(with: Result { try decode(body, storage: storage, isCancelled: { cancellation.isCancelled }) })
        }
        decoding.async(execute: work)
    }
}

/// The page's Helm section (`8`; stage 2c): the releases of the context
/// and namespace shown, read from Helm's own records' metadata — a list,
/// not a watch, read again when the section shows, on Refresh, and with
/// another context or namespace — and one release's revision opened,
/// decoded and masked (`KubeHelmDetail`). Reading a release is reading a
/// Secret (rule 9), so it is the user's ask: on a production context the
/// first one of the session asks, naming the context (`KubeSecretConsent`,
/// shared with Secrets' Show), and what was read goes when the page hides,
/// the context changes or another release opens. Secrets that can't be
/// listed (RBAC) are said, with helm in a terminal offered; ConfigMap
/// records are still listed. A window's, as its page is.
@MainActor
final class KubeHelmSession: ObservableObject {
    enum ListState: Equatable {
        case idle, loading, live
        case failed(String)
    }

    enum State: Equatable {
        /// Production: asked first.
        case confirming
        case loading
        case shown(KubeHelmDetail)
        case failed(String)
        /// What was read went (the page hid, another context); Read Again.
        case dropped(String)
    }

    /// The release opened: one revision of it, and how its reading stands.
    struct Opened: Equatable {
        var release: KubeHelmRelease
        var record: KubeHelmRecord
        var context: String
        var isProduction: Bool
        var state: State

        var detail: KubeHelmDetail? {
            if case .shown(let detail) = state { return detail }
            return nil
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview, history, values, manifest, notes
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @Published private(set) var releases: [KubeHelmRelease] = []
    @Published private(set) var listState: ListState = .idle
    /// Why the Secrets — where Helm keeps its releases by default — can't
    /// be listed here (a 403), said over the section.
    @Published private(set) var secretsRefused: String?
    /// A storage whose list failed otherwise (a 5xx, a timeout, a server
    /// that won't answer metadata only) while another's listed: said over
    /// the section, so the list isn't taken for all of them.
    @Published private(set) var unlisted: String?
    /// The release picked (`KubeHelmRelease.id`).
    @Published var selection: String?
    @Published private(set) var opened: Opened?
    @Published var tab: Tab = .overview
    /// Values: the computed ones (`--all`) rather than the user's.
    @Published var computedValues = false
    /// What opened revisions said of their charts, by release: the list's
    /// Chart and App Version — names and versions only, never a value or
    /// a description; kept for the context, gone with it.
    @Published private(set) var charts: [String: KubeHelmChart] = [:]
    /// What the open release's revisions said of themselves (Helm's
    /// description, scrubbed — a failure's can quote the manifest), by
    /// record: History's, gone with the release (rule 9).
    @Published private(set) var summaries: [String: String] = [:]
    /// The context and namespace the list is of.
    private(set) var context: String?
    private(set) var scope: KubeScope?

    private let consent: KubeSecretConsent
    private var client: KubeClient?
    private var listing: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var generation = 0

    init(consent: KubeSecretConsent) {
        self.consent = consent
    }

    // MARK: The list

    /// The releases of `context` in `scope`, listed again. Another context
    /// forgets everything the last one's said; another namespace, its
    /// list and the release opened.
    func load(context: String, scope: KubeScope, client: KubeClient?) {
        if context != self.context {
            drop(nil)
            charts = [:]
            summaries = [:]
            releases = []
            selection = nil
            secretsRefused = nil
            unlisted = nil
        } else if scope != self.scope {
            drop(nil)
            releases = []
            selection = nil
            secretsRefused = nil
            unlisted = nil
        }
        self.context = context
        self.scope = scope
        self.client = client
        listing?.cancel()
        generation += 1
        let generation = self.generation
        guard let client else {
            listState = .failed("Kubernetes is off, or the context is gone.")
            return
        }
        listState = .loading
        let storages = Self.storages(scope)
        listing = Task { [weak self] in
            let results = await withTaskGroup(of: (Int, Result<[KubeHelmRecord], Error>).self) { group in
                for (index, storage) in storages.enumerated() {
                    group.addTask { (index, await Self.records(client, storage, scope)) }
                }
                var results: [Result<[KubeHelmRecord], Error>?] = Array(repeating: nil, count: storages.count)
                for await (index, result) in group { results[index] = result }
                return results.compactMap { $0 }
            }
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.take(Array(zip(storages, results)), scope: scope)
        }
    }

    /// What a scope lists: Secrets and ConfigMaps; Tiller's only across all
    /// namespaces — its records sit in Tiller's namespace (kube-system by
    /// default) whichever namespace the release went to, and say no other.
    nonisolated static func storages(_ scope: KubeScope) -> [KubeHelmStorage] {
        scope == .all ? [.secret, .configMap, .tiller] : [.secret, .configMap]
    }

    nonisolated private static func records(_ client: KubeClient, _ storage: KubeHelmStorage, _ scope: KubeScope) async -> Result<
        [KubeHelmRecord], Error
    > {
        do {
            return .success(try await client.helmRecords(storage, in: scope))
        } catch {
            return .failure(error)
        }
    }

    private func take(_ results: [(KubeHelmStorage, Result<[KubeHelmRecord], Error>)], scope: KubeScope) {
        listing = nil
        var records: [KubeHelmRecord] = []
        var refused: String?
        var failures: [(KubeHelmStorage, Error)] = []
        for (storage, result) in results {
            switch result {
            case .success(let found): records += found
            case .failure(let error as KubeAPIError) where error.isForbidden:
                // ConfigMaps or Tiller's refused: their releases are left
                // out; the Secrets', said.
                if storage == .secret { refused = Self.refusal(scope) }
            case .failure(let error):
                failures.append((storage, error))
            }
        }
        secretsRefused = refused
        if let failure = failures.first, records.isEmpty {
            unlisted = nil
            listState = .failed(KubernetesModel.said(failure.1))
            releases = []
            return
        }
        unlisted = failures.isEmpty ? nil : Self.unlisted(failures)
        releases = KubeHelm.releases(records)
        listState = .live
        if let selection, !releases.contains(where: { $0.id == selection }) { self.selection = nil }
        if let opened {
            if let release = releases.first(where: { $0.id == opened.release.id }) {
                self.opened?.release = release
            } else {
                drop(nil)
            }
        }
    }

    /// The forbidden Secret list in plain words: what it means for Helm,
    /// and what still works.
    static func refusal(_ scope: KubeScope) -> String {
        let place =
            switch scope {
            case .all: "across all namespaces"
            case .namespace(let name): "in \(name)"
            case .namespaces: "in \(scope.said)"
            }
        return "Releases can't be read here: this user can't list Secrets \(place), and Helm keeps its releases in them. "
            + "helm in a terminal reads them with your own credentials."
    }

    /// The storages that failed, and why, in plain words.
    static func unlisted(_ failures: [(KubeHelmStorage, Error)]) -> String {
        let said = failures.map { storage, error in
            "Releases kept in \(storage.said)s couldn't be listed: \(KubernetesModel.said(error))"
        }
        return said.joined(separator: "\n") + "\nThe list shows the others only."
    }

    // MARK: One release

    /// A release's revision (its latest unless one is picked from its
    /// history) read: the one GET, decoded and masked — on production the
    /// session's first asked first.
    func open(_ release: KubeHelmRelease, revision record: KubeHelmRecord? = nil, isProduction: Bool) {
        guard let context, let client else { return }
        let record = record ?? release.latest
        // Another revision of the release open: its History's descriptions stay.
        let kept = opened?.release.id == release.id && opened?.state != .confirming ? summaries : [:]
        drop(nil)
        summaries = kept
        selection = release.id
        if release.storage == .tiller {
            opened = Opened(
                release: release, record: record, context: context, isProduction: isProduction,
                state: .failed(KubeHelmProblem.helm2.localizedDescription))
            return
        }
        opened = Opened(release: release, record: record, context: context, isProduction: isProduction, state: .loading)
        if consent.needsAsking(context, production: isProduction) {
            opened?.state = .confirming
            return
        }
        read(record, client: client)
    }

    /// The production question answered yes: not asked again this session.
    func confirm() {
        guard let opened, opened.state == .confirming, let client else { return }
        consent.grant(opened.context)
        read(opened.record, client: client)
    }

    func cancelConfirmation() {
        guard opened?.state == .confirming else { return }
        opened = nil
    }

    /// Read Again, after a drop.
    func readAgain() {
        guard let opened, case .dropped = opened.state else { return }
        open(opened.release, revision: opened.record, isProduction: opened.isProduction)
    }

    private func read(_ record: KubeHelmRecord, client: KubeClient) {
        opened?.state = .loading
        let id = record.id
        reading = Task { [weak self] in
            let result: Result<KubeHelmDetail, Error>
            do {
                result = .success(try await client.helmRelease(record))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, self.opened?.record.id == id, self.opened?.state == .loading else { return }
            self.reading = nil
            switch result {
            case .success(let detail):
                self.opened?.state = .shown(detail)
                if let release = self.opened?.release, record.revision == release.revision { self.charts[release.id] = detail.chart }
                if let summary = detail.summary { self.summaries[id] = summary }
            case .failure(let error):
                self.opened?.state = .failed(KubernetesModel.said(error))
            }
        }
    }

    /// The release opened closes (Esc, another one).
    func close() { drop(nil) }

    /// What was read goes: with a reason, the release stays open saying it
    /// (Read Again); without, it closes.
    func drop(_ reason: String?) {
        reading?.cancel()
        reading = nil
        summaries = [:]
        guard let opened else { return }
        if let reason, opened.state != .confirming {
            if case .dropped = opened.state { return }
            self.opened?.state = .dropped(reason)
        } else {
            self.opened = nil
        }
    }

    /// The page hid, or its window: no release read stays on screen.
    func pageHidden() { drop("Hidden again when the page was hidden.") }

    /// ↑ ↓: the selection moves along the list.
    func move(_ step: Int) {
        guard !releases.isEmpty else { return }
        let index = selection.flatMap { id in releases.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + step, 0), releases.count - 1) } ?? (step > 0 ? 0 : releases.count - 1)
        selection = releases[next].id
    }

    var selectedRelease: KubeHelmRelease? { selection.flatMap { id in releases.first { $0.id == id } } }
}
