import Foundation

/// An MCP server the API client can open: how it is reached, and where it
/// was found. The agents' own configs are read, never written — the
/// checkout's `.mcp.json`, Claude Code's `~/.claude.json` (the user's and
/// this checkout's), Codex's `~/.codex/config.toml`, opencode's
/// `~/.config/opencode/opencode.json(c)` and Gemini CLI's
/// `~/.gemini/settings.json` — and servers added
/// here are Overterm's, in its own folder: nothing goes into a Bruno
/// collection, which has no MCP request (Bruno would refuse the file).
struct MCPServerConfig: Equatable, Hashable, Identifiable, Sendable {
    enum Transport: Equatable, Hashable, Sendable {
        /// A process, its stdin and stdout JSON-RPC a line each.
        case stdio(command: String, args: [String], env: [String: String])
        /// Streamable HTTP: a POST a message, the answer JSON or an event stream.
        case http(url: String, headers: [String: String])
        /// The 2024 transport: an event stream, and POSTs to the endpoint it names.
        case sse(url: String, headers: [String: String])

        var kind: String {
            switch self {
            case .stdio: "stdio"
            case .http: "http"
            case .sse: "sse"
            }
        }

        /// What it runs or reaches, on one line.
        var summary: String {
            switch self {
            case .stdio(let command, let args, _): ([command] + args).joined(separator: " ")
            case .http(let url, _), .sse(let url, _): url
            }
        }
    }

    enum Source: String, Sendable, CaseIterable {
        case project, claudeLocal, claudeUser, codex, opencode, gemini, overterm

        var title: String {
            switch self {
            case .project: ".mcp.json"
            case .claudeLocal: "Claude Code — this checkout"
            case .claudeUser: "Claude Code"
            case .codex: "Codex"
            case .opencode: "opencode"
            case .gemini: "Gemini CLI"
            case .overterm: "Added here"
            }
        }
    }

    var name: String
    var source: Source
    var transport: Transport
    /// Where a stdio server runs: the checkout, for a project's.
    var directory: String?
    /// An added one's: its keychain account names its secrets.
    var id: String { "\(source.rawValue):\(name)" }

    // MARK: Reading the agents' configs

