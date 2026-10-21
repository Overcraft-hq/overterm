import Foundation

/// What an agent can do with the API client of its tab's checkout — the
/// window answers with an APIWorkspace on that checkout; tests hand in one
/// of their own.
@MainActor
protocol AgentAPI: AnyObject {
    /// The checkout's collections — never the user's own My Requests.
    var checkoutCollections: [BrunoCollection] { get }
    /// The environment picked for a collection (the panel's, or its last).
    func pickedEnvironment(for collection: BrunoCollection) -> String?
    func collection(containing url: URL) -> BrunoCollection?
    /// Each takes the environment fixed: an agent's choice is never "the
    /// panel's, whatever that is by the time it runs".
    func runFile(_ url: URL, environment: APIWorkspace.EnvironmentChoice) async -> APIExecution.Result?
    func runAdHoc(_ file: BruFile, in collection: BrunoCollection?, environment: APIWorkspace.EnvironmentChoice) async -> APIExecution.Result
    func runAll(_ items: [APIItem], title: String, in collection: BrunoCollection, environment: String?) async -> [APIRunner.Entry]
    /// Every secret value a run could fill in, to keep out of what agents are told.
    func allSecretValues() -> [String]
    /// Its collections, read if they haven't been.
    func loadIfNeeded() async
}

/// The API client's MCP tools, beside the browser's on the same server
/// (BrowserBridge): an agent in Overterm lists the checkout's collection,
/// sends its requests or one of its own, and runs the collection's tests
/// — the user watching the same results in the panel.
@MainActor
enum APIMCP {
    static func call(_ name: String, _ arguments: [String: Any], api: AgentAPI) async throws -> [String: Any] {
        await api.loadIfNeeded()
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let environment = string("environment")
        // Secrets fill requests in, but are never repeated back to an agent —
        // any environment's of any collection, whichever a run used.
        // Taken when the answer is written, after the run: a secret its script
        // set with bru.setEnvVar is masked in this very answer.
        func redacted(_ text: String) -> [String: Any] { BrowserMCP.textResult(redact(text, api.allSecretValues())) }
        /// The environment for `collection`: the one named — which it must
        /// have; a typo for staging must never run on what is picked — or
        /// its pick, fixed now.
        func choice(for collection: BrunoCollection?) throws -> APIWorkspace.EnvironmentChoice {
            guard let collection else { return .none }
            guard let environment else { return api.pickedEnvironment(for: collection).map(APIWorkspace.EnvironmentChoice.named) ?? .none }
            guard collection.environments.contains(where: { $0.name == environment }) else {
                let known = collection.environments.map(\.name)
                throw BrowserMCP.ToolError(
                    message: "“\(collection.name)” has no environment “\(environment)”"
                        + (known.isEmpty ? "." : ". It has: \(known.joined(separator: ", ")).")
                )
            }
            return .named(environment)
        }
        switch name {
        case "api_collections":
            return BrowserMCP.textResult(describe(api))
        case "api_send":
            guard let target = string("request") else { throw BrowserMCP.ToolError(message: "api_send needs “request”: a path or a name from api_collections.") }
            guard let url = find(target, in: api) else {
                throw BrowserMCP.ToolError(message: "No request “\(target)” — api_collections lists them.")
            }
            guard let result = await api.runFile(url, environment: try choice(for: api.collection(containing: url))) else {
                throw BrowserMCP.ToolError(message: "\(url.lastPathComponent) can't be read.")
            }
            return redacted(report(result, limit: limit(arguments)))
        case "api_request":
            guard let address = string("url") else { throw BrowserMCP.ToolError(message: "api_request needs “url”.") }
            var file = BruFile.newRequest(name: "Agent request", method: (string("method") ?? "GET").lowercased(), url: address, seq: 1)
            file.authMode = .none
            if let headers = arguments["headers"] as? [String: Any] {
                file.headers = headers.keys.sorted().map { BruPair(key: $0, value: "\(headers[$0]!)") }
            }
            if let body = arguments["body"] {
                let text = (body as? String) ?? APIImport.prettyJSON(body)
                let isJSON = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
                file.bodyMode = isJSON ? .json : .text
                file.setBody(file.bodyMode, text)
            }
            // The checkout's collection — the one with that environment, if one
            // is named — never the user's own My Requests.
            let target =
                api.checkoutCollections.first { collection in environment.map { name in collection.environments.contains { $0.name == name } } ?? true }
                ?? api.checkoutCollections.first
            return redacted(report(await api.runAdHoc(file, in: target, environment: try choice(for: target)), limit: limit(arguments)))
        case "api_run":
            guard let collection = api.checkoutCollections.first else { throw BrowserMCP.ToolError(message: "This checkout has no Bruno collection.") }
            var items = [collection.tree]
            var title = collection.name
            if let folder = string("folder") {
                guard let found = findFolder(folder, in: collection) ?? collection.tree.findFolder(named: folder) else {
                    throw BrowserMCP.ToolError(message: "No folder “\(folder)”.")
                }
                items = [found]
                title = found.name
            }
            let pinned: String? = if case .named(let name) = try choice(for: collection) { name } else { nil }
            let entries = await api.runAll(items, title: title, in: collection, environment: pinned)
            if entries.isEmpty, !items.flatMap(\.allRequests).isEmpty {
                return BrowserMCP.textResult("The run was replaced by another one (the user's, or a second api_run) before it finished.")
            }
            return redacted(summary(entries, title: title))
        default:
            throw BrowserMCP.ToolError(message: "Unknown tool: \(name)")
        }
    }

