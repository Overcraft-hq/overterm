import Foundation

/// The API client's MCP servers and the one being inspected: connected on
/// asking, its tools, resources and prompts listed, a tool called with JSON
/// arguments, every message logged — MCP Inspector's work, in Overterm.
@MainActor
final class MCPInspector: ObservableObject {
    enum State: Equatable {
        case idle, connecting, connected
        case failed(String)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case tools = "Tools", resources = "Resources", prompts = "Prompts", log = "Log"
        var id: String { rawValue }
    }

    struct Tool: Equatable, Identifiable {
        var name: String
        var title: String?
        var description: String
        var inputSchema: JSONValue
        var readOnly: Bool?
        var destructive: Bool?
        var id: String { name }
    }

    struct Resource: Equatable, Identifiable {
        var uri: String
        var name: String
        var description: String
        var mimeType: String?
        /// A template's `uriTemplate`: its `{placeholders}` filled before reading.
        var isTemplate = false
        var id: String { uri }
    }

    struct Prompt: Equatable, Identifiable {
        struct Argument: Equatable {
            var name: String
            var description: String
            var required: Bool
        }

        var name: String
        var description: String
        var arguments: [Argument]
        var id: String { name }
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        var date = Date()
        var direction: MCPClient.Direction
        var text: String
    }

    /// What came back from a call, a read or a prompt.
    struct Outcome: Equatable {
        var value: JSONValue
        var duration: TimeInterval
        var isError: Bool
    }

    @Published private(set) var servers: [MCPServerConfig] = []
    @Published private(set) var selected: MCPServerConfig?
    @Published private(set) var states: [String: State] = [:]
    @Published var tab = Tab.tools
    @Published private(set) var serverInfo: JSONValue = .null
    @Published private(set) var instructions: String?
    @Published private(set) var tools: [Tool] = []
    @Published private(set) var resources: [Resource] = []
    @Published private(set) var prompts: [Prompt] = []
    @Published private(set) var log: [LogLine] = []
    @Published var pickedTool: String?
    @Published var pickedResource: String?
    @Published var pickedPrompt: String?
    /// The arguments as typed: JSON for a tool, a value a name for a prompt,
    /// a resource template's URI.
    @Published var toolArguments = "{}"
    @Published var promptArguments: [String: String] = [:]
    @Published var resourceURI = ""
    @Published private(set) var outcome: Outcome?
    @Published private(set) var running = false
    @Published private(set) var error: String?

    private var clients: [String: MCPClient] = [:]
    private let added: MCPAddedServers
    private let home: URL
    private var checkout: URL?
    /// The log's lines kept at most.
    static let logLimit = 1000

    init(added: MCPAddedServers, home: URL) {
        self.added = added
        self.home = home
    }

    static func make() -> MCPInspector {
        let secrets: MCPSecrets = AppEnvironment.isIsolated ? MemoryMCPSecrets() : KeychainMCPSecrets()
        let file = AppEnvironment.supportDirectory.appendingPathComponent("API/MCPServers.json")
        // An isolated run reads no agent of the user's: its home is its own.
        let home = AppEnvironment.isIsolated ? AppEnvironment.supportDirectory : FileManager.default.homeDirectoryForCurrentUser
        return MCPInspector(added: MCPAddedServers(file: file, secrets: secrets), home: home)
    }

    var state: State { selected.map { states[$0.id] ?? .idle } ?? .idle }

    // MARK: The servers

    /// Reads them again: the checkout's, the agents', the ones added here.
    func reload(checkout: URL?) {
        self.checkout = checkout
        let environment = ShellEnvironment.known() ?? ProcessInfo.processInfo.environment
        servers = MCPServerConfig.discover(checkout: checkout, home: home, environment: environment) + added.load()
        if let selected, !servers.contains(where: { $0.id == selected.id }) { self.selected = nil }
    }

    func add(_ server: MCPServerConfig) throws {
        var mine = added.load().filter { $0.name != server.name }
        mine.append(server)
        try added.save(mine)
        reload(checkout: checkout)
    }

    func remove(_ server: MCPServerConfig) throws {
        disconnect(server)
        try added.remove(server)
        reload(checkout: checkout)
    }

    /// Shown, and connected unless it is.
    func open(_ server: MCPServerConfig) {
        if selected?.id != server.id {
            selected = server
            clearShown()
        }
        if case .connected = states[server.id] ?? .idle {
            Task { await refresh() }
            return
        }
        connect(server)
    }

    private func clearShown() {
        tools = []
        resources = []
        prompts = []
        serverInfo = .null
        instructions = nil
        outcome = nil
        error = nil
        pickedTool = nil
        pickedResource = nil
        pickedPrompt = nil
    }

    func connect(_ server: MCPServerConfig) {
        disconnect(server)
        states[server.id] = .connecting
        let id = server.id
        let environment = ShellEnvironment.environment()
        let client = MCPClient(server, environment: environment) { [weak self] direction, text in
            Task { @MainActor in self?.logged(direction, text, server: id) }
        }
        clients[id] = client
        Task {
            do {
                try await client.connect()
                guard clients[id] === client else { return }
                states[id] = .connected
                if selected?.id == id { await refresh() }
            } catch {
                guard clients[id] === client else { return }
                states[id] = .failed(error.localizedDescription)
                await client.close()
            }
        }
    }