    /// Every server the checkout and this Mac's agents know, a name once
    /// per source; `home` is the user's (a test's own folder in tests).
    static func discover(checkout: URL?, home: URL, environment: [String: String]) -> [MCPServerConfig] {
        var out: [MCPServerConfig] = []
        if let checkout, let data = try? Data(contentsOf: checkout.appendingPathComponent(".mcp.json")) {
            out += servers(fromJSON: data, source: .project, directory: checkout.path, environment: environment)
        }
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let checkout,
                let projects = object["projects"] as? [String: Any],
                let project = projects[checkout.path] as? [String: Any] ?? projects[checkout.standardizedFileURL.path] as? [String: Any],
                let servers = project["mcpServers"] as? [String: Any]
            {
                out += Self.servers(servers, source: .claudeLocal, directory: checkout.path, environment: environment)
            }
            if let servers = object["mcpServers"] as? [String: Any] {
                out += Self.servers(servers, source: .claudeUser, directory: nil, environment: environment)
            }
        }
        if let text = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
            out += codex(text, environment: environment)
        }
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".config")
        for name in ["opencode.json", "opencode.jsonc"] {
            if let text = try? String(contentsOf: config.appendingPathComponent("opencode/\(name)"), encoding: .utf8) {
                out += opencode(text, environment: environment)
                break
            }
        }
        if let text = try? String(contentsOf: home.appendingPathComponent(".gemini/settings.json"), encoding: .utf8) {
            out += gemini(text, environment: environment)
        }
        return out
    }

    /// opencode's `mcp` object (JSONC): `{"type": "local", "command":
    /// [program, args…], "environment": {…}}` or `{"type": "remote",
    /// "url": …, "headers": {…}}`; `{env:VAR}` substituted, as opencode does.
    static func opencode(_ text: String, environment: [String: String]) -> [MCPServerConfig] {
        guard let object = try? SettingsJSON.object(from: text), let servers = object["mcp"] as? [String: Any] else { return [] }
        func expand(_ any: Any?) -> String? {
            guard var text = any as? String else { return nil }
            while let start = text.range(of: "{env:"), let end = text[start.upperBound...].firstIndex(of: "}") {
                text.replaceSubrange(start.lowerBound...end, with: environment[String(text[start.upperBound..<end])] ?? "")
            }
            return text
        }
        func strings(_ any: Any?) -> [String: String] { (any as? [String: Any] ?? [:]).compactMapValues { expand($0) } }
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            if let url = expand(entry["url"]) {
                return MCPServerConfig(name: name, source: .opencode, transport: .http(url: url, headers: strings(entry["headers"])))
            }
            let command = (entry["command"] as? [Any] ?? []).compactMap { expand($0) }
            guard let program = command.first else { return nil }
            return MCPServerConfig(
                name: name, source: .opencode, transport: .stdio(command: program, args: Array(command.dropFirst()), env: strings(entry["environment"])))
        }
    }

    /// Gemini CLI's `mcpServers` (JSON with comments): `command`/`args`/
    /// `env`, `httpUrl` (streamable HTTP) or `url` (SSE, unless `type` says
    /// http), `headers`; `$VAR` and `${VAR}` expanded, as Gemini does.
    static func gemini(_ text: String, environment: [String: String]) -> [MCPServerConfig] {
        guard let object = try? SettingsJSON.object(from: text), let servers = object["mcpServers"] as? [String: Any] else { return [] }
        func expand(_ any: Any?) -> String? { (any as? String).map { expandDollar($0, environment) } }
        func strings(_ any: Any?) -> [String: String] { (any as? [String: Any] ?? [:]).compactMapValues { expand($0) } }
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let transport: Transport
            if let url = expand(entry["httpUrl"]) {
                transport = .http(url: url, headers: strings(entry["headers"]))
            } else if let url = expand(entry["url"]) {
                transport =
                    (entry["type"] as? String)?.lowercased() == "http"
                    ? .http(url: url, headers: strings(entry["headers"])) : .sse(url: url, headers: strings(entry["headers"]))
            } else if let command = expand(entry["command"]) {
                transport = .stdio(command: command, args: (entry["args"] as? [Any] ?? []).compactMap { expand($0) }, env: strings(entry["env"]))
            } else {
                return nil
            }
            return MCPServerConfig(name: name, source: .gemini, transport: transport, directory: expand(entry["cwd"]))
        }
    }

    /// `$VAR`, `${VAR}` and `${VAR:-default}`; an unset one left as written.
    static func expandDollar(_ text: String, _ environment: [String: String]) -> String {
        guard text.contains("$") else { return text }
        let pattern = /\$(?:(?<bare>\w+)|\{(?<name>[^}:]+?)(?::-(?<fallback>[^}]*))?\})/
        var out = ""
        var rest = Substring(text)
        while let match = rest.firstMatch(of: pattern) {
            out += rest[..<match.range.lowerBound]
            let name = String(match.output.bare ?? match.output.name ?? "")
            out += environment[name] ?? match.output.fallback.map(String.init) ?? String(match.output.0)
            rest = rest[match.range.upperBound...]
        }
        return out + rest
    }

    /// `{"mcpServers": {name: {...}}}` — Claude Code's and Claude Desktop's shape.
    static func servers(fromJSON data: Data, source: Source, directory: String?, environment: [String: String]) -> [MCPServerConfig] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let servers = object["mcpServers"] as? [String: Any]
        else { return [] }
        return Self.servers(servers, source: source, directory: directory, environment: environment)
    }

    static func servers(_ servers: [String: Any], source: Source, directory: String?, environment: [String: String]) -> [MCPServerConfig] {
        servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            func text(_ any: Any?) -> String? { (any as? String).map { expand($0, environment) } }
            func strings(_ any: Any?) -> [String: String] {
                (any as? [String: Any] ?? [:]).compactMapValues { text($0) }
            }
            let type = (entry["type"] as? String)?.lowercased()
            let transport: Transport
            if let url = text(entry["url"]) {
                transport = type == "sse" ? .sse(url: url, headers: strings(entry["headers"])) : .http(url: url, headers: strings(entry["headers"]))
            } else if let command = text(entry["command"]) {
                transport = .stdio(command: command, args: (entry["args"] as? [Any] ?? []).compactMap(text), env: strings(entry["env"]))
            } else {
                return nil
            }
            return MCPServerConfig(name: name, source: source, transport: transport, directory: directory)
        }
    }

    /// `${VAR}` and `${VAR:-default}`, as Claude Code expands `.mcp.json`.
    static func expand(_ text: String, _ environment: [String: String]) -> String {
        guard text.contains("${") else { return text }
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "${") {
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
                out += rest[start.lowerBound...]
                return out
            }
            let inner = String(rest[start.upperBound..<end])
            let parts = inner.components(separatedBy: ":-")
            out += environment[parts[0]] ?? (parts.count > 1 ? parts.dropFirst().joined(separator: ":-") : "")
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    /// Codex's `[mcp_servers.<name>]` tables: `command`, `args`, `env`, or `url`.
    /// Only what those tables use of TOML: strings, arrays of strings, inline
    /// tables of strings, `[mcp_servers.<name>.env]` sub-tables.
    static func codex(_ text: String, environment: [String: String]) -> [MCPServerConfig] {
        var tables: [String: [String: Any]] = [:]
        var order: [String] = []
        var current: (server: String, sub: String?)?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let parts = TOMLLine.keyPath(header)
                if parts.count >= 2, parts[0] == "mcp_servers" {
                    current = (parts[1], parts.count > 2 ? parts[2] : nil)
                    if tables[parts[1]] == nil {
                        tables[parts[1]] = [:]
                        order.append(parts[1])
                    }
                } else {
                    current = nil
                }
                continue
            }
            guard let current, let (key, value) = TOMLLine.pair(line) else { continue }
            if let sub = current.sub {
                var table = tables[current.server]?[sub] as? [String: Any] ?? [:]
                table[key] = value
                tables[current.server]?[sub] = table
            } else {
                tables[current.server]?[key] = value
            }
        }
        var servers: [String: Any] = [:]
        for name in order { servers[name] = tables[name] }
        return Self.servers(servers, source: .codex, directory: nil, environment: environment)
    }
}

