import Foundation

/// A gRPC request as it is sent: its address, the method, the metadata
/// (the collection's and folders' headers, the request's own, its auth)
/// and its messages as JSON — variables filled as an HTTP request's are.
package struct GRPCPlan: Equatable, Sendable {
    package var address: String
    package var method: String
    package var metadata: [(String, String)]
    package var messages: [JSONValue]
    package var protoFiles: [URL]
    package var importPaths: [URL]

    package static func == (a: GRPCPlan, b: GRPCPlan) -> Bool {
        a.address == b.address && a.method == b.method && a.metadata.map { "\($0.0)=\($0.1)" } == b.metadata.map { "\($0.0)=\($0.1)" }
            && a.messages == b.messages && a.protoFiles == b.protoFiles
    }

    package struct Problem: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    package static func make(_ file: BruFile, context: APIRequestPlan.Context, collection: BrunoCollection?) throws -> GRPCPlan {
        var vars = context.variables
        vars.collection = APIVariables.map(context.collectionFile?.preRequestVars ?? [])
        vars.folders = context.folderFiles.map { APIVariables.map($0.preRequestVars) }
        vars.request = APIVariables.map(file.preRequestVars)
        let fill = { vars.interpolate($0) }

        var metadata: [(String, String)] = []
        func add(_ pairs: [BruPair]) {
            for pair in pairs where pair.enabled {
                metadata.removeAll { $0.0.caseInsensitiveCompare(pair.key) == .orderedSame }
                metadata.append((pair.key, fill(pair.value)))
            }
        }
        add(context.collectionFile?.headers ?? [])
        context.folderFiles.forEach { add($0.headers) }
        add(file.metadata)

        // Auth: the request's (in its grpc block), or the nearest folder's.
        var authFile = file
        var mode = file.grpcAuthMode
        if mode == .inherit {
            mode = .none
            if let folder = context.folderFiles.reversed().first(where: { $0.has("auth") && $0.defaultAuthMode != .inherit }) {
                (authFile, mode) = (folder, folder.defaultAuthMode)
            } else if let collection = context.collectionFile, collection.has("auth") {
                (authFile, mode) = (collection, collection.defaultAuthMode)
            }
        }
        switch mode {
        case .none, .inherit: break
        case .bearer:
            let token = fill(authFile.value("token", in: "auth:bearer") ?? "")
            if !token.isEmpty { add([BruPair(key: "authorization", value: "Bearer \(token)")]) }
        case .basic:
            let user = fill(authFile.value("username", in: "auth:basic") ?? "")
            let password = fill(authFile.value("password", in: "auth:basic") ?? "")
            add([BruPair(key: "authorization", value: "Basic " + Data("\(user):\(password)".utf8).base64EncodedString())])
        case .apikey:
            let key = fill(authFile.value("key", in: "auth:apikey") ?? "")
            if !key.isEmpty { add([BruPair(key: key, value: fill(authFile.value("value", in: "auth:apikey") ?? ""))]) }
        default:
            throw Problem(message: "\(mode.title) isn't sent with gRPC here — Bearer, Basic or an API key are.")
        }

        let messages = try file.grpcMessages.map { message -> JSONValue in
            let text = fill(message.content).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .object([:]) }
            do {
                return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            } catch {
                throw Problem(message: "“\(message.name)” isn't JSON: \(error.localizedDescription)")
            }
        }
        // The request's .proto, else the collection's; none: reflection.
        var protoFiles: [URL] = []
        var importPaths: [URL] = []
        if let root = collection?.root ?? context.collectionRoot {
            let named = file.protoPath.isEmpty ? (collection?.protoFiles ?? []) : [file.protoPath]
            protoFiles = named.map { root.appendingPathComponent($0).standardizedFileURL }
            importPaths = (collection?.protoImportPaths ?? []).map { root.appendingPathComponent($0).standardizedFileURL }
        }
        return GRPCPlan(
            address: fill(file.grpcURL).trimmingCharacters(in: .whitespaces), method: file.grpcMethod, metadata: metadata, messages: messages,
            protoFiles: protoFiles, importPaths: importPaths)
    }
}

/// What a gRPC call gave back.
package struct GRPCResult: Equatable, Sendable {
    package var method = ""
    package var kind = ""
    package var sent: [JSONValue] = []
    package var received: [JSONValue] = []
    package var status: Int?
    package var statusMessage = ""
    package var headers: [String] = []
    package var trailers: [String] = []
    package var duration: TimeInterval = 0
    package var error: String?
    package var running = false

    package var statusName: String { status.map(GRPCConnection.statusName) ?? "" }
    package var succeeded: Bool { error == nil && status == 0 }
}

package enum GRPCSchemaState: Equatable, Sendable {
    case loading
    case loaded(Protobuf.Registry)
    case failed(String)
}

extension APIWorkspace {
    private func grpcContext(_ file: BruFile, at url: URL) -> (APIRequestPlan.Context, BrunoCollection?) {
        let setup = setup(for: url, file: file)
        var context = APIRequestPlan.Context()
        context.collectionRoot = setup.collectionRoot
        context.collectionFile = setup.collectionFile
        context.folderFiles = setup.folderFiles
        context.variables.environment = setup.environment
        context.variables.runtime = setup.runtime
        context.variables.processEnv = setup.processEnv
        return (context, collection(containing: url))
    }

    package func grpcPlan(_ file: BruFile, at url: URL) throws -> GRPCPlan {
        let (context, collection) = grpcContext(file, at: url)
        return try GRPCPlan.make(file, context: context, collection: collection)
    }

