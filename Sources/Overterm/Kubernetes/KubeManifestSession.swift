import Darwin
import Foundation

// MARK: The requests

extension KubeClient {
    /// A server-side apply, a dry run or not — the answer's body, for the
    /// caller to read and mask at once: a Secret's carries its values.
    /// Refused here unless the connection's context is writable for this
    /// session; never retried.
    func apply(_ request: KubeWriteRequest) async throws -> Data {
        guard connection.writable else { throw KubeWriteRefused(reason: "This context is read-only: Overterm changes nothing here.") }
        let response: HTTPResponse
        do {
            response = try await connection.write(
                request.method, request.path, body: request.body, headers: [("Content-Type", request.contentType), ("Accept", "application/json")])
        } catch {
            throw Self.mapped(error, signIn: connection.signIn)
        }
        if (200..<300).contains(response.status) { return response.body }
        if let problem = KubeProxyProblem.classify(
            status: response.status, contentType: response.header("Content-Type"), text: String(decoding: response.body.prefix(4096), as: UTF8.self),
            stderr: "", signIn: connection.signIn)
        {
            throw problem
        }
        throw KubeAPIError.from(response)
    }

    /// The object as the cluster has it now, as JSON; nil when it isn't
    /// there. A Secret's carries its values: read only for its diff, masked
    /// before anything shows it, never kept.
    func live(_ ref: KubeObjectRef) async throws -> Data? {
        do {
            return try await get(KubeWrites.path(ref)).body
        } catch let error as KubeAPIError where error.isNotFound {
            return nil
        }
    }
}

/// `kubectl kustomize DIR`: a kustomization rendered here, from its files
/// alone — kubectl reaches no cluster for it (Section 5: started on every
/// class), and is given `KUBECONFIG=/dev/null` all the same.
enum KubeKustomize {
    static let timeout: TimeInterval = 30
    static let outputLimit = 4 << 20

    static func render(_ folder: URL, context: KubeContext, configuration: KubeProxies.Configuration) async throws -> String {
        if let refused = KubeProcessCheck.rule(.kustomize, for: context).refused { throw KubeManifestProblem(refused) }
        let tool = try await KubeProxyPlanner().tool(context, configuration: configuration, serverMinor: nil)
        var given = tool.environment
        given["KUBECONFIG"] = "/dev/null"
        let environment = given
        let arguments = KubeApply.kustomizeArguments(folder.path)
        let result = await KubeBlocking.run {
            KubeProcessRun.run(tool.kubectl, arguments, environment: environment, timeout: timeout, outputLimit: outputLimit)
        }
        guard let result else { throw KubeManifestProblem("kubectl kustomize didn't finish in \(Int(timeout)) seconds.") }
        guard result.status == 0 else {
            let said = KubeProxyProblem.lastLine(of: result.stderr) ?? "it exited with \(result.status)"
            throw KubeManifestProblem("kubectl kustomize \(folder.lastPathComponent) failed: \(said)")
        }
        guard !result.truncated else { throw KubeManifestProblem("The kustomization renders to more than \(outputLimit >> 20) MB: too much to diff here.") }
        return result.stdout
    }
}

/// The names cluster objects' YAML has in the editor (`KubeResourceBuffer`),
/// and the version each was read at — sent with its apply. A name only:
/// nothing is ever written at it, the text lives in memory (2.8). The
/// templates' copies (`writeTemplate`) are files, under the support
/// folder's `Kubernetes/Edits`, a folder for this Overterm (by its pid,
/// 0700) and a file a copy (0600): each removed when its tab closes, all
/// of them at quit, and a gone Overterm's folder when the next one makes
/// its own.
@MainActor
enum KubeManifestEdits {
    struct Opened {
        var ref: KubeObjectRef
        /// What the object was at as it was read: sent with the apply.
        var resourceVersion: String?
    }

    /// The copies open now, by path.
    private(set) static var opened: [String: Opened] = [:]
    private static var swept = false

    /// The support folder's — a unit test's own in the temporary directory.
    static var root: URL {
        let base =
            AppEnvironment.isUnitTest && !AppEnvironment.isIsolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("overterm-unit-test-\(getpid())", isDirectory: true)
            : AppEnvironment.supportDirectory
        return base.appendingPathComponent("Kubernetes/Edits", isDirectory: true)
    }

    static var folder: URL { root.appendingPathComponent(String(getpid()), isDirectory: true) }