/// A line of TOML, as far as an MCP server's table needs it.
enum TOMLLine {
    /// `mcp_servers."my server".env` → ["mcp_servers", "my server", "env"].
    static func keyPath(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for c in text {
            if let open = quote {
                if c == open { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    static func pair(_ line: String) -> (String, Any)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = keyPath(String(line[..<equals])).joined(separator: ".")
        var rest = Substring(line[line.index(after: equals)...]).drop { $0 == " " }
        guard let value = Self.value(&rest) else { return nil }
        return (key, value)
    }

    private static func value(_ rest: inout Substring) -> Any? {
        rest = rest.drop { $0 == " " }
        guard let first = rest.first else { return nil }
        switch first {
        case "\"", "'":
            rest = rest.dropFirst()
            var out = ""
            while let c = rest.first {
                rest = rest.dropFirst()
                if c == first { return out }
                if c == "\\", first == "\"", let next = rest.first {
                    rest = rest.dropFirst()
                    switch next {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(next)
                    }
                    continue
                }
                out.append(c)
            }
            return out
        case "[":
            rest = rest.dropFirst()
            var items: [Any] = []
            while true {
                rest = rest.drop { $0 == " " || $0 == "," }
                if rest.first == "]" {
                    rest = rest.dropFirst()
                    return items
                }
                guard let item = value(&rest) else { return items }
                items.append(item)
            }
        case "{":
            rest = rest.dropFirst()
            var table: [String: Any] = [:]
            while true {
                rest = rest.drop { $0 == " " || $0 == "," }
                if rest.first == "}" {
                    rest = rest.dropFirst()
                    return table
                }
                guard let equals = rest.firstIndex(of: "=") else { return table }
                let key = keyPath(String(rest[..<equals])).joined(separator: ".")
                rest = rest[rest.index(after: equals)...]
                guard let item = value(&rest) else { return table }
                table[key] = item
            }
        default:
            // A number or a boolean: kept as its text.
            let word = rest.prefix { $0 != "," && $0 != "]" && $0 != "}" && $0 != " " && $0 != "#" }
            rest = rest.dropFirst(word.count)
            return String(word)
        }
    }
}

/// Servers added here: their names, how they are reached — their headers'
/// and env's values in the keychain, never in the file.
struct MCPAddedServers {
    let file: URL
    let secrets: MCPSecrets

    struct Stored: Codable, Equatable {
        var name: String
        var kind: String
        var command: String?
        var args: [String]?
        var url: String?
        /// Names only: the values are secrets.
        var env: [String]?
        var headers: [String]?
    }

    func load() -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.map { item in
            let id = "overterm:\(item.name)"
            func values(_ names: [String]?) -> [String: String] {
                Dictionary((names ?? []).map { ($0, secrets.value(server: id, name: $0) ?? "") }, uniquingKeysWith: { $1 })
            }
            let transport: MCPServerConfig.Transport =
                switch item.kind {
                case "stdio": .stdio(command: item.command ?? "", args: item.args ?? [], env: values(item.env))
                case "sse": .sse(url: item.url ?? "", headers: values(item.headers))
                default: .http(url: item.url ?? "", headers: values(item.headers))
                }
            return MCPServerConfig(name: item.name, source: .overterm, transport: transport)
        }
    }

    func save(_ servers: [MCPServerConfig]) throws {
        let stored: [Stored] = servers.filter { $0.source == .overterm }.map { server in
            switch server.transport {
            case .stdio(let command, let args, let env):
                for (name, value) in env { secrets.set(value, server: server.id, name: name) }
                return Stored(name: server.name, kind: "stdio", command: command, args: args, env: env.keys.sorted())
            case .http(let url, let headers), .sse(let url, let headers):
                for (name, value) in headers { secrets.set(value, server: server.id, name: name) }
                return Stored(name: server.name, kind: server.transport.kind, url: url, headers: headers.keys.sorted())
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: file, options: .atomic)
    }

    func remove(_ server: MCPServerConfig) throws {
        switch server.transport {
        case .stdio(_, _, let env): for name in env.keys { secrets.set(nil, server: server.id, name: name) }
        case .http(_, let headers), .sse(_, let headers): for name in headers.keys { secrets.set(nil, server: server.id, name: name) }
        }
        try save(load().filter { $0.name != server.name })
    }
}

/// An added server's secret values: the keychain, or memory for an isolated run.
protocol MCPSecrets: AnyObject, Sendable {
    func value(server: String, name: String) -> String?
    func set(_ value: String?, server: String, name: String)
}

final class KeychainMCPSecrets: MCPSecrets {
    static let service = "Overterm MCP"

    func value(server: String, name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(server)|\(name)", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, server: String, name: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: "\(server)|\(name)",
        ]
        SecItemDelete(match as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Overterm MCP: \(name) (\(server))"
        SecItemAdd(item as CFDictionary, nil)
    }
}

final class MemoryMCPSecrets: MCPSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(server: String, name: String) -> String? { lock.withLock { values["\(server)|\(name)"] } }
    func set(_ value: String?, server: String, name: String) { lock.withLock { values["\(server)|\(name)"] = value } }
}