    /// Where a request's methods come from: its .proto files, else its server.
    package static func grpcSchemaKey(_ plan: GRPCPlan) -> String {
        plan.protoFiles.isEmpty ? "reflection:" + plan.address : "proto:" + plan.protoFiles.map(\.path).joined(separator: ",")
    }

    package func grpcSchema(_ file: BruFile, at url: URL) -> GRPCSchemaState? {
        (try? grpcPlan(file, at: url)).flatMap { grpcSchemas[Self.grpcSchemaKey($0)] }
    }

    /// The services and methods, read once until Refresh: protoc on the
    /// collection's .proto files, or the server's reflection.
    package func loadGRPCSchema(_ file: BruFile, at url: URL, force: Bool = false) {
        guard let plan = try? grpcPlan(file, at: url), !plan.address.isEmpty || !plan.protoFiles.isEmpty else { return }
        let key = Self.grpcSchemaKey(plan)
        if !force, let state = grpcSchemas[key] {
            if case .failed = state {} else { return }
        }
        grpcSchemas[key] = .loading
        Task { [weak self] in
            let state: GRPCSchemaState
            do {
                state = .loaded(try await Self.registry(for: plan))
            } catch {
                state = .failed(error.localizedDescription)
            }
            self?.grpcSchemas[key] = state
        }
    }

    package nonisolated static func registry(for plan: GRPCPlan) async throws -> Protobuf.Registry {
        if !plan.protoFiles.isEmpty {
            let files = plan.protoFiles
            let imports = plan.importPaths
            return try await Task.detached { try GRPCProtoc.registry(files: files, importPaths: imports) }.value
        }
        guard let endpoint = GRPCConnection.endpoint(plan.address) else { throw GRPCPlan.Problem(message: "The URL isn't an address: “\(plan.address)”.") }
        let connection = try await GRPCConnection.connect(host: endpoint.host, port: endpoint.port, tls: endpoint.tls)
        defer { connection.close() }
        return try await GRPCReflection.registry(connection, metadata: plan.metadata, prefix: endpoint.prefix)
    }

    package func grpcResult(for url: URL) -> GRPCResult? { grpcResults[Self.key(url)] }

    /// Sends it: its schema read (or reused), its messages encoded by the
    /// method's input type, the replies shown as they arrive.
    package func sendGRPC(_ file: BruFile, at url: URL) {
        let key = Self.key(url)
        grpcTasks[key]?.cancel()
        var result = GRPCResult(method: file.grpcMethod, running: true)
        let plan: GRPCPlan
        do {
            plan = try grpcPlan(file, at: url)
        } catch {
            result.running = false
            result.error = error.localizedDescription
            grpcResults[key] = result
            return
        }
        grpcResults[key] = result
        let schemaKey = Self.grpcSchemaKey(plan)
        let known: Protobuf.Registry? = if case .loaded(let registry)? = grpcSchemas[schemaKey] { registry } else { nil }
        let timeout = options.timeout
        grpcTasks[key] = Task { [weak self] in
            let started = Date()
            do {
                let registry: Protobuf.Registry
                if let known {
                    registry = known
                } else {
                    registry = try await Self.registry(for: plan)
                    self?.grpcSchemas[schemaKey] = .loaded(registry)
                }
                guard !plan.method.isEmpty else { throw GRPCPlan.Problem(message: "Pick a method.") }
                guard let (_, method) = registry.method(path: plan.method) else {
                    throw GRPCPlan.Problem(message: "The server has no method \(plan.method) — it has \(registry.paths.joined(separator: ", ")).")
                }
                // One message for a unary call or a server stream; every one for the rest.
                let messages = method.clientStreaming ? plan.messages : Array(plan.messages.prefix(1))
                let encoded = try (messages.isEmpty ? [JSONValue.object([:])] : messages).map {
                    try Protobuf.encode($0, as: method.input, registry: registry)
                }
                guard let endpoint = GRPCConnection.endpoint(plan.address) else { throw GRPCPlan.Problem(message: "The URL isn't an address: “\(plan.address)”.") }
                let connection = try await GRPCConnection.connect(host: endpoint.host, port: endpoint.port, tls: endpoint.tls)
                defer { connection.close() }
                await MainActor.run {
                    self?.grpcResults[key]?.kind = method.kind
                    self?.grpcResults[key]?.sent = messages
                }
                let reply = try await connection.call(endpoint.prefix + plan.method, metadata: plan.metadata, messages: encoded, timeout: timeout) { data in
                    let json = (try? Protobuf.decode(data, as: method.output, registry: registry)) ?? .string(data.base64EncodedString())
                    Task { @MainActor in self?.grpcResults[key]?.received.append(json) }
                }
                let received = try reply.messages.map { try Protobuf.decode($0, as: method.output, registry: registry) }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.grpcResults[key] = GRPCResult(
                        method: plan.method, kind: method.kind, sent: messages, received: received, status: reply.status,
                        statusMessage: reply.statusMessage, headers: reply.headers.map { "\($0.name): \($0.value)" },
                        trailers: reply.trailers.map { "\($0.name): \($0.value)" }, duration: Date().timeIntervalSince(started))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.grpcResults[key]?.running = false
                    self?.grpcResults[key]?.error = error.localizedDescription
                    self?.grpcResults[key]?.duration = Date().timeIntervalSince(started)
                }
            }
        }
    }

    package func cancelGRPC(_ url: URL) {
        let key = Self.key(url)
        grpcTasks[key]?.cancel()
        grpcTasks[key] = nil
        grpcResults[key]?.running = false
        grpcResults[key]?.error = "Cancelled."
    }
}