    /// `<context's hash>/<namespace>/deployment-web.yaml`: the tab says
    /// what it is, two contexts' never one file.
    static func url(for ref: KubeObjectRef) -> URL {
        let hash = String(KubeSocketFolder.name(for: ref.context).dropLast(".sock".count))
        let kind = (ref.kind.singular.isEmpty ? ref.kind.kind.lowercased() : ref.kind.singular)
        return folder.appendingPathComponent(hash, isDirectory: true).appendingPathComponent(ref.namespace ?? "_cluster", isDirectory: true)
            .appendingPathComponent("\(safe(kind))-\(safe(ref.name)).yaml")
    }

    private static func safe(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" })
    }

    /// The copy's first lines: what it is, where it goes.
    static func header(_ ref: KubeObjectRef, production: Bool) -> String {
        "# \(production ? "PRODUCTION · " : "")\(ref.context) · \(ref.namespace.map { "namespace \($0)" } ?? "cluster-wide") — \(KubeWriteOutcome.spoken(ref))\n"
            + "# In memory, never saved: Diff with Cluster shows what an apply would change; Apply is a step of its own.\n"
    }

    /// `ref`'s name in the editor, and the version its text was read at.
    /// Nothing is written.
    @discardableResult
    static func register(_ ref: KubeObjectRef, resourceVersion: String?) -> URL {
        let file = url(for: ref)
        opened[file.standardizedFileURL.path] = Opened(ref: ref, resourceVersion: resourceVersion)
        return file
    }

    /// 0600 before a byte is in it, never through a link.
    private static func writePrivately(_ text: String, to file: URL) throws {
        let data = Data(text.utf8)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw KubeManifestProblem("Overterm couldn't write \(file.path): \(String(cString: strerror(errno))).") }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw KubeManifestProblem("\(file.path) couldn't be made private.") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw KubeManifestProblem("Overterm couldn't write \(file.path).") }
    }

    static func edit(at url: URL) -> Opened? { opened[url.standardizedFileURL.path] }

    /// The templates' copies open now (`KubeTemplates`), by path: a file to
    /// apply, never saved, removed with its tab — and its tab closed once
    /// it is applied (2.18: a Secret's value typed into it goes then).
    private(set) static var templates: Set<String> = []

    static func isTemplate(_ url: URL) -> Bool { templates.contains(url.standardizedFileURL.path) }

    /// A template's copy, `templates/<name>-<a tab's id>.yaml`: 0600, its folders 0700.
    static func writeTemplate(_ text: String, name: String) throws -> URL {
        try prepare()
        let folder = self.folder.appendingPathComponent("templates", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("\(safe(name))-\(UUID().uuidString.prefix(6).lowercased()).yaml")
        try writePrivately(text, to: file)
        templates.insert(file.standardizedFileURL.path)
        return file
    }

    /// Said for a save of a template's copy.
    static let templateUnsaved =
        "A template's copy isn't saved: what you type in it — a Secret's value too — stays in memory. Apply sends what is in the editor and closes the tab; closing it drops it."

    /// Said for a save of one: it lives in memory, masked as it was read.
    static let unsaved =
        "A cluster object's YAML is never saved: what you type stays in memory, never in a file. Apply sends what is in the editor; Revert gives back the cluster's."

    /// After an apply: what the object is at now.
    static func applied(_ url: URL, resourceVersion: String?) {
        guard var edit = opened[url.standardizedFileURL.path] else { return }
        edit.resourceVersion = resourceVersion
        opened[url.standardizedFileURL.path] = edit
    }

    /// Its tab closed, its buffer gone: a template's file removed.
    static func remove(_ url: URL) {
        let key = url.standardizedFileURL.path
        opened.removeValue(forKey: key)
        guard templates.remove(key) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// At quit: this Overterm's folder.
    static func removeAll() {
        opened = [:]
        templates = []
        try? FileManager.default.removeItem(at: folder)
    }

    /// The root, 0700 — and, once a run, the folders of Overterms that are gone.
    private static func prepare() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(root.path, 0o700) == 0, chmod(folder.path, 0o700) == 0 else { throw KubeManifestProblem("\(folder.path) couldn't be made private.") }
        guard !swept else { return }
        swept = true
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let pid = pid_t(name), pid != getpid(), !KubeTerminalFiles.isAlive(pid) else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }
}

/// What a manifest's session asks of its window.
@MainActor
protocol KubeManifestHost: AnyObject {
    /// The write's confirmation (`WriteConfirmation`), the name typed where
    /// asked: what was typed when the button was pressed, nil for Cancel.
    func askManifestWrite(_ confirmation: KubeWriteConfirmation) async -> String?
    /// Asked first, with this button (a production Secret's values read for its diff).
    func askManifest(_ title: String, _ detail: String, _ button: String) async -> Bool
    /// The diff, in the right-hand pane.
    func showManifestDiff(_ session: KubeManifestSession)
    /// A template's copy was applied and closed (2.18: what was typed in
    /// it, a Secret's value, goes with it): what was applied, said.
    func manifestTemplateApplied(_ said: String)
    /// The explain view, in the right-hand pane (3.15).
    func showExplain(_ session: KubeExplainSession)
}

