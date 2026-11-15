import Foundation

/// Where the docs came from, said: `fake-dev's API (v1.31.1)`.
struct KubeDocsSource: Equatable, Sendable {
    var context: String
    var version: String
    var groupVersion: String

    var said: String { "\(context)'s API" + (version.isEmpty ? "" : " (\(version))") }
}

/// A group version the context's index doesn't list (yet): said, never
/// kept as a failure — another kind on the context is read as ever.
struct KubeDocsUnserved: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The cluster's own API docs (3.15), for the app: each context's
/// `/openapi/v3` and the group version documents asked for, read only
/// when a manifest's hover, completion or the explain view asks — GETs
/// through the context's proxy in a background slot — and kept in memory
/// for that context and its server's version, never on disk. Bounded:
/// `maxContexts` contexts, `maxDocuments` documents a context and
/// `maxBytes` read in all, the least recently used dropped first; each
/// answer read as it arrives and dropped, its connection closed, once it
/// passes its bound (`KubeClient.get(_:maxBytes:)`: 4 MB for the index,
/// 32 MB for a document), then read within bounds (`KubeOpenAPIIndex`,
/// `KubeOpenAPIDocument`). A failure of the context's — unreachable, a
/// sign-in, no OpenAPI v3 — is kept a minute, one group version's (a
/// document forbidden, too big) for that group version: a hover doesn't
/// ask again at every move (an expired sign-in would run its exec plugin
/// each time). A group version the index lacks is not kept — the index is
/// read again at most every `indexAge` anyway —, nor what an unasked read
/// was refused (a sign-in it may not open, no free slot). The explain
/// view asks anew.
@MainActor
final class KubeAPIDocs {
    static let maxContexts = 4
    static let maxDocuments = 12
    /// How long the server's version is taken as it was: then asked again,
    /// and a new version drops what was read.
    static let versionAge: TimeInterval = 300
    /// A group version the index lacks (a CRD applied since): the index
    /// read again, at most this often.
    static let indexAge: TimeInterval = 30
    static let failureAge: TimeInterval = 60

    private final class Entry {
        var context: KubeContext
        var version: String?
        var versionRead: Date?
        var index: KubeOpenAPIIndex?
        var indexRead: Date?
        var documents: [String: Document] = [:]
        var used: Date
        var failure: (at: Date, problem: Error)?
        /// A group version's own failures, by its index key.
        var failures: [String: (at: Date, problem: Error)] = [:]

        init(context: KubeContext, used: Date) {
            self.context = context
            self.used = used
        }
    }

    private struct Document {
        var url: String
        var document: KubeOpenAPIDocument
        var used: Date
    }

    private var entries: [String: Entry] = [:]
    private var reading: [String: Task<KubeOpenAPIDocument, Error>] = [:]
    var now: () -> Date = Date.init
    /// What is kept in all, the documents' sizes as read; a test's smaller.
    var maxBytes = 96 << 20
    /// Where an answer is cut off as it is read; a test's smaller.
    var maxIndexBytes = KubeOpenAPIIndex.maxBytes
    var maxDocumentBytes = KubeOpenAPIDocument.maxBytes
    /// Documents read from a server, for the tests.
    private(set) var documentsRead = 0

    /// What is cached for `gvk` on the context, nothing asked; nil when
    /// nothing is (or the context now names another cluster).
    func cached(_ gvk: KubeGVK, context: KubeContext) -> (document: KubeOpenAPIDocument, source: KubeDocsSource)? {
        guard let entry = entries[context.name], KubernetesModel.sameCluster(entry.context, context),
            let url = entry.index?.url(for: gvk), let document = entry.documents[KubeOpenAPIIndex.key(group: gvk.group, version: gvk.version)],
            document.url == url
        else { return nil }
        return (document.document, source(entry, gvk))
    }

    /// Whether anything was read for the context: marks are made then only.
    func hasDocuments(for context: KubeContext) -> Bool {
        guard let entry = entries[context.name], KubernetesModel.sameCluster(entry.context, context) else { return false }
        return !entry.documents.isEmpty
    }

