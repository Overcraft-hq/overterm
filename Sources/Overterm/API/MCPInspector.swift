import Foundation

/// The API client's MCP servers and the one being inspected: connected on
/// asking, its tools, resources and prompts listed, a tool called with JSON
/// arguments, every message logged — MCP Inspector's work, in Overterm.
@MainActor
package final class MCPInspector: ObservableObject {
    package enum State: Equatable {
        case idle, connecting, connected
        case failed(String)
    }

    package enum Tab: String, CaseIterable, Identifiable {
        case tools = "Tools", resources = "Resources", prompts = "Prompts", log = "Log"
        package var id: String { rawValue }
    }

    package struct Tool: Equatable, Identifiable {
        package var name: String
        package var title: String?
        package var description: String
        package var inputSchema: JSONValue
        package var readOnly: Bool?
        package var destructive: Bool?
        package var id: String { name }
    }

    package struct Resource: Equatable, Identifiable {
        package var uri: String
        package var name: String
        package var description: String
        package var mimeType: String?
        /// A template's `uriTemplate`: its `{placeholders}` filled before reading.
        package var isTemplate = false
        package var id: String { uri }
    }

    package struct Prompt: Equatable, Identifiable {
        package struct Argument: Equatable {
            package var name: String
            package var description: String
            package var required: Bool
        }

        package var name: String
        package var description: String
        package var arguments: [Argument]
        package var id: String { name }
    }

    package struct LogLine: Identifiable, Equatable {
        package let id = UUID()
        package var date = Date()
        package var direction: MCPClient.Direction
        package var text: String
    }

    /// What came back from a call, a read or a prompt.
    package struct Outcome: Equatable {
        package var value: JSONValue
        package var duration: TimeInterval
        package var isError: Bool
    }

    @Published package private(set) var servers: [MCPServerConfig] = []
    @Published package private(set) var selected: MCPServerConfig?
    @Published package private(set) var states: [String: State] = [:]
    @Published package var tab = Tab.tools
    @Published package private(set) var serverInfo: JSONValue = .null
    @Published package private(set) var instructions: String?
    @Published package private(set) var tools: [Tool] = []
    @Published package private(set) var resources: [Resource] = []
    @Published package private(set) var prompts: [Prompt] = []
    @Published package private(set) var log: [LogLine] = []
    @Published package var pickedTool: String?
    @Published package var pickedResource: String?
    @Published package var pickedPrompt: String?
    /// The arguments as typed: JSON for a tool, a value a name for a prompt,
    /// a resource template's URI.
    @Published package var toolArguments = "{}"
    @Published package var promptArguments: [String: String] = [:]
    @Published package var resourceURI = ""
    @Published package private(set) var outcome: Outcome?
    @Published package private(set) var running = false
    @Published package private(set) var error: String?

    private var clients: [String: MCPClient] = [:]
    private let added: MCPAddedServers
    private let home: URL
    private var checkout: URL?
    /// The log's lines kept at most.
    package static let logLimit = 1000

    package init(added: MCPAddedServers, home: URL) {
        self.added = added
        self.home = home
    }

    package static func make() -> MCPInspector {
        let secrets: MCPSecrets = AppEnvironment.isIsolated ? MemoryMCPSecrets() : KeychainMCPSecrets()
        let file = AppEnvironment.supportDirectory.appendingPathComponent("API/MCPServers.json")
        // An isolated run reads no agent of the user's: its home is its own.
        let home = AppEnvironment.isIsolated ? AppEnvironment.supportDirectory : FileManager.default.homeDirectoryForCurrentUser
        return MCPInspector(added: MCPAddedServers(file: file, secrets: secrets), home: home)
    }

    package var state: State { selected.map { states[$0.id] ?? .idle } ?? .idle }

    // MARK: The servers

    /// Reads them again: the checkout's, the agents', the ones added here.
    package func reload(checkout: URL?) {
        self.checkout = checkout
        let environment = ShellEnvironment.known() ?? ProcessInfo.processInfo.environment
        servers = MCPServerConfig.discover(checkout: checkout, home: home, environment: environment) + added.load()
        if let selected, !servers.contains(where: { $0.id == selected.id }) { self.selected = nil }
    }

    package func add(_ server: MCPServerConfig) throws {
        var mine = added.load().filter { $0.name != server.name }
        mine.append(server)
        try added.save(mine)
        reload(checkout: checkout)
    }

    package func remove(_ server: MCPServerConfig) throws {
        disconnect(server)
        try added.remove(server)
        reload(checkout: checkout)
    }

    /// Shown, and connected unless it is.
    package func open(_ server: MCPServerConfig) {
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

    package func connect(_ server: MCPServerConfig) {
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

    package func disconnect(_ server: MCPServerConfig) {
        guard let client = clients.removeValue(forKey: server.id) else { return }
        states[server.id] = .idle
        Task { await client.close() }
    }

    package func disconnectAll() {
        for server in servers { disconnect(server) }
    }

    private func logged(_ direction: MCPClient.Direction, _ text: String, server: String) {
        guard selected?.id == server else { return }
        log.append(LogLine(direction: direction, text: text))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    package func clearLog() { log = [] }

    /// What the server has: its tools, resources and prompts, as far as it
    /// says it has them (`capabilities`).
    package func refresh() async {
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

    package static func tool(_ value: JSONValue) -> Tool {
        Tool(
            name: value["name"].string ?? "", title: value["title"].string ?? value["annotations"]["title"].string,
            description: value["description"].string ?? "", inputSchema: value["inputSchema"],
            readOnly: value["annotations"]["readOnlyHint"].bool, destructive: value["annotations"]["destructiveHint"].bool)
    }

    package static func resource(_ value: JSONValue, template: Bool) -> Resource {
        Resource(
            uri: (template ? value["uriTemplate"] : value["uri"]).string ?? "", name: value["name"].string ?? "",
            description: value["description"].string ?? "", mimeType: value["mimeType"].string, isTemplate: template)
    }

    package static func prompt(_ value: JSONValue) -> Prompt {
        Prompt(
            name: value["name"].string ?? "", description: value["description"].string ?? "",
            arguments: (value["arguments"].array ?? []).map {
                Prompt.Argument(name: $0["name"].string ?? "", description: $0["description"].string ?? "", required: $0["required"].bool ?? false)
            })
    }

    // MARK: Using it

    package func pick(tool: Tool) {
        pickedTool = tool.name
        toolArguments = Self.skeleton(tool.inputSchema).pretty
        outcome = nil
    }

    package func pick(resource: Resource) {
        pickedResource = resource.uri
        resourceURI = resource.uri
        outcome = nil
        if !resource.isTemplate { read() }
    }

    package func pick(prompt: Prompt) {
        pickedPrompt = prompt.name
        promptArguments = Dictionary(prompt.arguments.map { ($0.name, "") }, uniquingKeysWith: { $1 })
        outcome = nil
    }

    /// The arguments a schema asks for, each with an empty value of its type —
    /// the required ones and the rest, as a start to fill in.
    package static func skeleton(_ schema: JSONValue) -> JSONValue {
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

    package func call() {
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

    package func read() {
        guard let server = selected, let client = clients[server.id], !resourceURI.isEmpty else { return }
        let uri = resourceURI
        perform { try await client.readResource(uri) }
    }

    package func getPrompt() {
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