    private static func limit(_ arguments: [String: Any]) -> Int {
        max(1000, min(arguments["max_body_chars"] as? Int ?? 20_000, 200_000))
    }

    /// A folder by its path in the collection ("Users/Admin") — inside it,
    /// with links resolved, as for requests.
    static func findFolder(_ path: String, in collection: BrunoCollection) -> APIItem? {
        let root = collection.root.resolvingSymlinksInPath().path
        let candidate = collection.root.appendingPathComponent(path).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root + "/") else { return nil }
        let found = collection.tree.find(candidate.standardizedFileURL) ?? collection.tree.find(collection.root.appendingPathComponent(path).standardizedFileURL)
        return found?.isFolder == true ? found : nil
    }

    /// Each secret value (four characters or more: shorter ones would
    /// mask ordinary text) replaced by a marker.
    static func redact(_ text: String, _ secrets: [String]) -> String {
        // As written, and as it reads once a URL has percent-encoded it.
        let forms = secrets.filter { $0.count >= 4 }.flatMap { secret in
            [secret, secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), APIRequestPlan.formEncode(secret)].compactMap { $0 }
        }
        return Set(forms).sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: "‹secret›") }
    }

    /// A request by its path in the collection or its name — never a file
    /// outside the collection: an absolute path or `..` would run another
    /// checkout's scripts in this one.
    static func find(_ target: String, in api: AgentAPI) -> URL? {
        for collection in api.checkoutCollections {
            let root = APIWorkspace.canonicalPath(collection.root) + "/"
            let relative = target.hasPrefix(root) ? String(target.dropFirst(root.count)) : target
            for candidate in [collection.root.appendingPathComponent(relative), collection.root.appendingPathComponent(relative + ".bru")]
            where candidate.pathExtension == "bru" && FileManager.default.fileExists(atPath: candidate.path)
                && APIWorkspace.canonicalPath(candidate.resolvingSymlinksInPath()).hasPrefix(
                    APIWorkspace.canonicalPath(collection.root.resolvingSymlinksInPath()) + "/")
            {
                return candidate.standardizedFileURL
            }
            if let named = collection.requests.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) { return named.url }
        }
        return nil
    }

    static func describe(_ api: AgentAPI) -> String {
        guard !api.checkoutCollections.isEmpty else {
            return "This checkout has no Bruno collection (a folder with bruno.json). api_request sends one-off requests; the user can import an OpenAPI document from the API panel."
        }
        var lines: [String] = []
        for collection in api.checkoutCollections {
            lines.append("Collection “\(collection.name)” at \(collection.root.path)")
            let environments = collection.environments.map(\.name)
            lines.append(
                "Environments: \(environments.isEmpty ? "none" : environments.joined(separator: ", "))"
                    + (api.pickedEnvironment(for: collection).map { " — the user picked \($0)" } ?? " — none picked"))
            func walk(_ item: APIItem, _ depth: Int) {
                for child in item.children ?? [] {
                    let indent = String(repeating: "  ", count: depth)
                    if child.isFolder {
                        lines.append("\(indent)\(child.name)/")
                        walk(child, depth + 1)
                    } else {
                        let path = String(child.url.standardizedFileURL.path.dropFirst(collection.root.standardizedFileURL.path.count + 1))
                        lines.append("\(indent)\(child.method ?? "GET") \(child.name) — \(path)")
                    }
                }
            }
            walk(collection.tree, 0)
        }
        return lines.joined(separator: "\n")
    }

    static func report(_ result: APIExecution.Result, limit: Int) -> String {
        var lines: [String] = []
        if let plan = result.plan {
            lines.append("\(plan.method) \(plan.url.absoluteString)")
            if !plan.unresolved.isEmpty { lines.append("Undefined variables: " + plan.unresolved.joined(separator: ", ")) }
        }
        if let error = result.error { lines.append("Error: \(error)") }
        if let response = result.response {
            lines.append("\(response.status) \(response.statusText) — \(APIResponse.formatDuration(response.duration)), \(APIResponse.formatSize(response.size))")
            lines.append(response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
            var body = response.display
            if body.count > limit { body = String(body.prefix(limit)) + "\n… (\(response.size) bytes in all)" }
            lines.append("")
            lines.append(body)
        }
        if !result.tests.isEmpty {
            lines.append("")
            lines.append("Tests: \(result.passed)/\(result.tests.count) passed")
            for test in result.tests {
                lines.append("\(test.passed ? "✓" : "✗") \(test.name)\(test.error.map { " — \($0)" } ?? "")")
            }
        }
        if !result.logs.isEmpty {
            lines.append("")
            lines.append("Console:")
            lines += result.logs.map { "[\($0.level.rawValue)] \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    static func summary(_ entries: [APIRunner.Entry], title: String) -> String {
        let done = entries.filter { $0.state == .done }
        let failed = done.filter { !$0.passed }
        var lines = ["Ran \(title): \(done.count) of \(entries.count) requests, \(done.count - failed.count) passed, \(failed.count) failed."]
        for entry in entries {
            guard let result = entry.result else {
                lines.append("· \(entry.name) — not run")
                continue
            }
            let status = result.response.map { "\($0.status)" } ?? (result.error ?? "no response")
            let tests = result.tests.isEmpty ? "" : ", tests \(result.passed)/\(result.tests.count)"
            lines.append("\(entry.passed ? "✓" : "✗") \(entry.method) \(entry.name) — \(status)\(tests)")
            for test in result.tests where !test.passed {
                lines.append("    ✗ \(test.name)\(test.error.map { " — \($0)" } ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }

    static let tools: [[String: Any]] = [
        tool(
            "api_collections",
            "The Bruno collection in your checkout: its requests (method, name, path) by folder, and its environments. Requests are .bru files you can edit; api_send runs one.",
            [:]),
        tool(
            "api_send",
            "Send one of the collection's requests — its scripts, assertions and tests run as in Bruno — and get the response and the test results.",
            [
                "request": ["type": "string", "description": "Its path in the collection (Users/List.bru) or its name."],
                "environment": ["type": "string", "description": "An environment's name; the one the user picked if omitted."],
                "max_body_chars": ["type": "integer", "description": "How much of the body to return (default 20000)."],
            ], required: ["request"]),
        tool(
            "api_request",
            "Send a one-off HTTP request (not saved): {{variables}} of the collection's environment are filled in.",
            [
                "method": ["type": "string", "description": "GET, POST, PUT, PATCH, DELETE… (default GET)."],
                "url": ["type": "string", "description": "The URL; {{baseUrl}}/path works."],
                "headers": ["type": "object", "description": "Header names to values."],
                "body": ["description": "A JSON value, or text."],
                "environment": ["type": "string", "description": "An environment's name; the one the user picked if omitted."],
                "max_body_chars": ["type": "integer", "description": "How much of the body to return (default 20000)."],
            ], required: ["url"]),
        tool(
            "api_run",
            "Run the whole collection, or one folder, in order — as Bruno's runner does — and get each request's status and failing tests. The user sees the run in Overterm.",
            [
                "folder": ["type": "string", "description": "A folder's path or name; the whole collection if omitted."],
                "environment": ["type": "string", "description": "An environment's name; the one the user picked if omitted."],
            ]),
    ]
}

extension APIItem {
    func findFolder(named name: String) -> APIItem? {
        for child in children ?? [] where child.isFolder {
            if child.name.caseInsensitiveCompare(name) == .orderedSame { return child }
            if let found = child.findFolder(named: name) { return found }
        }
        return nil
    }
}

/// The window's APIWorkspace, as an agent's: on that agent's checkout.
/// An agent's environment is for its own call: passed down to that run,
/// never set as the panel's pick, which a request sent meanwhile would use.
extension APIWorkspace: AgentAPI {
    func runFile(_ url: URL, environment: EnvironmentChoice) async -> APIExecution.Result? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return await run(BruFile(parsing: text), at: url, environment: environment)
    }

    func runAdHoc(_ file: BruFile, in collection: BrunoCollection?, environment: EnvironmentChoice) async -> APIExecution.Result {
        // Inside the collection's folder, so its environment and .env apply.
        let url = collection?.root.appendingPathComponent(".agent-request.bru")
        // The agent names the host here: no secret is filled in.
        let setup = setup(for: url, file: file, environment: environment, includeSecrets: false)
        return await APIExecution.run(setup, client: client(for: setup.collectionRoot), scripts: scripts)
    }

    func runAll(_ items: [APIItem], title: String, in collection: BrunoCollection, environment: String?) async -> [APIRunner.Entry] {
        let id = runner.run(items, title: title, in: collection, workspace: self, environment: environment)
        while runner.isRunning(id) { try? await Task.sleep(nanoseconds: 50_000_000) }
        return runner.entries(of: id)
    }
}