    /// The document holding `gvk`, read when it isn't cached: the server's
    /// version (when not known lately), the index (when not read, or it
    /// lacks the group version and is older than `indexAge`), the document —
    /// each one GET. `retry`: ask again even after a failure a minute old.
    func document(_ gvk: KubeGVK, context: KubeContext, client: KubeClient, retry: Bool = false) async throws -> (
        document: KubeOpenAPIDocument, source: KubeDocsSource
    ) {
        let entry = entry(for: context)
        let key = KubeOpenAPIIndex.key(group: gvk.group, version: gvk.version)
        if !retry {
            if let failure = entry.failure, now().timeIntervalSince(failure.at) < Self.failureAge { throw failure.problem }
            if let failure = entry.failures[key], now().timeIntervalSince(failure.at) < Self.failureAge { throw failure.problem }
        }
        // Whose failure it is: the context's until its group version's document is asked for.
        var groupVersions = false
        do {
            try await checkVersion(entry, client: client)
            var url = entry.index?.url(for: gvk)
            if entry.index == nil || (url == nil && (entry.indexRead.map { now().timeIntervalSince($0) >= Self.indexAge } ?? true)) {
                let answer = try await Self.fetch("/openapi/v3", client: client, what: "OpenAPI index", maxBytes: maxIndexBytes)
                let index = try KubeOpenAPIIndex.read(answer)
                entry.index = index
                entry.indexRead = now()
                // A document whose URL changed (its hash) is read again.
                entry.documents = entry.documents.filter { index.paths[$0.key] == $0.value.url }
                url = index.url(for: gvk)
            }
            guard let url else {
                throw KubeDocsUnserved(message: "\(context.name) serves no \(gvk.apiVersion): its OpenAPI index has no \(key).")
            }
            entry.failure = nil
            if let cached = entry.documents[key], cached.url == url {
                entry.documents[key]?.used = now()
                entry.failures[key] = nil
                return (cached.document, source(entry, gvk))
            }
            groupVersions = true
            let limit = maxDocumentBytes
            let task: Task<KubeOpenAPIDocument, Error>
            let readingKey = context.name + "\u{0}" + url
            if let running = reading[readingKey] {
                task = running
            } else {
                task = Task {
                    let data = try await Self.fetch(url, client: client, what: "the \(gvk.apiVersion) document", maxBytes: limit)
                    return try await Task.detached(priority: .userInitiated) { try KubeOpenAPIDocument.read(data) }.value
                }
                reading[readingKey] = task
            }
            defer { reading[readingKey] = nil }
            let document = try await task.value
            // The entry may have been dropped, or the cluster changed, while it read.
            guard entries[context.name] === entry, KubernetesModel.sameCluster(entry.context, context) else {
                return (document, source(entry, gvk))
            }
            if entry.documents[key] == nil { documentsRead += 1 }
            entry.documents[key] = Document(url: url, document: document, used: now())
            entry.failures[key] = nil
            trim()
            return (document, source(entry, gvk))
        } catch {
            if entries[context.name] === entry {
                switch Self.keeps(error, groupVersions: groupVersions) {
                case .no: break
                case .context: entry.failure = (now(), error)
                case .groupVersion: entry.failures[key] = (now(), error)
                }
            }
            throw error
        }
    }

    private enum Kept { case no, context, groupVersion }

    /// Whose a failure is, to keep: none for what an unasked read was
    /// refused (a sign-in it may not open, no free slot) — a read someone
    /// asks for goes on —, nor for a group version the index lacks; the
    /// context's for the server or its proxy failing (unreachable, a
    /// sign-in, no OpenAPI v3); else, past the index, the group version's.
    private static func keeps(_ error: Error, groupVersions: Bool) -> Kept {
        if error is KubeDocsUnserved || error is CancellationError { return .no }
        if let problem = error as? KubeProxyProblem {
            switch problem {
            case .needsPageSignIn, .noSlot, .closedWhileOpening: return .no
            default: return .context
            }
        }
        if let http = error as? HTTPError, http.status == 0 { return .context }
        return groupVersions ? .groupVersion : .context
    }

    /// Everything read for a context goes (its cluster changed; a test).
    func forget(_ context: String) { entries[context] = nil }
    func forgetAll() { entries = [:] }

    /// What is kept now: contexts, documents, bytes — for the tests.
    var kept: (contexts: Int, documents: Int, bytes: Int) {
        let documents = entries.values.flatMap { $0.documents.values }
        return (entries.count, documents.count, documents.reduce(0) { $0 + $1.document.bytes })
    }

    // MARK: Inside

    private func entry(for context: KubeContext) -> Entry {
        if let entry = entries[context.name], KubernetesModel.sameCluster(entry.context, context) {
            entry.context = context
            entry.used = now()
            return entry
        }
        let entry = Entry(context: context, used: now())
        entries[context.name] = entry
        trim()
        return entry
    }