    func disconnect(_ server: MCPServerConfig) {
        guard let client = clients.removeValue(forKey: server.id) else { return }
        states[server.id] = .idle
        Task { await client.close() }
    }

    func disconnectAll() {
        for server in servers { disconnect(server) }
    }

    private func logged(_ direction: MCPClient.Direction, _ text: String, server: String) {
        guard selected?.id == server else { return }
        log.append(LogLine(direction: direction, text: text))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    func clearLog() { log = [] }

    /// What the server has: its tools, resources and prompts, as far as it
    /// says it has them (`capabilities`).
    func refresh() async {
        guard let server = selected, let client = clients[server.id] else { return }
        serverInfo = await client.serverInfo
        instructions = await client.instructions
        let capabilities = await client.capabilities
        do {
            // Read whole, then shown at once: a list half there read as "none".
            let tools = capabilities["tools"] == .null ? [] : try await client.list("tools/list", key: "tools").map(Self.tool)
            var resources: [Resource] = []
            if capabilities["resources"] != .null {
                resources = try await client.list("resources/list", key: "resources").map { Self.resource($0, template: false) }
                resources += (try? await client.list("resources/templates/list", key: "resourceTemplates"))?.map { Self.resource($0, template: true) } ?? []
            }
            let prompts = capabilities["prompts"] == .null ? [] : try await client.list("prompts/list", key: "prompts").map(Self.prompt)
            (self.tools, self.resources, self.prompts) = (tools, resources, prompts)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func tool(_ value: JSONValue) -> Tool {
        Tool(
            name: value["name"].string ?? "", title: value["title"].string ?? value["annotations"]["title"].string,
            description: value["description"].string ?? "", inputSchema: value["inputSchema"],
            readOnly: value["annotations"]["readOnlyHint"].bool, destructive: value["annotations"]["destructiveHint"].bool)
    }

    static func resource(_ value: JSONValue, template: Bool) -> Resource {
        Resource(
            uri: (template ? value["uriTemplate"] : value["uri"]).string ?? "", name: value["name"].string ?? "",
            description: value["description"].string ?? "", mimeType: value["mimeType"].string, isTemplate: template)
    }

    static func prompt(_ value: JSONValue) -> Prompt {
        Prompt(
            name: value["name"].string ?? "", description: value["description"].string ?? "",
            arguments: (value["arguments"].array ?? []).map {
                Prompt.Argument(name: $0["name"].string ?? "", description: $0["description"].string ?? "", required: $0["required"].bool ?? false)
            })
    }

    // MARK: Using it

    func pick(tool: Tool) {
        pickedTool = tool.name
        toolArguments = Self.skeleton(tool.inputSchema).pretty
        outcome = nil
    }

    func pick(resource: Resource) {
        pickedResource = resource.uri
        resourceURI = resource.uri
        outcome = nil
        if !resource.isTemplate { read() }
    }

    func pick(prompt: Prompt) {
        pickedPrompt = prompt.name
        promptArguments = Dictionary(prompt.arguments.map { ($0.name, "") }, uniquingKeysWith: { $1 })
        outcome = nil
    }

    /// The arguments a schema asks for, each with an empty value of its type —
    /// the required ones and the rest, as a start to fill in.
    static func skeleton(_ schema: JSONValue) -> JSONValue {
        if schema["default"] != .null { return schema["default"] }
        switch schema["type"].string ?? (schema["properties"] != .null ? "object" : "") {
        case "object":
            var out: [String: JSONValue] = [:]
            for (name, property) in schema["properties"].object ?? [:] { out[name] = skeleton(property) }
            return .object(out)
        case "array": return .array([])
        case "string": return .string(schema["enum"].array?.first?.string ?? "")
        case "integer", "number": return .int(0)
        case "boolean": return .bool(false)
        default: return .null
        }
    }

    func call() {
        guard let server = selected, let client = clients[server.id], let name = pickedTool else { return }
        let arguments: JSONValue
        do {
            arguments = try JSONDecoder().decode(JSONValue.self, from: Data(toolArguments.utf8))
        } catch {
            self.error = "The arguments aren't JSON: \(error.localizedDescription)"
            return
        }
        perform { try await client.callTool(name, arguments: arguments) }
    }

    func read() {
        guard let server = selected, let client = clients[server.id], !resourceURI.isEmpty else { return }
        let uri = resourceURI
        perform { try await client.readResource(uri) }
    }

    func getPrompt() {
        guard let server = selected, let client = clients[server.id], let name = pickedPrompt else { return }
        let arguments = promptArguments.filter { !$0.value.isEmpty }
        perform { try await client.getPrompt(name, arguments: arguments) }
    }

    private func perform(_ work: @escaping @Sendable () async throws -> JSONValue) {
        running = true
        error = nil
        let started = Date()
        Task {
            defer { running = false }
            do {
                let value = try await work()
                outcome = Outcome(value: value, duration: Date().timeIntervalSince(started), isError: value["isError"].bool == true)
            } catch {
                self.error = error.localizedDescription
                outcome = nil
            }
        }
    }
}