extension KubeManifestHost {
    func manifestTemplateApplied(_ said: String) {}
    func showExplain(_ session: KubeExplainSession) {}
}

/// The diff and the apply, shared by the editor's sessions and agents'
/// `k8s_apply`: on the main actor, the objects never leave it. Every
/// request goes through `KubeClient` on the context's connection.
@MainActor
enum KubeManifestRun {
    /// What the context serves: the page's (the same cluster), else read.
    static func discovery(_ context: KubeContext, client: KubeClient, model: KubernetesModel) async throws -> KubeDiscovery {
        if let known = model.knownDiscovery(of: context) { return known }
        return try await client.discover()
    }

    /// The namespace an object without one goes to: the page's on the
    /// context (of several, the context's own when it is one, else the
    /// first), else the context's own.
    static func defaultNamespace(_ context: KubeContext, model: KubernetesModel) -> String {
        let own = KubernetesModel.defaultScope(context).one()
        return model.agentDefaultScope(for: context).one(preferring: own) ?? own ?? "default"
    }

    /// The discovery `objects` are resolved against: the context's, with
    /// the list of each group version a manifest names that isn't its
    /// group's preferred one (discovery holds only that) — `autoscaling/v1`,
    /// a CRD's older version — so the object goes to its own version's path.
    static func served(_ objects: [KubeManifestObject], discovery: KubeDiscovery, client: KubeClient) async -> KubeDiscovery {
        var discovery = discovery
        var asked = Set<String>()
        for object in objects where KubeApply.kind(of: object, in: discovery) == nil && asked.insert(object.apiVersion).inserted {
            let path =
                object.group.isEmpty
                ? "/api/\(KubePath.segment(object.version))" : "/apis/\(KubePath.segment(object.group))/\(KubePath.segment(object.version))"
            guard let answer = try? await client.get(path), let kinds = try? KubeDiscovery.resourceList(answer.body) else { continue }
            discovery.kinds += kinds.filter { kind in !discovery.kinds.contains { $0.groupVersion == kind.groupVersion && $0.resource == kind.resource } }
        }
        return discovery
    }

    /// Where each object goes, in order: its kind at its own apiVersion,
    /// its namespace (the file's, else `namespace`, else the page's).
    static func refs(
        _ objects: [KubeManifestObject], context: KubeContext, client: KubeClient, model: KubernetesModel, namespace: String?
    ) async throws -> [KubeObjectRef] {
        let discovery = await served(objects, discovery: try await discovery(context, client: client, model: model), client: client)
        let fallback = namespace ?? defaultNamespace(context, model: model)
        return try objects.map { try KubeApply.ref($0, context: context.name, discovery: discovery, namespace: fallback) }
    }

    /// Why the cluster's answer means "do it client-side": a refused dry
    /// run — RBAC's 403, the read-only socket's own, a webhook that takes
    /// no dry run (a 400 saying so) — and nothing else. An admission's
    /// denial is a 403 too, but it is the cluster saying no to the object:
    /// that is shown, never a client-side diff as if it would apply.
    static func refusal(_ error: Error) -> String? {
        if let refused = error as? KubeWriteRefused { return refused.reason }
        guard let api = error as? KubeAPIError else { return nil }
        if api.status == 400, dryRunUnsupported(api.message) { return "a webhook of the cluster's takes no dry run (\(api.message))" }
        if api.isForbidden, !admissionDenied(api.message) { return "the cluster refused the dry run (\(api.message))" }
        return nil
    }

    /// `admission webhook "x" does not support dry run`.
    static func dryRunUnsupported(_ message: String) -> Bool { message.lowercased().contains("does not support dry run") }

    /// `admission webhook "x" denied the request: …`, a
    /// ValidatingAdmissionPolicy's `… denied request: …`.
    static func admissionDenied(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("admission webhook") || text.contains("denied the request") || text.contains("denied request")
    }