    private func source(_ entry: Entry, _ gvk: KubeGVK) -> KubeDocsSource {
        KubeDocsSource(context: entry.context.name, version: entry.version ?? "", groupVersion: gvk.apiVersion)
    }

    /// `/version`, when not asked lately: another version than the one the
    /// docs were read at drops them.
    private func checkVersion(_ entry: Entry, client: KubeClient) async throws {
        if let read = entry.versionRead, now().timeIntervalSince(read) < Self.versionAge { return }
        let version = try await client.version().gitVersion
        if entry.version != nil, entry.version != version {
            entry.index = nil
            entry.indexRead = nil
            entry.documents = [:]
        }
        entry.version = version
        entry.versionRead = now()
    }

    /// One GET, cut off as it is read once it passes `maxBytes`.
    nonisolated private static func fetch(_ path: String, client: KubeClient, what: String, maxBytes: Int) async throws -> Data {
        do {
            return try await client.get(path, accept: "application/json", maxBytes: maxBytes)
        } catch let error as KubeBodyTooLarge {
            let limit = error.limit >= 1 << 20 ? "\(error.limit >> 20) MB" : "\(error.limit >> 10) KB"
            throw KubeOpenAPIProblem("The cluster's \(what) is over \(limit): too much to read here.")
        } catch let error as KubeAPIError where error.isNotFound {
            throw KubeOpenAPIProblem("The cluster serves no OpenAPI v3 (\(path): 404) — Kubernetes 1.27 and later do.")
        } catch let error as KubeAPIError where error.isForbidden {
            throw KubeOpenAPIProblem("Not allowed to read \(what): \(error.message)")
        }
    }

    /// The least recently used out, until the bounds hold.
    private func trim() {
        while entries.count > Self.maxContexts, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { entries[oldest] = nil }
        for entry in entries.values {
            while entry.documents.count > Self.maxDocuments, let oldest = entry.documents.min(by: { $0.value.used < $1.value.used })?.key {
                entry.documents[oldest] = nil
            }
        }
        while kept.bytes > maxBytes {
            let all = entries.values.flatMap { entry in entry.documents.map { (entry, $0.key, $0.value.used) } }
            guard let oldest = all.min(by: { $0.2 < $1.2 }) else { break }
            oldest.0.documents[oldest.1] = nil
        }
    }
}

// MARK: The explain view

