import AppKit
import Combine

/// The API client of a window: the Bruno collections in the checkout the
/// selected tab shows, the one picked and its environment, what has been
/// sent and what came back. The sidebar's API panel and every request
/// open in the editor read it.
///
/// It reads the disk only while its panel is on screen or a request is
/// open (CLAUDE.md: a panel reads nothing while it is not the one on screen).
@MainActor
final class APIWorkspace: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var collections: [BrunoCollection] = []
    @Published var selectedRoot: URL? {
        didSet { if selectedRoot != oldValue { loadEnvironment() } }
    }
    /// The environment picked for the selected collection; nil for none.
    @Published var environmentName: String? {
        didSet {
            guard environmentName != oldValue, let collection else { return }
            AppEnvironment.defaults.set(environmentName, forKey: Self.environmentKey(collection.root))
        }
    }
    @Published private(set) var isLoading = false
    /// The last result of each request file, for the view that shows it.
    @Published private(set) var results: [URL: APIExecution.Result] = [:]
    /// Requests in flight, by file.
    @Published private(set) var sending: Set<URL> = []
    @Published var search = ""
    /// Specs, collections and servers to import from (APIDiscovery).
    @Published private(set) var discovered: [APIDiscovery.Source] = []
    /// The ports the selected tab listens on — the window answers.
    var ports: () -> [Int] = { [] }

    var visible = false {
        didSet { if visible && !oldValue { reload() } }
    }

    /// The last collection or folder run, for the right-hand pane.
    let runner = APIRunner()
    let secrets: APISecretStore
    let scripts: APIScriptRuntime
    /// What runs leave behind for the next — runtime variables, setEnvVar
    /// values, cookies — shared by every workspace of the window (APISession).
    let session: APISession
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var loadGeneration = 0

    /// My Requests' folder; nil for none (tests, an agent's checkout).
    let personalRoot: URL?

    init(
        secrets: APISecretStore = AppEnvironment.makeSecretStore(), scripts: APIScriptRuntime = .shared,
        personalRoot: URL? = APIWorkspace.defaultPersonalRoot, session: APISession = APISession()
    ) {
        self.session = session
        self.secrets = secrets
        self.scripts = scripts
        self.personalRoot = personalRoot
    }

    var collection: BrunoCollection? {
        collections.first { $0.root.standardizedFileURL == selectedRoot?.standardizedFileURL } ?? collections.first
    }

    /// Collections of requests open from another checkout than the one
    /// shown (the tab changed under them), read when they were sent.
    private var elsewhere: [BrunoCollection] = []

    /// The collection a file is in, by path.
    func collection(containing url: URL) -> BrunoCollection? {
        let path = Self.canonicalPath(place(of: url))
        return (collections + elsewhere).filter { path.hasPrefix(Self.canonicalPath($0.root) + "/") }
            .max { $0.root.path.count < $1.root.path.count }
    }

    /// A path to compare by. standardizedFileURL takes /private off /var
    /// only for a path that exists, so a file not written yet (an agent's
    /// one-off request) is standardized by its folder.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        if FileManager.default.fileExists(atPath: url.path) { return url.standardizedFileURL.path }
        return url.deletingLastPathComponent().standardizedFileURL.path + "/" + url.lastPathComponent
    }

    private static func environmentKey(_ root: URL) -> String { "api.environment." + root.standardizedFileURL.path }

    // MARK: Loading

    /// The checkout the window shows now.
    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        root = url
        collections = []
        discovered = []
        // What was read belongs to the checkout it was read for: coming back
        // to that one, it is read again (an agent found nothing otherwise).
        loadedRoot = nil
        if visible { reload() }
    }

    // MARK: My Requests

    /// Requests of your own, as Postman keeps them: a Bruno collection in
    /// Overterm's own folder, not the checkout's — there whatever the
    /// checkout has, nothing committed. Agents aren't shown it.
    nonisolated static var defaultPersonalRoot: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("api/My Requests", isDirectory: true)
    }

    /// The personal collection at `root`, made the first time it is asked for.
    nonisolated static func personalCollection(at root: URL) -> BrunoCollection? {
        let config = root.appendingPathComponent(BrunoCollection.configName)
        if !FileManager.default.fileExists(atPath: config.path) {
            let environments = root.appendingPathComponent("environments", isDirectory: true)
            try? FileManager.default.createDirectory(at: environments, withIntermediateDirectories: true)
            let json: [String: Any] = ["version": "1", "name": "My Requests", "type": "collection", "ignore": ["node_modules", ".git"]]
            try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: config)
            var local = BruFile()
            local.variables = [BruPair(key: "baseUrl", value: "http://localhost:3000")]
            try? local.text.write(to: environments.appendingPathComponent("Local.bru"), atomically: true, encoding: .utf8)
        }
        var collection = BrunoCollection.load(root)
        collection?.isPersonal = true
        return collection
    }

    /// The checkout's collections, and yours after them: My Requests, and
    /// every other collection made beside it in Overterm's folder.
    nonisolated static func loadAll(in root: URL, personal: URL?) -> [BrunoCollection] {
        // Anything in the personal folder is yours, even when the checkout
        // holds it (a home folder opened as one).
        let personalParent = personal.map { $0.deletingLastPathComponent().standardizedFileURL.path + "/" }
        let checkout = BrunoCollection.find(in: root)
            .filter { found in personalParent.map { !(found.standardizedFileURL.path + "/").hasPrefix($0) } ?? true }
            .compactMap(BrunoCollection.load)
        let mine = [personal.flatMap(personalCollection(at:))].compactMap { $0 } + (personal.map(otherPersonalCollections(beside:)) ?? [])
        return checkout + mine
    }

    /// Personal collections other than My Requests: the folders beside it
    /// with a bruno.json, by name.
    nonisolated static func otherPersonalCollections(beside myRequests: URL) -> [BrunoCollection] {
        let parent = myRequests.deletingLastPathComponent()
        let folders = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        return
            folders
            .filter { $0.standardizedFileURL.path != myRequests.standardizedFileURL.path }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(BrunoCollection.configName).path) }
            .compactMap { folder -> BrunoCollection? in
                var collection = BrunoCollection.load(folder)
                collection?.isPersonal = true
                return collection
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The checkout's own: what agents, imports and the runner's bru see.
    var checkoutCollections: [BrunoCollection] { collections.filter { !$0.isPersonal } }

    /// Picked when nothing else is: the checkout's first, else yours.
    private func defaultRoot(_ found: [BrunoCollection]) -> URL? {
        (found.first { !$0.isPersonal } ?? found.first)?.root
    }

    /// Finds the collections again and reads them — off the main thread.
    func reload() {
        guard let root else {
            collections = []
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let personal = personalRoot
        Task.detached(priority: .userInitiated) {
            let found = Self.loadAll(in: root, personal: personal)
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.loadedRoot = root
                self.collections = found
                self.isLoading = false
                if self.selectedRoot == nil || !found.contains(where: { $0.root.standardizedFileURL == self.selectedRoot?.standardizedFileURL }) {
                    self.selectedRoot = self.defaultRoot(found)
                }
                self.loadEnvironment()
                self.discover()
            }
        }
    }

    /// Reads the collections now, on this thread — for an agent's call,
    /// which needs them before it can answer. The walk is bounded.
    func loadNow() {
        guard let root else { return }
        apply(Self.loadAll(in: root, personal: personalRoot), for: root)
    }

    /// What a load found, whichever way it was read. Any read in flight is
    /// superseded — and the panel told it is done, so it doesn't spin on.
    private func apply(_ found: [BrunoCollection], for root: URL) {
        loadGeneration += 1
        loadedRoot = root
        collections = found
        isLoading = false
        if selectedRoot == nil || !found.contains(where: { $0.root.standardizedFileURL == selectedRoot?.standardizedFileURL }) {
            selectedRoot = defaultRoot(found)
        }
        loadEnvironment()
        if visible { discover() }
    }

    /// A request opened or sent while the panel was never shown (from
    /// Files, say): its collection is read now, so its environment, auth,
    /// headers and scripts apply. Only for a file in the checkout, and
    /// only when it isn't known yet — the panel still reads nothing idle.
    func ensureLoaded(for url: URL) {
        // A draft's collection is where it will be saved, not where it sits.
        let url = place(of: url)
        guard collection(containing: url) == nil else { return }
        // The checkout is read once; a .bru no collection holds (an example
        // in the docs) isn't a reason to walk it again on every send.
        if let root, Self.canonicalPath(url).hasPrefix(Self.canonicalPath(root) + "/"),
            loadedRoot?.standardizedFileURL != root.standardizedFileURL
        {
            loadNow()
            if collection(containing: url) != nil { return }
        }
        // Not this checkout's: the nearest bruno.json above it. Bounded, and
        // stopped at the top — never a walk up past "/" (CLAUDE.md).
        var folder = url.deletingLastPathComponent()
        for _ in 0..<32 {
            guard folder.pathComponents.count > 1 else { return }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(BrunoCollection.configName).path) {
                if let found = BrunoCollection.load(folder) {
                    elsewhere.removeAll { $0.root.standardizedFileURL == found.root.standardizedFileURL }
                    elsewhere.append(found)
                }
                return
            }
            folder = folder.deletingLastPathComponent()
        }
    }

    /// The checkout the collections were last read for.
    private(set) var loadedRoot: URL?

    /// Reads the collections off the main thread unless they have been
    /// read for this checkout already — an agent's call waits on it; the
    /// walk lists every folder four down, too many in a monorepo to do on
    /// the main thread each time.
    func loadIfNeeded() async {
        guard let root, loadedRoot?.standardizedFileURL != root.standardizedFileURL else { return }
        let personal = personalRoot
        let found = await Task.detached(priority: .userInitiated) { Self.loadAll(in: root, personal: personal) }.value
        guard self.root?.standardizedFileURL == root.standardizedFileURL else { return }
        apply(found, for: root)
    }

    private func loadEnvironment() {
        guard let collection else { return }
        let saved = AppEnvironment.defaults.string(forKey: Self.environmentKey(collection.root))
        let names = collection.environments.map(\.name)
        let pick = saved.flatMap { names.contains($0) ? $0 : nil }
        if environmentName != pick { environmentName = pick }
    }

    /// Looks for what could be imported: files in the checkout, and —
    /// if Settings allows — an API the selected tab serves.
    func discover() {
        guard let root else { return }
        let ports = Settings.shared.apiDiscoverServers ? ports() : []
        Task { [weak self] in
            let sources = await APIDiscovery.find(in: root, ports: ports, probe: !ports.isEmpty)
            guard let self, self.root == root else { return }
            self.discovered = sources
        }
    }

    // MARK: Importing

    struct Imported {
        /// The collection, or the folder in it, that was written.
        let folder: URL
        /// Its first request, to open.
        let firstRequest: URL?
        let notes: [String]
    }

    /// Where an import goes.
    enum Destination {
        /// The collection picked in the panel — a personal one too: a file
        /// you import, into My Requests if that is where you are.
        case picked
        /// The checkout's: its own API, found in it, is the checkout's.
        case checkout
    }

    /// Writes `imported` as a folder of its destination's collection; with
    /// none, as a collection of its own in the checkout's `bruno/`.
    /// Imported with My Requests picked, a Postman export went into the
    /// checkout's collection whatever was picked.
    func write(_ imported: APIImport, into destination: Destination = .picked) throws -> Imported {
        guard let root else { throw FileError.exists("No checkout") }
        let folder: URL
        let target =
            switch destination {
            case .picked: collection ?? checkoutCollections.first
            case .checkout: checkoutCollections.first
            }
        var notes = imported.notes
        if let collection = target {
            notes += imported.environmentConflicts(in: collection.root)
            folder = try imported.writeFolder(in: collection.root)
        } else {
            let preferred = root.appendingPathComponent("bruno", isDirectory: true)
            let target =
                FileManager.default.fileExists(atPath: preferred.path)
                ? APIImport.unique(root.appendingPathComponent("bruno-" + Self.fileName(imported.name), isDirectory: true), isFolder: true)
                : preferred
            folder = try imported.writeCollection(at: target)
            selectedRoot = folder
            if !imported.environments.isEmpty {
                AppEnvironment.defaults.set(imported.environments[0].name, forKey: Self.environmentKey(folder))
            }
        }
        reload()
        let first =
            BrunoCollection.load(target?.root ?? folder).flatMap { $0.item(at: folder)?.allRequests.first?.url }
            ?? Self.firstRequest(in: folder)
        return Imported(folder: folder, firstRequest: first, notes: notes)
    }

    private static func firstRequest(in folder: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "bru", !["folder.bru", "collection.bru"].contains(url.lastPathComponent),
                !url.path.contains("/environments/")
            {
                return url
            }
        }
        return nil
    }

    func importSource(_ source: APIDiscovery.Source) async throws -> Imported {
        switch source {
        // Found in the checkout or served by it: the checkout's API.
        case .file(let url, _):
            return try write(try APIImport.read(url), into: .checkout)
        case .server(let base, let spec, _):
            let (data, _) = try await URLSession.shared.data(from: spec)
            guard let document = APIImport.parseDocument(data) else { throw APIImport.Problem.unreadable(spec.absoluteString) }
            return try write(try OpenAPIImporter.make(document, baseURL: base.absoluteString), into: .checkout)
        }
    }

    /// A request from a cURL command, in the collection picked — My
    /// Requests when the checkout has none, so nothing lands in the repo
    /// unasked; its file.
    func importCurl(_ command: String) throws -> URL {
        var file = try CurlParser.parse(command)
        if collection == nil, let personal = personalRoot.flatMap(Self.personalCollection(at:)) {
            collections.append(personal)
            selectedRoot = personal.root
        }
        guard let collection else { throw FileError.exists("No collection") }
        file.seq = (collection.tree.children?.compactMap(\.seq).max() ?? 0) + 1
        let target = APIImport.unique(collection.root.appendingPathComponent(Self.fileName(file.name) + ".bru"), isFolder: false)
        try file.text.write(to: target, atomically: true, encoding: .utf8)
        reload()
        return target
    }

    // MARK: Environments

    func environmentFile(_ name: String?, in collection: BrunoCollection) -> BruFile? {
        guard let name, let ref = collection.environments.first(where: { $0.name == name }) else { return nil }
        return (try? String(contentsOf: ref.url, encoding: .utf8)).map(BruFile.init(parsing:))
    }

    /// The environment's variables, its secrets filled in from the store,
    /// and what scripts set on it this run.
    /// - Parameter includeSecrets: false for a request an agent wrote
    ///   itself — it names the host, so a secret could leave with it.
    func environmentValues(_ collection: BrunoCollection, name: String?, includeSecrets: Bool = true) -> [String: String] {
        guard let name, let file = environmentFile(name, in: collection) else { return [:] }
        var values = APIVariables.map(file.variables)
        for secret in file.secretNames {
            values[secret] = includeSecrets ? secrets.value(collection: collection.root, environment: name, name: secret) ?? values[secret] ?? "" : nil
        }
        values.merge(session.environmentOverrides[collection.root.path + "|" + name] ?? [:]) { $1 }
        // After the overrides: a secret a script set with bru.setEnvVar is
        // still a secret, not to be filled into an agent's one-off request.
        if !includeSecrets { for secret in file.secretNames { values[secret] = nil } }
        return values
    }

    /// Saves an environment's secrets: the names into its file's
    /// `vars:secret` (and out of its `vars`, so no value stays committed),
    /// the values into the keychain.
    func saveSecrets(_ names: [String], values: [String: String], environment: String, in collection: BrunoCollection) throws {
        guard let ref = collection.environments.first(where: { $0.name == environment }) else { return }
        var file = BruFile(parsing: try String(contentsOf: ref.url, encoding: .utf8))
        let before = file.secretNames
        file.secretNames = names
        file.variables = file.variables.filter { !names.contains($0.key) }
        try file.text.write(to: ref.url, atomically: true, encoding: .utf8)
        for name in Set(before + names) {
            secrets.set(names.contains(name) ? values[name] : nil, collection: collection.root, environment: environment, name: name)
        }
        objectWillChange.send()
    }

    /// Hands a request and what came back to an agent — the window answers.
    var askAgent: ((String, URL?) -> Void)?

    func runtimeVariables(_ collection: BrunoCollection) -> [String: String] { session.runtime[collection.root] ?? [:] }

    /// Every secret value the checkout's collections could fill in — each
    /// environment's, from the keychain and as scripts set them — to keep
    /// out of what agents are told, whichever environment a run used.
    func allSecretValues() -> [String] {
        checkoutCollections.flatMap { collection in
            collection.environments.flatMap { ref -> [String] in
                guard let file = environmentFile(ref.name, in: collection) else { return [] }
                let overrides = session.environmentOverrides[collection.root.path + "|" + ref.name] ?? [:]
                return file.secretNames.flatMap { name in
                    [secrets.value(collection: collection.root, environment: ref.name, name: name), overrides[name]].compactMap { $0 }
                }
            }
        }
    }

    func clearRuntimeVariables() {
        guard let collection else { return }
        session.runtime[collection.root] = [:]
        session.runtimeJSON[collection.root] = [:]
        objectWillChange.send()
    }

    func client(for root: URL?) -> APIClient {
        let key = root ?? URL(fileURLWithPath: "/")
        if let client = session.clients[key] { return client }
        let client = APIClient()
        session.clients[key] = client
        return client
    }

    // MARK: Sending

    var options: APIClient.Options {
        APIClient.Options(
            timeout: TimeInterval(Settings.shared.apiTimeout), followRedirects: Settings.shared.apiFollowRedirects,
            verifyTLS: Settings.shared.apiVerifyTLS)
    }

    /// Which environment a run uses. Spelled out, because nil meant two
    /// things — "the panel's" and "none" — and the difference sent requests
    /// to the wrong server: an agent's or a run's choice is always fixed.
    enum EnvironmentChoice: Equatable, Sendable {
        /// What the panel has picked for the request's collection, now.
        case panel
        case none
        case named(String)
    }

    /// The environment picked for `collection`: the panel's pick for the
    /// one it shows, else the pick it was left with last.
    func pickedEnvironment(for collection: BrunoCollection) -> String? {
        let name =
            collection.root.standardizedFileURL == self.collection?.root.standardizedFileURL
            ? environmentName : AppEnvironment.defaults.string(forKey: Self.environmentKey(collection.root))
        return name.flatMap { name in collection.environments.contains { $0.name == name } ? name : nil }
    }

    /// The choice made fixed: what `.panel` means now.
    func fixed(_ choice: EnvironmentChoice, for collection: BrunoCollection) -> EnvironmentChoice {
        guard choice == .panel else { return choice }
        return pickedEnvironment(for: collection).map(EnvironmentChoice.named) ?? .none
    }

    /// Everything a request file needs to be run, read now.
    /// - Parameter environment: fixed for this run (an agent's, the
    ///   runner's); the panel's pick for `.panel`. Never changes the pick.
    func setup(for url: URL?, file: BruFile, environment choice: EnvironmentChoice = .panel, includeSecrets: Bool = true)
        -> APIExecution.Setup
    {
        var setup = APIExecution.Setup(file: file)
        setup.requestName = file.name
        setup.options = options
        var processEnv = ProcessInfo.processInfo.environment
        if let url { ensureLoaded(for: url) }
        if let url, let collection = collection(containing: url) {
            setup.collectionName = collection.name
            setup.collectionRoot = collection.root
            setup.collectionFile = collection.collectionFile
            // A draft runs as if it were already where it will be saved.
            setup.folderFiles = collection.folders(containing: place(of: url)).compactMap(BrunoCollection.folderFile)
            setup.scriptFlow = collection.scriptFlow
            let environment: String? =
                switch fixed(choice, for: collection) {
                case .named(let name): collection.environments.contains { $0.name == name } ? name : nil
                default: nil
                }
            setup.environmentName = environment
            setup.environment = environmentValues(collection, name: environment, includeSecrets: includeSecrets)
            setup.runtime = runtimeVariables(collection)
            setup.runtimeJSON = session.runtimeJSON[collection.root] ?? [:]
            if !includeSecrets {
                // A secret copied into a runtime variable (bru.setVar("t",
                // bru.getEnvVar("token"))) is still a secret.
                let hidden = Set(allSecretValues().filter { !$0.isEmpty })
                for (name, value) in setup.runtime where hidden.contains(value) || hidden.contains(where: { value.contains($0) && $0.count >= 4 }) {
                    setup.runtime[name] = nil
                    setup.runtimeJSON[name] = nil
                }
            }
            processEnv.merge(collection.dotEnv) { $1 }
        }
        setup.processEnv = processEnv
        return setup
    }

    /// Sends the request in `file` (its text as the editor holds it, saved or not).
    func send(_ file: BruFile, at url: URL) {
        let url = Self.key(url)
        tasks[url]?.cancel()
        sending.insert(url)
        let setup = setup(for: url, file: file)
        let client = client(for: setup.collectionRoot)
        let scripts = scripts
        tasks[url] = Task { [weak self] in
            let result = await APIExecution.run(setup, client: client, scripts: scripts)
            guard let self, !Task.isCancelled else { return }
            self.record(result, for: url, setup: APIRunSnapshot(setup))
            self.sending.remove(url)
            self.tasks[url] = nil
        }
    }

    /// Runs a request and waits for it — the runner's and agents' way in.
    func run(_ file: BruFile, at url: URL?, environment: EnvironmentChoice = .panel) async -> APIExecution.Result {
        let setup = setup(for: url, file: file, environment: environment)
        let result = await APIExecution.run(setup, client: client(for: setup.collectionRoot), scripts: scripts)
        // A run replaced meanwhile: its result would put back the runtime
        // variables it started with, over what the new run has set.
        guard !Task.isCancelled else { return result }
        if let url { record(result, for: url, setup: APIRunSnapshot(setup)) }
        return result
    }

    func cancel(_ url: URL) {
        let url = Self.key(url)
        tasks[url]?.cancel()
        tasks[url] = nil
        sending.remove(url)
    }

    /// Keeps a run's result, and what it changed for the runs after it —
    /// only what it changed: two requests out at once each started from the
    /// same variables, and the one ending last wrote all of its copy back,
    /// over a token the other had just set.
    private func record(_ result: APIExecution.Result, for url: URL, setup: APIRunSnapshot) {
        results[Self.key(url)] = result
        guard let root = setup.collectionRoot else { return }
        for name in Set(setup.runtime.keys).union(result.runtime.keys) where setup.runtime[name] != result.runtime[name] {
            session.runtime[root, default: [:]][name] = result.runtime[name]
        }
        for name in Set(setup.runtimeJSON.keys).union(result.runtimeJSON.keys) where setup.runtimeJSON[name] != result.runtimeJSON[name] {
            session.runtimeJSON[root, default: [:]][name] = result.runtimeJSON[name]
        }
        if let environment = setup.environmentName, !result.environment.isEmpty {
            session.environmentOverrides[root.path + "|" + environment, default: [:]].merge(result.environment) { $1 }
        }
    }


    // MARK: Files

    enum FileError: LocalizedError {
        case exists(String)
        var errorDescription: String? {
            switch self {
            case .exists(let name): "“\(name)” is already there."
            }
        }
    }

    /// A new request in `folder`, after the ones there; its URL.
    // MARK: Drafts

    /// Requests not saved yet, as Postman's new tabs: a file of Overterm's,
    /// outside every collection — nothing lands in the checkout or in My
    /// Requests until it is saved — but sent as if it were in the folder it
    /// was started from, with that collection's environment and settings.
    nonisolated static var draftsDirectory: URL {
        draftsOverride ?? AppEnvironment.supportDirectory.appendingPathComponent("api-drafts", isDirectory: true)
    }
    /// Unit tests' own: they aren't an isolated run, and must not write
    /// into the user's support folder.
    nonisolated(unsafe) static var draftsOverride: URL?

    /// Each draft, by its path, and the folder it belongs in.
    private(set) var drafts: [String: URL] = [:]

    func isDraft(_ url: URL) -> Bool { drafts[Self.canonicalPath(url)] != nil }

    /// Where a request is sent from: a draft's folder, else its own place.
    func place(of url: URL) -> URL {
        drafts[Self.canonicalPath(url)].map { $0.appendingPathComponent(url.lastPathComponent) } ?? url
    }

    /// A new request, unnamed and unsaved, ready to send.
    func newDraft(in folder: URL, url: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: Self.draftsDirectory, withIntermediateDirectories: true)
        let file = APIImport.unique(Self.draftsDirectory.appendingPathComponent("New Request.bru"), isFolder: false)
        try BruFile.newRequest(name: "New Request", url: url, seq: 1).text.write(to: file, atomically: true, encoding: .utf8)
        drafts[Self.canonicalPath(file)] = folder
        return file
    }

    /// Saves a draft as `name` in the folder it was started from; the
    /// request's file there.
    func saveDraft(_ draft: URL, named name: String) throws -> URL {
        guard let folder = drafts[Self.canonicalPath(draft)] else { throw FileError.exists("Not a draft") }
        var file = BruFile(parsing: try String(contentsOf: draft, encoding: .utf8))
        file.name = name
        file.seq = (collection(containing: folder.appendingPathComponent("x"))?.item(at: folder)?.children?.compactMap(\.seq).max() ?? 0) + 1
        let target = APIImport.unique(folder.appendingPathComponent(Self.fileName(name) + ".bru"), isFolder: false)
        try file.text.write(to: target, atomically: true, encoding: .utf8)
        drafts[Self.canonicalPath(draft)] = nil
        try? FileManager.default.removeItem(at: draft)
        reload()
        return target
    }

    /// A draft closed without saving: gone.
    func discardDraft(_ draft: URL) {
        guard drafts.removeValue(forKey: Self.canonicalPath(draft)) != nil else { return }
        try? FileManager.default.removeItem(at: draft)
    }

    @discardableResult
    func newRequest(named name: String, in folder: URL, method: String = "get", url: String = "") throws -> URL {
        let file = folder.appendingPathComponent(Self.fileName(name) + ".bru")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw FileError.exists(file.lastPathComponent) }
        let seq = (collection(containing: file)?.item(at: folder)?.children?.compactMap(\.seq).max() ?? 0) + 1
        try BruFile.newRequest(name: name, method: method, url: url, seq: seq).text.write(to: file, atomically: true, encoding: .utf8)
        reload()
        return file
    }

    @discardableResult
    func newFolder(named name: String, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(Self.fileName(name), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw FileError.exists(folder.lastPathComponent) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var meta = BruFile()
        meta.setPairs("meta", [BruPair(key: "name", value: name)])
        try meta.text.write(to: folder.appendingPathComponent("folder.bru"), atomically: true, encoding: .utf8)
        reload()
        return folder
    }

    /// A new collection in the checkout, shared with whoever clones it: in
    /// `bruno/`, or beside it when that is taken — a second one had nowhere
    /// to go.
    @discardableResult
    func newCheckoutCollection(named name: String) throws -> URL {
        guard let root else { throw FileError.exists("No checkout") }
        let preferred = root.appendingPathComponent("bruno", isDirectory: true)
        let folder =
            FileManager.default.fileExists(atPath: preferred.path)
            ? APIImport.unique(root.appendingPathComponent("bruno-" + Self.fileName(name), isDirectory: true), isFolder: true)
            : preferred
        return try newCollection(named: name, at: folder)
    }

    /// A new collection of your own, beside My Requests in Overterm's
    /// folder: nothing of it lands in the checkout.
    @discardableResult
    func newPersonalCollection(named name: String) throws -> URL {
        guard let personalRoot else { throw FileError.exists("No place for personal collections") }
        let parent = personalRoot.deletingLastPathComponent()
        let folder = APIImport.unique(parent.appendingPathComponent(Self.fileName(name), isDirectory: true), isFolder: true)
        return try newCollection(named: name, at: folder)
    }

    /// A new collection in `folder` (made if missing): bruno.json, a Local
    /// environment, a first request.
    @discardableResult
    func newCollection(named name: String, at folder: URL, baseURL: String = "http://localhost:3000") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = folder.appendingPathComponent(BrunoCollection.configName)
        guard !FileManager.default.fileExists(atPath: config.path) else { throw FileError.exists(BrunoCollection.configName) }
        let json: [String: Any] = ["version": "1", "name": name, "type": "collection", "ignore": ["node_modules", ".git"]]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: config)
        let environments = folder.appendingPathComponent("environments", isDirectory: true)
        try FileManager.default.createDirectory(at: environments, withIntermediateDirectories: true)
        var local = BruFile()
        local.variables = [BruPair(key: "baseUrl", value: baseURL)]
        try local.text.write(to: environments.appendingPathComponent("Local.bru"), atomically: true, encoding: .utf8)
        selectedRoot = folder
        AppEnvironment.defaults.set("Local", forKey: Self.environmentKey(folder))
        reload()
        return folder
    }

    /// Renames a request (its meta name and its file) or a folder.
    func rename(_ item: APIItem, to name: String) throws -> URL {
        let parent = item.url.deletingLastPathComponent()
        if item.isFolder {
            let target = parent.appendingPathComponent(Self.fileName(name), isDirectory: true)
            if target.standardizedFileURL != item.url.standardizedFileURL {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw FileError.exists(target.lastPathComponent) }
                try FileManager.default.moveItem(at: item.url, to: target)
            }
            let meta = target.appendingPathComponent("folder.bru")
            var file = (try? String(contentsOf: meta, encoding: .utf8)).map(BruFile.init(parsing:)) ?? BruFile()
            file.name = name
            try file.text.write(to: meta, atomically: true, encoding: .utf8)
            reload()
            return target
        }
        let target = parent.appendingPathComponent(Self.fileName(name) + ".bru")
        var file = BruFile(parsing: try String(contentsOf: item.url, encoding: .utf8))
        file.name = name
        if target.standardizedFileURL != item.url.standardizedFileURL {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw FileError.exists(target.lastPathComponent) }
            try FileManager.default.moveItem(at: item.url, to: target)
        }
        try file.text.write(to: target, atomically: true, encoding: .utf8)

        reload()
        return target
    }

    /// The one spelling results are kept under: links resolved — the
    /// panel's tree lists /private/var where the editor opened /var.
    nonisolated static func key(_ url: URL) -> URL {
        FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath()
            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }

    /// Whether the request at `url` is out, however it is spelled.
    func isSending(_ url: URL) -> Bool { sending.contains(Self.key(url)) }

    /// The last result of the request at `url`, however it is spelled.
    func result(for url: URL) -> APIExecution.Result? { results[Self.key(url)] }

    /// Results of what was at `old` (a request, or the requests of a folder)
    /// are now those of what is at `new` — matched with links resolved, as
    /// the editor and the tree spell the same path differently.
    func moveResults(from old: URL, resolved oldResolved: String, to new: URL) {
        for (url, result) in results {
            let resolved = url.resolvingSymlinksInPath().path
            // Gone from disk: resolved by its folder, which is still there.
            let path = FileManager.default.fileExists(atPath: url.path) ? resolved : url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + url.lastPathComponent
            guard path == oldResolved || path.hasPrefix(oldResolved + "/") else { continue }
            results[url] = nil
            results[Self.key(URL(fileURLWithPath: new.path + path.dropFirst(oldResolved.count)))] = result
        }
    }

    /// A copy beside it, named "<name> copy".
    func duplicate(_ item: APIItem) throws -> URL {
        guard !item.isFolder else { return item.url }
        var file = BruFile(parsing: try String(contentsOf: item.url, encoding: .utf8))
        var name = item.name + " copy"
        var target = item.url.deletingLastPathComponent().appendingPathComponent(Self.fileName(name) + ".bru")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            name = item.name + " copy \(n)"
            target = item.url.deletingLastPathComponent().appendingPathComponent(Self.fileName(name) + ".bru")
            n += 1
        }
        file.name = name
        file.seq = (file.seq ?? 0) + 1
        try file.text.write(to: target, atomically: true, encoding: .utf8)
        reload()
        return target
    }

    /// A name as a file may be called: no slashes or colons.
    nonisolated static func fileName(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

/// What runs leave behind for the runs after them, per collection: the
/// runtime variables, bru.setEnvVar's values, a cookie jar. One per window,
/// shared by its workspaces — the panel's and an agent's on another
/// checkout — so a login an agent ran is still there after a tab switch.
@MainActor
final class APISession {
    var runtime: [URL: [String: String]] = [:]
    /// The same values as JavaScript had them, JSON-encoded.
    var runtimeJSON: [URL: [String: String]] = [:]
    /// Per collection path and environment name.
    var environmentOverrides: [String: [String: String]] = [:]
    var clients: [URL: APIClient] = [:]
}

/// What a run started from, to tell what it changed.
struct APIRunSnapshot {
    let collectionRoot: URL?
    let environmentName: String?
    let runtime: [String: String]
    let runtimeJSON: [String: String]

    init(_ setup: APIExecution.Setup) {
        collectionRoot = setup.collectionRoot
        environmentName = setup.environmentName
        runtime = setup.runtime
        runtimeJSON = setup.runtimeJSON
    }
}