    /// The manifest's objects against the cluster: each one's live object
    /// (a GET), then — on a writable context — a server-side apply with
    /// `dryRun=All`; read-only, or refused, the file merged over the live
    /// object here, labelled so. Both sides stripped and masked.
    static func diff(
        _ objects: [KubeManifestObject], text: String, context: KubeContext, client: KubeClient, model: KubernetesModel, namespace: String?,
        kustomized: Bool = false
    ) async throws -> KubeManifestDiffResult {
        let refs = try await refs(objects, context: context, client: client, model: model, namespace: namespace)
        var lives: [[String: Any]?] = []
        for ref in refs {
            let data = try await client.live(ref)
            lives.append(data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        }
        // What an apply would send: an untouched env mask given its live value back, in memory.
        let sent = objects.enumerated().map { index, object in KubeApplyCheck.restoringEnv(object.object, live: lives[index]) }
        var method: KubeManifestDiffResult.Method =
            context.isWritable ? .serverSide : .clientSide("\(context.name) is read-only: its socket takes no dry run, so nothing was sent.")
        var afters: [[String: Any]] = []
        if method == .serverSide {
            do {
                for index in objects.indices {
                    let body = KubeApply.body(KubeApplyCheck.unmasked(sent[index], live: lives[index]), ref: refs[index], resourceVersion: nil)
                    // Forced, as `kubectl diff --server-side --force-conflicts`:
                    // a dry run takes nothing, and the fields' other owners
                    // are said from managedFields beside it.
                    let answer = try await client.apply(KubeApply.request(body, ref: refs[index], dryRun: true, force: true))
                    afters.append((try? JSONSerialization.jsonObject(with: answer) as? [String: Any]) ?? [:])
                }
            } catch {
                guard let why = refusal(error) else {
                    if let api = error as? KubeAPIError, api.isForbidden || api.status == 400, admissionDenied(api.message) {
                        throw KubeManifestProblem("\(context.name)'s admission refuses it: \(api.message)")
                    }
                    throw error
                }
                method = .clientSide(why)
                afters = []
            }
        }
        if afters.isEmpty {
            afters = objects.indices.map { index in
                KubeManifestDiff.clientSide(
                    live: lives[index], manifest: KubeApply.body(KubeApplyCheck.unmasked(sent[index], live: lives[index]), ref: refs[index], resourceVersion: nil))
            }
        }
        var items: [KubeManifestItem] = []
        for (index, object) in objects.enumerated() {
            let live = lives[index]
            var given = object
            given.object = sent[index]
            let sides = KubeManifestDiff.sides(live: live, after: afters[index])
            let spoken = KubeWriteOutcome.spoken(refs[index])
            let unified = KubeManifestDiff.unified(
                before: sides.before, after: sides.after, from: live == nil ? "\(spoken): not in \(context.name)" : "\(spoken) in \(context.name)",
                to: method == .serverSide ? "\(spoken) after apply (dry run)" : "\(spoken) after apply (client-side)")
            // Who else owns what changes: the result against the live object,
            // only where the diff says something changes.
            let changes = live == nil || !unified.text.isEmpty
            items.append(
                KubeManifestItem(
                    ref: refs[index], before: sides.before, after: sides.after, diff: unified.text, added: unified.added, removed: unified.removed,
                    isNew: live == nil, owners: changes ? KubeFieldOwners.others(after: KubeManifestDiff.stripped(afters[index]), live: live) : [],
                    managedBy: KubeFieldOwners.managedBy(live), masked: KubeApplyCheck.masked(given), sent: sent[index],
                    overterms: KubeFieldOwners.overterms(live)))
        }
        return KubeManifestDiffResult(
            context: context.name, production: context.isProduction, method: method, items: items, text: text, kustomized: kustomized)
    }

    /// What an apply sends for `items` (the ones that change), in order:
    /// each item's own object (`sent`, the one its diff was made from) to
    /// its own ref, with the version it was opened at (`versions`, by ref)
    /// unless `replacing`, `force` only when asked again. The first
    /// failure stops it — what was applied before it stays applied.
    enum Outcome {
        case applied([KubeObjectRef: String?])
        case conflict(KubeApplyConflict, applied: [KubeObjectRef: String?])
        case failed(String, applied: [KubeObjectRef: String?])
    }

    static func apply(
        _ items: [KubeManifestItem], client: KubeClient, versions: [KubeObjectRef: String], force: Bool, replacing: Bool
    ) async -> Outcome {
        var applied: [KubeObjectRef: String?] = [:]
        for item in items where !item.unchanged {
            let body = KubeApply.body(item.sent, ref: item.ref, resourceVersion: replacing ? nil : versions[item.ref])
            do {
                let answer = try await client.apply(KubeApply.request(body, ref: item.ref, dryRun: false, force: force))
                // Only its version is read: a Secret's answer carries its values.
                let object = (try? JSONSerialization.jsonObject(with: answer) as? [String: Any]) ?? [:]
                applied[item.ref] = (object["metadata"] as? [String: Any])?["resourceVersion"] as? String
            } catch let error as KubeAPIError where error.status == 409 {
                return .conflict(KubeApplyConflict.read(error) ?? .changed(error.message), applied: applied)
            } catch {
                return .failed(failed(item.ref, error), applied: applied)
            }
        }
        return .applied(applied)
    }

    /// An apply's error said plainly.
    static func failed(_ ref: KubeObjectRef, _ error: Error) -> String {
        let object = KubeWriteOutcome.spoken(ref)
        if let refused = error as? KubeWriteRefused { return refused.reason }
        if let problem = error as? KubeProxyProblem { return "\(object): \(problem.reason)" }
        guard let api = error as? KubeAPIError else { return "Couldn't apply \(object): \(error.localizedDescription)" }
        switch api.status {
        case 403: return "\(ref.context) refused it — you may not apply \(object): \(api.message)"
        case 404: return "\(object)'s namespace or kind isn't there: \(api.message)"
        case 422: return "The cluster wouldn't take \(object): \(api.message)"
        case 415, 400: return "The cluster couldn't read \(object) as sent: \(api.message)"
        default: return "Couldn't apply \(object) (HTTP \(api.status)): \(api.message)"
        }
    }

    /// `Applied deployment shop/web to kind-fake.`
    static func done(_ refs: [KubeObjectRef], context: String) -> String {
        refs.count == 1 ? "Applied \(KubeWriteOutcome.spoken(refs[0])) to \(context)." : "Applied \(refs.count) objects to \(context)."
    }
}

/// A manifest in the editor, against a cluster (stage 2b): a copy of a
/// cluster object `y` opened (its context and namespace fixed), a manifest
/// file of the checkout's, or a kustomization's folder (rendered by
/// `kubectl kustomize`, files only). Diff with Cluster reads the live
/// objects and asks for a dry run (`KubeManifestRun.diff`), shown in the
/// changes pane; Apply is a step of its own, through the writes' guard
/// path: the class check (writable contexts only; production only with
/// `applyOnProduction`, never forced), the masks refused, the access
/// review, a fresh dry-run diff in the confirmation with the fields'
/// other owners, the name typed on production, the context checked again
/// at the button, then the requests. A 409 says who owns what, and offers
/// Force (confirmed again; never on production) — or, the object changed
/// since it was opened, Replace.
@MainActor
final class KubeManifestSession: ObservableObject, Identifiable {
    enum Source: Equatable {
        /// A copy of a cluster object (`y`): it goes back where it came from.
        case object(KubeObjectRef)
        /// A manifest of the checkout's.
        case file(URL)
        /// A kustomization: its folder rendered.
        case kustomization(URL)
    }