/// `kubectl explain`, beside the editor: a kind and a field path on a
/// context, the docs from its own `/openapi/v3` (`KubeAPIDocs`) — read
/// when Explain is pressed, not before. A field's fields open with a
/// press, Up goes back a step; Copy as kubectl gives the line it equals.
@MainActor
final class KubeExplainSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    let id = UUID()
    let model: KubernetesModel
    @Published var query: String
    @Published var contextName: String?
    /// A manifest's apiVersion: its kind at that version, not the preferred one.
    @Published var apiVersion: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var result: KubeFieldDoc?
    @Published private(set) var source: KubeDocsSource?
    /// The contexts, for the picker.
    @Published private(set) var contexts: [KubeContext] = []
    /// What a request goes through: the context's proxy in a background slot, or a test's.
    var client: (KubeContext) -> KubeClient
    /// The docs were read: a manifest's editor marks its unknown fields.
    var onRead: (() -> Void)?

    init(query: String, context: String?, apiVersion: String? = nil, model: KubernetesModel) {
        self.query = query
        contextName = context
        self.apiVersion = apiVersion
        self.model = model
        client = { context in model.agentClient(for: context) }
    }

    var context: KubeContext? { contexts.first { $0.name == contextName } }

    var text: String? { result.map(KubeExplain.text) }

    var kubectl: String? {
        guard let contextName, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return KubeExplain.kubectl(query.trimmingCharacters(in: .whitespaces), context: contextName, apiVersion: apiVersion)
    }

    func refreshContexts() async {
        guard let list = await model.contextsForAgents() else {
            contexts = []
            return
        }
        contexts = list.contexts
        if contextName == nil { contextName = model.selectedName }
    }

    func explain() { Task { await run() } }

    /// One of the result's fields, opened.
    func open(_ field: String) {
        query = query.trimmingCharacters(in: .whitespaces) + "." + field
        explain()
    }

    /// A step back up the path.
    func up() {
        let parts = query.trimmingCharacters(in: .whitespaces).split(separator: ".")
        guard parts.count > 1 else { return }
        query = parts.dropLast().joined(separator: ".")
        explain()
    }

    /// Runs started: an answer is shown only by the latest, so one that
    /// comes after the query changed (or another run began) is dropped.
    private(set) var generation = 0

    func run() async {
        generation += 1
        let run = generation
        let asked = query
        let parsed: KubeExplain.Query
        do {
            parsed = try KubeExplain.parse(asked)
        } catch {
            fail(KubernetesModel.said(error))
            return
        }
        guard let name = contextName else {
            fail("Pick a context: the docs are its cluster's own.")
            return
        }
        state = .working("Reading \(name)'s API docs…")
        guard let list = await model.contextsForAgents() else {
            if current(run, asked, name) { fail("Kubernetes is off in Settings ▸ Kubernetes.") }
            return
        }
        contexts = list.contexts
        guard current(run, asked, name) else { return }
        guard let context = list.context(named: name) else {
            fail("No context called \(name) in the kubeconfig.")
            return
        }
        let client = client(context)
        do {
            let gvk = try await Self.kind(parsed.resource, apiVersion: apiVersion, context: context, client: client, model: model)
            let (document, source) = try await model.apiDocs.document(gvk, context: context, client: client, retry: true)
            guard current(run, asked, name) else { return }
            switch document.lookup(gvk, parsed.path) {
            case .found(let doc):
                result = doc
                self.source = source
                state = .idle
                onRead?()
            case .unknown(let index, let parent):
                fail("\(parent) has no field \"\(parsed.path[index])\" in \(source.said).")
            case .opaque:
                fail("\(([gvk.kind] + parsed.path).joined(separator: ".")): the schema says nothing of the fields there — any are taken.")
            case .noKind:
                fail("\(source.said) has no schema for \(gvk.kind) at \(gvk.apiVersion).")
            }
        } catch {
            guard current(run, asked, name) else { return }
            fail(KubernetesModel.said(error))
        }
    }

    /// Whether run `run`'s answer is still the one to show. Not: when a
    /// newer run started it answers instead; else the query or context
    /// changed under it without a new run (typing, not ↩) — the pane stops
    /// saying it reads, and the answer isn't shown as the new query's.
    private func current(_ run: Int, _ asked: String, _ name: String) -> Bool {
        guard run == generation else { return false }
        guard query == asked, contextName == name else {
            state = .idle
            return false
        }
        return true
    }

    /// A failure: said, and no earlier answer left under it.
    private func fail(_ said: String) {
        result = nil
        source = nil
        state = .failed(said)
    }

    /// `deployment` → apps/v1 Deployment, as discovery says (kubectl's
    /// names: plural, singular, short name, kind); at `apiVersion` when given.
    static func kind(_ resource: String, apiVersion: String?, context: KubeContext, client: KubeClient, model: KubernetesModel) async throws
        -> KubeGVK
    {
        var discovery = try await KubeManifestRun.discovery(context, client: client, model: model)
        // Not in what the page knows: a CRD applied since, maybe — asked of the server once.
        if discovery.kind(resource) == nil, model.knownDiscovery(of: context) != nil { discovery = try await client.discover() }
        guard let kind = discovery.kind(resource) else { throw KubeOpenAPIProblem("\(context.name) serves no kind called \(resource).") }
        if let apiVersion, !apiVersion.isEmpty, let gvk = KubeGVK(apiVersion: apiVersion, kind: kind.kind) {
            guard gvk.group == kind.group else { throw KubeOpenAPIProblem("\(resource) isn't in \(apiVersion)'s group.") }
            return gvk
        }
        return KubeGVK(group: kind.group, version: kind.version, kind: kind.kind)
    }
}

// MARK: A manifest's fields

/// A hover's answer: the docs, said, and where from.
struct KubeFieldHover: Equatable {
    var doc: KubeFieldDoc
    var source: KubeDocsSource

    var text: String { KubeExplain.hover(doc, source: source.said) }
}

extension KubeManifestSession {
    /// The context the docs are read from: the session's, as last read —
    /// a hover doesn't read the kubeconfig again — else read now.
    func docsContext() async -> KubeContext? {
        guard let name = contextName else { return nil }
        if let known = contexts.first(where: { $0.name == name }) { return known }
        return await contextNow()
    }

