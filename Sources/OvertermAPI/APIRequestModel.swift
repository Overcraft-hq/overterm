import AppKit
import Combine

/// A request file open in the editor, as the request view edits it. The
/// editor's buffer holds the file's text; every change made here is a
/// change to that text — so ⌘S saves it, undo and "unsaved changes" work
/// as for any file, and an agent rewriting the file on disk reaches this
/// view the way it reaches the editor.
@MainActor
package final class APIRequestModel: ObservableObject {
    package let url: URL
    @Published package private(set) var file: BruFile
    @Published package var requestTab: RequestTab
    @Published package var responseTab: ResponseTab = .body
    /// Body shown as sent (raw) rather than indented.
    @Published package var rawBody = false
    /// The editor writes the new text into its buffer.
    package var onEdit: ((String) -> Void)?
    package let workspace: APIWorkspace?
    private var cancellables: Set<AnyCancellable> = []

    package enum RequestTab: String, CaseIterable, Identifiable {
        case params, body, schema, headers, auth, vars, script, assert, tests, docs, settings
        package var id: String { rawValue }
        package var title: String { rawValue == "vars" ? "Vars" : rawValue.capitalized }
    }

    package enum ResponseTab: String, CaseIterable, Identifiable {
        case body, headers, timeline, tests
        package var id: String { rawValue }
        package var title: String { rawValue.capitalized }
    }

    package init(url: URL, text: String, workspace: APIWorkspace?) {
        self.url = url
        self.workspace = workspace
        let file = BruFile(parsing: text)
        self.file = file
        // Open on what the request has: a body to edit, else its params.
        requestTab = file.bodyMode != .none ? .body : .params
        // This request's result and whether it is in flight drive the
        // response half — not everything else the workspace publishes (the
        // panel's filter as it is typed, other requests): a large body
        // redrawn on every keystroke there hung the window.
        if let workspace {
            workspace.$results
                .map { [key = APIWorkspace.key(url)] in $0[key] }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
            workspace.$sending
                .map { [key = APIWorkspace.key(url)] in $0.contains(key) }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
            workspace.$environmentName
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// The buffer's text changed — typed in the source, undone, reloaded
    /// from disk. What this view already wrote comes back here as well, and
    /// is no change.
    package func textChanged(_ text: String) {
        guard text != file.text else { return }
        file = BruFile(parsing: text)
    }

    /// Applies `change` and hands the new text to the editor.
    package func update(_ change: (inout BruFile) -> Void) {
        var copy = file
        change(&copy)
        guard copy != file else { return }
        file = copy
        onEdit?(copy.text)
    }

    // MARK: The URL and its params, kept in step as Bruno keeps them

    /// The URL typed: its query becomes the enabled query params (the
    /// switched-off ones stay), and `:name` segments become path params.
    package func setURL(_ address: String) {
        update { file in
            file.url = address
            let typed = Self.queryPairs(of: address)
            let disabled = file.queryParams.filter { !$0.enabled }
            file.queryParams = typed + disabled
            let names = Self.pathParamNames(in: address)
            let existing = file.pathParams
            file.pathParams = names.map { name in existing.first { $0.key == name } ?? BruPair(key: name, value: "") }
        }
    }

    /// The params edited: the URL's query is rebuilt from the enabled ones.
    package func setQueryParams(_ pairs: [BruPair]) {
        update { file in
            file.queryParams = pairs
            file.url = Self.url(file.url, withQuery: pairs.filter(\.enabled))
        }
    }

    package nonisolated static func queryPairs(of address: String) -> [BruPair] {
        guard let question = address.firstIndex(of: "?") else { return [] }
        var query = address[address.index(after: question)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return BruPair(key: unescapeDelimiters(String(pieces[0])), value: pieces.count > 1 ? unescapeDelimiters(String(pieces[1])) : "")
        }
    }

    package nonisolated static func url(_ address: String, withQuery pairs: [BruPair]) -> String {
        var base = address
        var fragment = ""
        if let hash = base.firstIndex(of: "#") {
            fragment = String(base[hash...])
            base = String(base[..<hash])
        }
        if let question = base.firstIndex(of: "?") { base = String(base[..<question]) }
        let query = pairs.map { "\(escapeDelimiters($0.key, inKey: true))=\(escapeDelimiters($0.value, inKey: false))" }.joined(separator: "&")
        return base + (query.isEmpty ? "" : "?" + query) + fragment
    }

    /// Only what would change the query's shape: `&` and `#` (and `=` in a
    /// name) — a value "a&b" is one param, not two. The rest stays as typed,
    /// as Bruno keeps it; the URL is encoded when it is sent.
    package nonisolated static func escapeDelimiters(_ text: String, inKey: Bool) -> String {
        var out = text.replacingOccurrences(of: "&", with: "%26").replacingOccurrences(of: "#", with: "%23")
        if inKey { out = out.replacingOccurrences(of: "=", with: "%3D") }
        return out
    }

    package nonisolated static func unescapeDelimiters(_ text: String) -> String {
        text.replacingOccurrences(of: "%26", with: "&").replacingOccurrences(of: "%23", with: "#").replacingOccurrences(of: "%3D", with: "=")
    }

    /// `:id` in `/users/:id/posts` — whole path segments only, and not a
    /// port (`localhost:3000`) nor a variable's braces.
    package nonisolated static func pathParamNames(in address: String) -> [String] {
        var path = address
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<end]) }
        if let scheme = path.range(of: "://") { path = String(path[scheme.upperBound...]) }
        var names: [String] = []
        for segment in path.split(separator: "/").dropFirst() where segment.hasPrefix(":") && segment.count > 1 {
            let name = String(segment.dropFirst())
            if !names.contains(name), name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) { names.append(name) }
        }
        return names
    }

    // MARK: Sending

    package var result: APIExecution.Result? { workspace?.result(for: url) }
    package var isSending: Bool { workspace?.isSending(url) == true }

    package func send() {
        guard let workspace else { return }
        if file.isGRPC {
            if workspace.grpcResult(for: url)?.running == true { workspace.cancelGRPC(url) } else { workspace.sendGRPC(file, at: url) }
            return
        }
        if isSending { workspace.cancel(url) } else { workspace.send(file, at: url) }
    }

    /// The request as Send would make it — for Copy as cURL and the timeline.
    package func plan() throws -> APIRequestPlan {
        guard let workspace else { return try APIRequestPlan.make(file, context: .init()) }
        let setup = workspace.setup(for: url, file: file)
        var context = APIRequestPlan.Context()
        context.collectionRoot = setup.collectionRoot
        context.collectionFile = setup.collectionFile
        context.folderFiles = setup.folderFiles
        context.variables.environment = setup.environment
        context.variables.runtime = setup.runtime
        context.variables.processEnv = setup.processEnv
        return try APIRequestPlan.make(file, context: context)
    }

    /// The request, what came back and how the tests went, to an agent —
    /// with the .bru file's path, so it can change the request too.
    package func askAgent() {
        guard let workspace, let result else { return }
        let collection = workspace.collection(containing: url)
        // What the agent's own tools would be told: the keychain's secrets
        // and secret headers and query values out (API-G2).
        let text = "Request: \(file.name) — \(url.path)\n\n" + APIMCP.forAgent(result, secrets: workspace.allSecretValues(), limit: 8000)
        workspace.askAgent?(text, collection?.root)
    }

    package func copyCurl() {
        let text: String
        do {
            text = try plan().curl
        } catch {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A GraphQL request: its Schema tab, its query completed from it.
    package var isGraphQL: Bool { file.requestType == "graphql" || file.bodyMode == .graphql }

    /// The tabs this request has: Schema only for GraphQL.
    package var tabs: [RequestTab] { RequestTab.allCases.filter { $0 != .schema || isGraphQL } }

    /// What may finish the word at the caret in the GraphQL query, from the schema.
    package func graphQLCompletions(before text: String) -> [String] {
        guard let workspace, case .loaded(let schema)? = workspace.graphQLSchema(file, at: url) else { return [] }
        return schema.complete(before: text).candidates.map(\.label)
    }

    /// Counts for the tab bar: what each tab holds.
    package func count(_ tab: RequestTab) -> Int {
        switch tab {
        case .params: file.queryParams.filter(\.enabled).count + file.pathParams.count
        case .headers: file.headers.filter(\.enabled).count
        case .vars: file.preRequestVars.filter(\.enabled).count + file.postResponseVars.filter(\.enabled).count
        case .assert: file.assertions.filter(\.enabled).count
        case .script: [file.preRequestScript, file.postResponseScript].compactMap { $0 }.filter { !$0.isEmpty }.count
        case .tests: (file.tests?.isEmpty == false) ? 1 : 0
        case .docs: (file.docs?.isEmpty == false) ? 1 : 0
        case .body, .auth, .settings, .schema: 0
        }
    }
}