    enum State: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)

        var text: String? {
            switch self {
            case .idle: nil
            case .working(let text), .done(let text), .failed(let text): text
            }
        }

        var isWorking: Bool { if case .working = self { true } else { false } }
        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    let id = UUID()
    let source: Source
    /// The editor's file.
    let file: URL
    let model: KubernetesModel
    /// The context it is compared with and applied to: an object's own,
    /// else the one picked (the page's, at first).
    @Published var contextName: String? {
        didSet {
            guard contextName != oldValue else { return }
            docsNote = nil
            result = nil
            conflict = nil
            state = .idle
            refreshApplyRefusal()
        }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var result: KubeManifestDiffResult?
    /// Each object's diff, made for the pane once.
    @Published private(set) var fileDiffs: [String: DiffModel.FileDiff] = [:]
    /// The last apply's 409: Force or Replace.
    @Published private(set) var conflict: KubeApplyConflict?
    /// The contexts, for the picker (a file's).
    @Published private(set) var contexts: [KubeContext] = []
    /// Why Apply isn't offered on the context picked now; nil when it is.
    @Published private(set) var applyRefusal: String?
    /// Where the field docs came from, or why they couldn't be read (3.15).
    @Published var docsNote: String?

    /// The buffer's text, as it is now.
    var text: () -> String = { "" }
    /// Where the editor's caret is in it: what Explain explains.
    var caret: () -> Int = { 0 }
    /// The field docs were read (a hover, a completion, Explain): the editor marks unknown fields.
    var onDocsRead: (() -> Void)?
    /// The editor's files with unsaved edits: a kustomization renders the
    /// saved files, so it refuses while one of its folder's is unsaved.
    var unsaved: () -> [URL] = { [] }
    weak var host: KubeManifestHost?
    /// What a request goes through: the context's proxy in a background
    /// slot (the page keeps its own), or a test's connection.
    var client: (KubeContext) -> KubeClient
    /// What a read nobody asked for goes through — a hover where the mouse
    /// rests (3.15) —: a slot free as it stands, never a browser sign-in
    /// (`KubeProxies.Role.spare`), or a test's connection.
    var unaskedClient: (KubeContext) -> KubeClient
    /// A kustomization rendered: a test's stands in.
    var render: (URL, KubeContext) async throws -> String
    /// What the session is told when an apply lands (the scenario).
    var onApplied: ((String) -> Void)?
    /// A cluster object's YAML (`KubeResourceBuffer`): the bar's banner, its Revert.
    weak var resource: KubeResourceBuffer?
    /// The object's own apply landed, at this version: its buffer has what the cluster has.
    var onObjectApplied: ((String?) -> Void)?

    init(source: Source, file: URL, model: KubernetesModel) {
        self.source = source
        self.file = file
        self.model = model
        client = { context in model.agentClient(for: context) }
        unaskedClient = { context in model.spareClient(for: context) }
        render = { folder, context in
            try await KubeKustomize.render(folder, context: context, configuration: model.readConfiguration().proxies)
        }
        if case .object(let ref) = source { contextName = ref.context } else { contextName = model.selectedName }
    }

    var isOwnCopy: Bool { if case .object = source { true } else { false } }

    /// The copy's object, for an `.object` source.
    var ref: KubeObjectRef? { if case .object(let ref) = source { ref } else { nil } }

    /// What the bar says it is.
    var title: String {
        switch source {
        case .object(let ref): KubeWriteOutcome.spoken(ref)
        case .file(let url): url.lastPathComponent
        case .kustomization(let folder): "kustomization \(folder.lastPathComponent)"
        }
    }

    /// The contexts read again (the picker opening; the bar appearing).
    func refreshContexts() async {
        guard let list = await model.contextsForAgents() else {
            contexts = []
            applyRefusal = "Kubernetes is off in Settings ▸ Kubernetes."
            return
        }
        contexts = list.contexts
        if contextName == nil { contextName = model.selectedName ?? list.current }
        refreshApplyRefusal(list)
    }

    private func refreshApplyRefusal(_ list: KubeContextList? = nil) {
        guard let name = contextName else {
            applyRefusal = "Pick a context first."
            return
        }
        guard let context = (list?.contexts ?? contexts).first(where: { $0.name == name }) else {
            applyRefusal = contexts.isEmpty ? nil : "No context called \(name)."
            return
        }
        applyRefusal = KubeApplyCheck.refused(context)
    }

    /// The context as the kubeconfig and the session's switches say it now.
    func contextNow() async -> KubeContext? {
        guard let name = contextName, let list = await model.contextsForAgents() else { return nil }
        contexts = list.contexts
        refreshApplyRefusal(list)
        return list.context(named: name)
    }

    /// The text to compare: the buffer's, or the kustomization rendered —
    /// from the files on disk, so not while one of them is unsaved here.
    private func manifestText(_ context: KubeContext) async throws -> String {
        guard case .kustomization(let folder) = source else { return text() }
        let inside = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let dirty = unsaved().filter { $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(inside) }
        if !dirty.isEmpty {
            throw KubeManifestProblem(
                "Save first: kubectl kustomize renders the saved files, and \(dirty.map(\.lastPathComponent).joined(separator: ", ")) "
                    + "\(dirty.count == 1 ? "has" : "have") unsaved changes.")
        }
        return try await render(folder, context)
    }

    /// The manifest read once: its text and its objects. A diff is made of
    /// exactly these, and an apply sends exactly what its diff was made of.
    private func manifest(_ context: KubeContext) async throws -> (text: String, objects: [KubeManifestObject]) {
        let text = try await manifestText(context)
        return (text, try objects(text))
    }

    var isKustomization: Bool { if case .kustomization = source { true } else { false } }

    /// Said on the bar (a save of Overterm's copy, refused).
    func say(_ text: String) {
        guard !state.isWorking else { return }
        state = .done(text)
    }

    /// The objects, and — for a copy of a cluster object — that it is still that object.
    private func objects(_ text: String) throws -> [KubeManifestObject] {
        let objects = try KubeManifest.parse(text)
        if case .object(let ref) = source {
            guard objects.count == 1, let only = objects.first, only.name == ref.name, only.kind == ref.kind.kind else {
                throw KubeManifestProblem("This copy is \(KubeWriteOutcome.spoken(ref)): keep it that one object — another goes in a file of its own.")
            }
        }
        return objects
    }

    // MARK: Diff with Cluster

    func diffWithCluster() { Task { _ = await runDiff() } }

    /// The diff, shown in the pane; nil when it couldn't be made (said).
    @discardableResult
    func runDiff(show: Bool = true) async -> KubeManifestDiffResult? {
        await runDiff(show: show, of: nil)
    }

    /// The diff of `given` (an apply's manifest, read once), else of the
    /// manifest as it is now. Another context picked while it worked: its
    /// answer is dropped, never shown under the new one.
    private func runDiff(show: Bool, of given: (text: String, objects: [KubeManifestObject])?) async -> KubeManifestDiffResult? {
        guard let name = contextName else {
            state = .failed("Pick a context to compare with.")
            return nil
        }
        state = .working("Comparing with \(name)…")
        conflict = nil
        guard let context = await contextNow(), contextName == name else {
            if contextName == name {
                state = .failed(model.enabled ? "No context called \(name) in the kubeconfig." : "Kubernetes is off in Settings ▸ Kubernetes.")
            }
            return nil
        }
        do {
            let manifest: (text: String, objects: [KubeManifestObject])
            if let given { manifest = given } else { manifest = try await self.manifest(context) }
            if manifest.objects.contains(where: \.isSecret), model.secretConsent.needsAsking(context.name, production: context.isProduction) {
                guard await askSecretConsent(context) else {
                    if contextName == name { state = .failed("Nothing was read: a Secret's diff reads its values, and that wasn't allowed.") }
                    return nil
                }
            }
            guard contextName == name else { return nil }
            let result = try await KubeManifestRun.diff(
                manifest.objects, text: manifest.text, context: context, client: client(context), model: model, namespace: ref?.namespace,
                kustomized: isKustomization)
            guard contextName == name else { return nil }
            self.result = result
            fileDiffs = Dictionary(
                uniqueKeysWithValues: result.items.map { ($0.id, DiffModel.FileDiff(parsing: $0.diff, path: "\($0.ref.name).yaml")) })
            let changes = result.changes
            state = .done(
                changes == 0
                    ? "No change: \(context.name) has \(result.items.count == 1 ? "it" : "them") as the manifest says."
                    : "\(changes) of \(result.items.count) would change: +\(result.added) −\(result.removed)"
                        + (result.isServerSide ? "" : " (\(KubeManifestDiffResult.clientSideLabel))"))
            if show { host?.showManifestDiff(self) }
            return result
        } catch {
            guard contextName == name else { return nil }
            // No diff shown but the one made now: never the last one beside its failure.
            result = nil
            fileDiffs = [:]
            state = .failed(KubernetesModel.said(error))
            return nil
        }
    }

    /// A production Secret's values are read for its diff once a context
    /// and session, as Show asks (rule 9).
    private func askSecretConsent(_ context: KubeContext) async -> Bool {
        guard let host else { return false }
        let yes = await host.askManifest(
            "Read this Secret's values to diff it?",
            "PRODUCTION · \(context.name)\nIts values are read once, compared and masked in the diff, and dropped — never written or kept. Asked once a session.",
            "Read and Compare")
        if yes { model.secretConsent.grant(context.name) }
        return yes
    }

    // MARK: Apply

    func apply() { Task { await runApply() } }

    /// Force: the last 409's fields taken from their managers, asked again.
    func forceApply() {
        guard case .fields = conflict else { return }
        Task { await runApply(force: true) }
    }

    /// Replace: the object changed since it was opened; applied again
    /// without that version, asked again.
    func replace() {
        guard case .changed = conflict else { return }
        Task { await runApply(replacing: true) }
    }

    func runApply(force: Bool = false, replacing: Bool = false) async {
        guard !state.isWorking else { return }
        let asked = conflict
        guard let name = contextName else {
            state = .failed("Pick a context to apply to.")
            return
        }
        state = .working("Checking… \(title) in \(name)")
        guard let context = await contextNow() else {
            state = .failed("No context called \(name) in the kubeconfig.")
            return
        }
        // 1. The class check: writable contexts only; production only by its setting, never forced.
        if let refused = KubeApplyCheck.refused(context, force: force) {
            state = .failed(refused)
            return
        }
        // 2. Read once: the diff shown and the apply sent are of this text.
        let manifest: (text: String, objects: [KubeManifestObject])
        do {
            manifest = try await self.manifest(context)
        } catch {
            state = .failed(KubernetesModel.said(error))
            return
        }
        // A Secret's value still masked would be applied as its mask.
        for object in manifest.objects {
            let masked = KubeApplyCheck.maskedBeforeReading(object)
            if !masked.isEmpty {
                let known = result?.context == context.name ? result?.items.first { $0.ref.name == object.name && $0.ref.kind.kind == object.kind } : nil
                state = .failed(KubeApplyCheck.maskedSaid(masked, of: object.spoken, owned: known?.overterms))
                return
            }
        }
        let client = client(context)
        // 3. The access review (a SelfSubjectAccessReview through the
        // context's writable socket): nothing is read or asked before it says yes.
        do {
            let refs = try await KubeManifestRun.refs(manifest.objects, context: context, client: client, model: model, namespace: ref?.namespace)
            for ref in refs {
                for access in KubeApplyCheck.accesses(ref, exists: true) {
                    let answer = await client.review(access, namespace: ref.namespace)
                    if let why = KubeAccessState.answered(answer).unavailable(access, namespace: ref.namespace ?? "", review: true) {
                        state = .failed(why)
                        return
                    }
                }
            }
        } catch {
            state = .failed(KubernetesModel.said(error))
            return
        }
        // 4. A fresh dry run of the same objects: what the confirmation shows
        // is what the cluster would make of what is sent.
        guard contextName == name, let result = await runDiff(show: true, of: manifest) else { return }
        guard result.isServerSide else {
            state = .failed("\(context.name) wouldn't dry-run it, so it isn't applied: \(result.label)")
            return
        }
        // An env value still masked that the live object couldn't give back.
        if let item = result.items.first(where: { !$0.masked.isEmpty }) {
            state = .failed(KubeApplyCheck.maskedSaid(item.masked, of: item.spoken, owned: item.overterms))
            return
        }
        for item in result.items where item.isNew {
            let access = KubeAccess(verb: "create", resource: item.ref.kind.fullName)
            let answer = await client.review(access, namespace: item.ref.namespace)
            if let why = KubeAccessState.answered(answer).unavailable(access, namespace: item.ref.namespace ?? "", review: true) {
                state = .failed(why)
                return
            }
        }
        guard result.changes > 0 || replacing else {
            state = .done("Nothing to apply: \(context.name) has it as the manifest says.")
            return
        }
        // 5. The confirmation, the name typed on production.
        let namespaces = Set(result.items.compactMap(\.ref.namespace))
        let kubectl = KubeApply.kubectl(
            file: isOwnCopy ? file.lastPathComponent : file.path, context: context.name, namespace: namespaces.count == 1 ? namespaces.first : nil, force: force)
        let confirmation = KubeApplyConfirmation.make(result, context: context, kubectl: kubectl, force: force ? asked : nil, replacing: replacing)
        state = .working("Asking… \(title) in \(context.name)")
        guard let host else {
            state = .failed("Nothing was applied: there is no window to ask in.")
            return
        }
        var versions: [KubeObjectRef: String] = [:]
        if let ref, let opened = resource?.resourceVersion ?? KubeManifestEdits.edit(at: file)?.resourceVersion { versions[ref] = opened }
        guard let typed = await host.askManifestWrite(confirmation) else {
            state = .done("Cancelled: nothing was applied.")
            return
        }
        guard confirmation.accepts(typed) else {
            state = .failed("The name typed wasn't \(confirmation.typedName ?? ""): nothing was applied.")
            return
        }
        guard contextName == name else {
            state = .failed("Another context was picked while it asked: nothing was applied.")
            return
        }
        await send(result, confirmedFor: context, versions: versions, force: force, replacing: replacing)
    }

    /// 6. The requests, through the context as it is now: writes turned off
    /// or the kubeconfig pointing the name elsewhere while it asked stop it here.
    private func send(
        _ result: KubeManifestDiffResult, confirmedFor context: KubeContext, versions: [KubeObjectRef: String], force: Bool, replacing: Bool
    ) async {
        guard let now = await contextNow(), KubernetesModel.sameAccess(context, now), KubeApplyCheck.refused(now, force: force) == nil else {
            state = .failed("\(context.name) changed while it was asked (its writes, its settings or its cluster): nothing was applied.")
            return
        }
        state = .working("Applying… \(title) to \(now.name)")
        let outcome = await KubeManifestRun.apply(result.items, client: client(now), versions: versions, force: force, replacing: replacing)
        let applied: [KubeObjectRef: String?]
        switch outcome {
        case .applied(let done):
            applied = done
            conflict = nil
            let said = KubeManifestRun.done(Array(done.keys).sorted { $0.description < $1.description }, context: now.name)
            await runDiff(show: true)
            state = .done(said)
            onApplied?(said)
        case .conflict(let found, let done):
            applied = done
            conflict = found
            switch found {
            case .fields:
                state = .failed(
                    "Conflict: \(found.said). Nothing of it was applied"
                        + (now.isProduction ? " — on production an apply is never forced." : " — Force takes these fields from them, asked again."))
            case .changed:
                state = .failed("It changed in \(now.name) since you opened it: \(found.said) — Replace applies your copy over it, asked again.")
            }
        case .failed(let said, let done):
            applied = done
            state = .failed(said)
        }
        if let ref, let version = applied[ref] {
            KubeManifestEdits.applied(file, resourceVersion: version)
            onObjectApplied?(version)
        }
    }

    /// The tab closed: an object's copy goes with it.
    func close() {
        if isOwnCopy || KubeManifestEdits.isTemplate(file) { KubeManifestEdits.remove(file) }
        result = nil
        fileDiffs = [:]
    }
}