    /// What is cached for `gvk` on the session's context, nothing asked.
    func cachedDocs(_ gvk: KubeGVK) -> (document: KubeOpenAPIDocument, source: KubeDocsSource)? {
        guard let name = contextName, let context = contexts.first(where: { $0.name == name }) else { return nil }
        return model.apiDocs.cached(gvk, context: context)
    }

    /// The docs of the field at `offset` (its key, or its line): read when
    /// not cached unless `fetch` is false. Nil when there is no field there,
    /// its kind isn't known, or the docs couldn't be read (said on the bar).
    /// `unasked` — the mouse resting there, nobody asked —: read only as a
    /// watch reads (`unaskedClient`): never a browser sign-in, never a proxy
    /// closed for it; the keyboard's hover reads as asked.
    func fieldHover(at offset: Int, in text: String, fetch: Bool = true, unasked: Bool = false) async -> KubeFieldHover? {
        let ns = text as NSString
        guard let (document, key) = KubeManifestFields.key(at: offset, in: ns), let gvk = document.gvk, let context = await docsContext() else { return nil }
        guard let (doc, source) = await docs(gvk, context: context, fetch: fetch, unasked: unasked) else { return nil }
        guard case .found(let field) = doc.lookup(gvk, key.path) else { return nil }
        return KubeFieldHover(doc: field, source: source)
    }

    /// The fields a key typed at `caret` could be, and the word they replace.
    func fieldCompletions(at caret: Int, in text: String, fetch: Bool = true) async -> (slot: KubeManifestFields.Slot, fields: [KubeFieldSummary])? {
        guard let slot = KubeManifestFields.slot(at: caret, in: text as NSString), let gvk = slot.document.gvk, let context = await docsContext(),
            let (doc, _) = await docs(gvk, context: context, fetch: fetch)
        else { return nil }
        let fields = KubeManifestFields.candidates(slot, in: doc, gvk: gvk)
        return fields.isEmpty ? nil : (slot, fields)
    }

    /// The keys the context's docs don't know, from what is cached alone:
    /// nothing is read for them. Empty until a hover, completion or
    /// explain read the docs.
    func fieldMarks(in text: String) -> [KubeManifestFields.Mark] {
        guard let name = contextName, let context = contexts.first(where: { $0.name == name }), model.apiDocs.hasDocuments(for: context) else { return [] }
        let documents = KubeManifestFields.documents(text as NSString)
        let docs = model.apiDocs
        return KubeManifestFields.marks(documents) { gvk in docs.cached(gvk, context: context).map { ($0.document, $0.source.said) } }
    }

    /// The explain view for the field at `offset` (else the document's
    /// kind), on the session's context and at the document's apiVersion.
    func explainSession(at offset: Int, in text: String) -> KubeExplainSession {
        let ns = text as NSString
        let found = KubeManifestFields.key(at: offset, in: ns)
        let document = found?.document ?? KubeManifestFields.documents(ns).first
        let kind = document?.kind?.lowercased() ?? ""
        var path = found.map { $0.key.path.filter { $0 != "[]" } } ?? []
        if path == ["apiVersion"] || path == ["kind"] { path = [] }
        let query = ([kind] + path).filter { !$0.isEmpty }.joined(separator: ".")
        let session = KubeExplainSession(query: query, context: contextName, apiVersion: document?.apiVersion, model: model)
        session.client = client
        return session
    }

    /// Explain, from the bar: the field at the caret in the right-hand
    /// pane, read now. The session made, for the tests.
    @discardableResult
    func explainAtCaret() -> KubeExplainSession {
        let session = explainSession(at: caret(), in: text())
        session.onRead = { [weak self] in self?.onDocsRead?() }
        host?.showExplain(session)
        session.explain()
        return session
    }

    private func docs(_ gvk: KubeGVK, context: KubeContext, fetch: Bool, unasked: Bool = false) async -> (KubeOpenAPIDocument, KubeDocsSource)? {
        if let cached = model.apiDocs.cached(gvk, context: context) { return (cached.document, cached.source) }
        guard fetch else { return nil }
        do {
            let found = try await model.apiDocs.document(gvk, context: context, client: unasked ? unaskedClient(context) : client(context))
            docsNote = "Field docs: \(found.source.said)"
            onDocsRead?()
            return (found.document, found.source)
        } catch {
            docsNote = "Field docs: " + KubernetesModel.said(error)
            return nil
        }
    }
}
