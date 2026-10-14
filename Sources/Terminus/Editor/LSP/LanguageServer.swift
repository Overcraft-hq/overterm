import Foundation

enum LanguageServerError: LocalizedError, Equatable {
    case launchFailed(String)
    /// Stopped, or died and not (yet) restarted.
    case notRunning
    /// The process ended while the request waited.
    case exited(Int32)
    case timedOut(String)
    /// The server answered with an error (-32800 cancelled, -32801 content
    /// modified are routine: the answer is stale, ask again or drop it).
    case response(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let why): "language server didn't start: \(why)"
        case .notRunning: "language server isn't running"
        case .exited(let status): "language server exited (\(status))"
        case .timedOut(let method): "\(method) timed out"
        case .response(let code, let message): "\(message) (\(code))"
        }
    }
}

/// One language server process, spoken to over stdin/stdout.
///
/// Safe to use from any thread; the editor calls it from the main actor.
/// Requests are `async throws` and never block a Swift-concurrency thread:
/// the reply arrives on the reader's own GCD thread and resumes the caller.
/// Writes go through a serial GCD queue, so a server slow to read never
/// stalls the main thread on a full pipe.
///
/// Documents are tracked here as well as sent: what was opened before the
/// server answered `initialize` is opened once it has, and a restarted
/// server gets every open document again — the editor never re-sends.
final class LanguageServer: @unchecked Sendable {
    /// How to launch it.
    struct Command: Sendable, Hashable {
        var executable: URL
        var arguments: [String]
        /// Added to the app's environment.
        var environment: [String: String]

        init(executable: URL, arguments: [String] = [], environment: [String: String] = [:]) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
        }
    }

    /// What the server said it does, from its `initialize` answer.
    struct Capabilities: Sendable, Equatable {
        var completion = false
        /// Typing one of these should ask for completions at once.
        var completionTriggerCharacters: [String] = []
        var hover = false
        var definition = false
        var references = false
        var documentSymbol = false
        var formatting = false
        /// 0 none, 1 full text, 2 incremental (sent as full text too — legal).
        var textDocumentSync = 1
        var openClose = true
        var save = true
        var saveIncludesText = false

        init() {}

        init(json: [String: Any]) {
            func provided(_ key: String) -> Bool {
                switch json[key] {
                case let flag as Bool: flag
                case is [String: Any]: true
                default: false
                }
            }
            if let completion = json["completionProvider"] as? [String: Any] {
                self.completion = true
                completionTriggerCharacters = completion["triggerCharacters"] as? [String] ?? []
            }
            hover = provided("hoverProvider")
            definition = provided("definitionProvider")
            references = provided("referencesProvider")
            documentSymbol = provided("documentSymbolProvider")
            formatting = provided("documentFormattingProvider")
            switch json["textDocumentSync"] {
            case let kind as Int:
                textDocumentSync = kind
            case let sync as [String: Any]:
                textDocumentSync = sync["change"] as? Int ?? 0
                openClose = sync["openClose"] as? Bool ?? false
                switch sync["save"] {
                case let flag as Bool: save = flag
                case let options as [String: Any]:
                    save = true
                    saveIncludesText = options["includeText"] as? Bool ?? false
                default: save = false
                }
            default:
                break
            }
        }
    }

    enum State: Sendable, Equatable {
        case idle
        /// Launched; `initialize` not answered yet.
        case starting
        case running
        /// Exited or failed to initialize. `restart()` brings it back.
        case dead
        /// `stop()` ended it.
        case stopped
    }

    let name: String
    let command: Command
    /// The workspace root it was started for.
    let root: URL

    /// Every publishDiagnostics, on the main actor: the file and its whole
    /// current list (an empty list clears it).
    @MainActor var onDiagnostics: (@MainActor (URL, [LSP.Diagnostic]) -> Void)?

    /// How long a feature request may take. A hover that comes after 10 s is
    /// no use; the request is cancelled at the server too.
    static let requestTimeout: TimeInterval = 10
    /// Starting can be slow (node, a cold cache); its answer may take this long.
    static let initializeTimeout: TimeInterval = 60
    static let stderrLineLimit = 200

    private let lock = NSLock()
    private var _state = State.idle
    private var _capabilities: Capabilities?
    private var nextID = 1
    private var pending: [Int: @Sendable (Result<Data, Error>) -> Void] = [:]
    private var readyWaiters: [CheckedContinuation<Capabilities, Error>] = []
    private var documents: [URL: OpenDocument] = [:]
    private var stderrTail: [String] = []
    private var partialStderr = ""
    /// Which launch the current process is; callbacks from an earlier one are ignored.
    private var generation = 0
    private var process: Process?
    private var input: FileHandle?
    private var exited = DispatchSemaphore(value: 0)
    private var _restartCount = 0
    private let writeQueue = DispatchQueue(label: "LanguageServer.write")

    private struct OpenDocument {
        var languageID: String
        var version: Int
        var text: String
    }

    init(name: String, command: Command, root: URL) {
        self.name = name
        self.command = command
        self.root = root
    }

    var state: State { lock.withLock { _state } }
    /// nil until `initialize` is answered.
    var capabilities: Capabilities? { lock.withLock { _capabilities } }
    var processIdentifier: Int32? { lock.withLock { process?.isRunning == true ? process?.processIdentifier : nil } }
    var restartCount: Int { lock.withLock { _restartCount } }
    /// The last lines it wrote to stderr: why it failed, when it did.
    var stderrLines: [String] { lock.withLock { stderrTail } }

    // MARK: - Lifecycle

    /// Launches the process and sends `initialize`; returns at once. Requests
    /// made meanwhile wait for the answer. Throws only if it can't launch.
    func start() throws {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Writing to a server that died would otherwise raise SIGPIPE and
        // take the app with it.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let exited = DispatchSemaphore(value: 0)
        let generation: Int = lock.withLock {
            self.generation += 1
            self.exited = exited
            return self.generation
        }
        process.terminationHandler = { [weak self] process in
            exited.signal()
            self?.died(generation, status: process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            lock.withLock { _state = .dead }
            throw LanguageServerError.launchFailed(error.localizedDescription)
        }
        lock.withLock {
            self.process = process
            input = stdin.fileHandleForWriting
            _state = .starting
            _capabilities = nil
        }
        readStderr(stderr, generation: generation)
        readStdout(stdout, generation: generation)
        initialize(generation)
    }

    /// Launches it again after it died, with every open document. The
    /// registry decides whether it should (once, not in a loop).
    func restart() throws {
        let state = state
        guard state == .dead || state == .idle else { return }
        lock.withLock { _restartCount += 1 }
        try start()
    }

    /// shutdown, exit, and the process gone — killed if it hasn't left in
    /// 2 s. Blocks for up to ~4 s; call it off the main thread, or at quit.
    func stop() {
        let (state, process, exited) = lock.withLock { (_state, self.process, self.exited) }
        guard state == .starting || state == .running, let process else { return }
        let answered = DispatchSemaphore(value: 0)
        let shutdown = state == .running ? register({ _ in answered.signal() }) : nil
        // From here its exit is expected, not a crash to restart from.
        lock.withLock { _state = .stopped }
        if let shutdown {
            send(["jsonrpc": "2.0", "id": .int(shutdown), "method": "shutdown"])
            if answered.wait(timeout: .now() + 2) == .timedOut { _ = take(shutdown) }
            send(["jsonrpc": "2.0", "method": "exit"])
        }
        // What writes are queued go first; closing stdin is the last word.
        writeQueue.sync { try? lock.withLock { input }?.close() }
        if exited.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        failAll(LanguageServerError.notRunning)
    }

    private func initialize(_ generation: Int) {
        let rootURI = LSP.uri(for: root)
        let params: JSONValue = [
            "processId": .int(Int(getpid())),
            "clientInfo": ["name": "Overterm"],
            "locale": "en",
            "rootUri": .string(rootURI),
            "rootPath": .string(root.path),
            "workspaceFolders": [["uri": .string(rootURI), "name": .string(root.lastPathComponent)]],
            "capabilities": Self.clientCapabilities,
        ]
        guard let id = register({ [weak self] result in self?.initialized(generation, result) }) else { return }
        send(["jsonrpc": "2.0", "id": .int(id), "method": "initialize", "params": params])
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.initializeTimeout) { [weak self] in
            guard let self, let handler = take(id) else { return }
            handler(.failure(LanguageServerError.timedOut("initialize")))
        }
    }

    /// What this client can take. Completion resolve isn't offered, so
    /// servers put documentation and additional edits in the list itself.
    static let clientCapabilities: JSONValue = [
        "general": ["positionEncodings": ["utf-16"]],
        "workspace": [
            "configuration": true,
            "workspaceFolders": true,
            "applyEdit": false,
        ],
        "window": ["workDoneProgress": false],
        "textDocument": [
            "synchronization": ["didSave": true, "willSave": false, "willSaveWaitUntil": false, "dynamicRegistration": false],
            "completion": [
                "completionItem": [
                    "snippetSupport": true,
                    "documentationFormat": ["markdown", "plaintext"],
                    "insertReplaceSupport": false,
                    "deprecatedSupport": false,
                ],
                "contextSupport": true,
            ],
            "hover": ["contentFormat": ["markdown", "plaintext"]],
            "definition": ["linkSupport": true],
            "references": [:],
            "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
            "formatting": [:],
            "publishDiagnostics": ["relatedInformation": false, "versionSupport": false],
        ],
    ]

    private func initialized(_ generation: Int, _ result: Result<Data, Error>) {
        let capabilities: Capabilities
        switch result {
        case .success(let data):
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            capabilities = Capabilities(json: json?["capabilities"] as? [String: Any] ?? [:])
        case .failure(let error):
            // A server that can't initialize is no use; end it.
            let process = lock.withLock { self.generation == generation ? self.process : nil }
            process?.terminate()
            died(generation, status: -1, error: error)
            return
        }
        lock.lock()
        guard self.generation == generation, _state == .starting else {
            lock.unlock()
            return
        }
        _state = .running
        _capabilities = capabilities
        let waiters = readyWaiters
        let documents = self.documents
        readyWaiters = []
        lock.unlock()
        send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
        for (url, document) in documents {
            sendDidOpen(url, document, capabilities)
        }
        for waiter in waiters { waiter.resume(returning: capabilities) }
    }

    /// The process ended (or its stdout closed, or it couldn't initialize).
    private func died(_ generation: Int, status: Int32, error: Error? = nil) {
        let changed: Bool = lock.withLock {
            guard self.generation == generation, _state == .starting || _state == .running else { return false }
            _state = .dead
            return true
        }
        guard changed else { return }
        failAll(error ?? LanguageServerError.exited(status))
    }

    private func failAll(_ error: Error) {
        let (handlers, waiters) = lock.withLock {
            defer {
                pending = [:]
                readyWaiters = []
            }
            return (Array(pending.values), readyWaiters)
        }
        for handler in handlers { handler(.failure(error)) }
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    /// The capabilities once it's initialized; throws if it dies first.
    func waitUntilReady() async throws -> Capabilities {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            switch _state {
            case .running:
                let capabilities = _capabilities ?? Capabilities()
                lock.unlock()
                continuation.resume(returning: capabilities)
            case .starting:
                readyWaiters.append(continuation)
                lock.unlock()
            case .idle, .dead, .stopped:
                lock.unlock()
                continuation.resume(throwing: LanguageServerError.notRunning)
            }
        }
    }

    // MARK: - Documents

    func didOpen(_ url: URL, languageID: String, version: Int, text: String) {
        let document = OpenDocument(languageID: languageID, version: version, text: text)
        guard let capabilities = track(url, document) else { return }
        sendDidOpen(url, document, capabilities)
    }

    /// The whole new text — also to an incremental server, as one change
    /// without a range, which the protocol allows.
    func didChange(_ url: URL, version: Int, text: String) {
        let opened: (LSP.Capabilities?, Bool) = lock.withLock {
            guard var document = documents[url] else { return (nil, false) }
            document.version = version
            document.text = text
            documents[url] = document
            return (_state == .running ? _capabilities : nil, true)
        }
        guard opened.1, let capabilities = opened.0, capabilities.textDocumentSync != 0 else { return }
        notify(
            "textDocument/didChange",
            [
                "textDocument": ["uri": .string(LSP.uri(for: url)), "version": .int(version)],
                "contentChanges": [["text": .string(text)]],
            ])
    }

    func didSave(_ url: URL, text: String) {
        let capabilities: Capabilities? = lock.withLock {
            documents[url]?.text = text
            return documents[url] != nil && _state == .running ? _capabilities : nil
        }
        guard let capabilities, capabilities.save else { return }
        var params: [String: JSONValue] = ["textDocument": ["uri": .string(LSP.uri(for: url))]]
        if capabilities.saveIncludesText { params["text"] = .string(text) }
        notify("textDocument/didSave", .object(params))
    }

    func didClose(_ url: URL) {
        let capabilities: Capabilities? = lock.withLock {
            guard documents.removeValue(forKey: url) != nil, _state == .running else { return nil }
            return _capabilities
        }
        guard let capabilities, capabilities.openClose else { return }
        notify("textDocument/didClose", ["textDocument": ["uri": .string(LSP.uri(for: url))]])
    }

    /// Records the document; the capabilities if it should be sent now
    /// (nil while starting — it's sent once initialized).
    private func track(_ url: URL, _ document: OpenDocument) -> Capabilities? {
        lock.withLock {
            documents[url] = document
            return _state == .running ? _capabilities : nil
        }
    }

    private func sendDidOpen(_ url: URL, _ document: OpenDocument, _ capabilities: Capabilities) {
        guard capabilities.openClose else { return }
        notify(
            "textDocument/didOpen",
            [
                "textDocument": [
                    "uri": .string(LSP.uri(for: url)), "languageId": .string(document.languageID), "version": .int(document.version),
                    "text": .string(document.text),
                ]
            ])
    }

    // MARK: - Features

    /// Completions at `position`; `trigger` is the character just typed if
    /// it's one of the server's trigger characters.
    func completion(_ url: URL, at position: LSP.Position, trigger: String? = nil) async throws -> LSP.CompletionList {
        guard try await waitUntilReady().completion else { return LSP.CompletionList(items: [], isIncomplete: false) }
        let context: JSONValue = trigger.map { ["triggerKind": 2, "triggerCharacter": .string($0)] } ?? ["triggerKind": 1]
        var params = Self.positionParams(url, position)
        params["context"] = context
        return try await request("textDocument/completion", .object(params), as: LSP.CompletionList.self)
    }

    func completion(_ url: URL, at position: LSP.Position) async throws -> [LSP.CompletionItem] {
        try await completion(url, at: position, trigger: nil).items
    }

    func hover(_ url: URL, at position: LSP.Position) async throws -> LSP.Hover? {
        guard try await waitUntilReady().hover else { return nil }
        let hover = try await request("textDocument/hover", .object(Self.positionParams(url, position)), as: LSP.Hover?.self)
        guard let hover, !hover.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return hover
    }

    func definition(_ url: URL, at position: LSP.Position) async throws -> [LSP.Location] {
        guard try await waitUntilReady().definition else { return [] }
        return try await request("textDocument/definition", .object(Self.positionParams(url, position)), as: LSP.Locations.self).items
    }

    func references(_ url: URL, at position: LSP.Position, includeDeclaration: Bool = true) async throws -> [LSP.Location] {
        guard try await waitUntilReady().references else { return [] }
        var params = Self.positionParams(url, position)
        params["context"] = ["includeDeclaration": .bool(includeDeclaration)]
        return try await request("textDocument/references", .object(params), as: LSP.Locations.self).items
    }

    func documentSymbols(_ url: URL) async throws -> [LSP.Symbol] {
        guard try await waitUntilReady().documentSymbol else { return [] }
        return try await request("textDocument/documentSymbol", ["textDocument": ["uri": .string(LSP.uri(for: url))]], as: LSP.Symbols.self)
            .items
    }

    /// The edits that format the document; apply with `LSP.apply(_:to:)`.
    func formatting(_ url: URL, tabSize: Int, insertSpaces: Bool) async throws -> [LSP.TextEdit] {
        guard try await waitUntilReady().formatting else { return [] }
        let params: JSONValue = [
            "textDocument": ["uri": .string(LSP.uri(for: url))],
            "options": ["tabSize": .int(tabSize), "insertSpaces": .bool(insertSpaces)],
        ]
        return try await request("textDocument/formatting", params, as: [LSP.Lenient<LSP.TextEdit>]?.self)?.compactMap(\.value) ?? []
    }

    private static func positionParams(_ url: URL, _ position: LSP.Position) -> [String: JSONValue] {
        [
            "textDocument": ["uri": .string(LSP.uri(for: url))],
            "position": ["line": .int(position.line), "character": .int(position.character)],
        ]
    }

    // MARK: - Requests

    /// Any request, its result decoded as `T`. Waits for initialization.
    /// Times out after `timeout`; cancelling the task cancels it at the
    /// server (`$/cancelRequest`) and throws CancellationError.
    func request<T: Decodable>(_ method: String, _ params: JSONValue, as type: T.Type, timeout: TimeInterval = requestTimeout) async throws -> T {
        _ = try await waitUntilReady()
        let data = try await rawRequest(method, params, timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func rawRequest(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> Data {
        let id = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard register(id: id, { continuation.resume(with: $0) }) else {
                    continuation.resume(throwing: LanguageServerError.notRunning)
                    return
                }
                // Cancelled before the handler was in place: onCancel found nothing.
                if Task.isCancelled {
                    cancel(id, CancellationError())
                    return
                }
                send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.cancel(id, LanguageServerError.timedOut(method))
                }
            }
        } onCancel: {
            cancel(id, CancellationError())
        }
    }

    /// Fails a pending request with `error` and tells the server to drop it.
    private func cancel(_ id: Int, _ error: Error) {
        guard let handler = take(id) else { return }
        handler(.failure(error))
        notify("$/cancelRequest", ["id": .int(id)])
    }

    /// A new id with its handler; nil once the server is gone.
    private func register(_ handler: @escaping @Sendable (Result<Data, Error>) -> Void) -> Int? {
        lock.withLock {
            guard _state == .starting || _state == .running else { return nil }
            defer { nextID += 1 }
            pending[nextID] = handler
            return nextID
        }
    }

    private func register(id: Int, _ handler: @escaping @Sendable (Result<Data, Error>) -> Void) -> Bool {
        lock.withLock {
            guard _state == .running else { return false }
            pending[id] = handler
            return true
        }
    }

    private func take(_ id: Int) -> (@Sendable (Result<Data, Error>) -> Void)? {
        lock.withLock { pending.removeValue(forKey: id) }
    }

    private func notify(_ method: String, _ params: JSONValue) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    private func send(_ message: JSONValue) {
        guard let body = try? message.encoded(), let input = lock.withLock({ input }) else { return }
        let data = JSONRPC.frame(body)
        writeQueue.async {
            // Raw write(2): FileHandle.write raises an Objective-C exception
            // on a closed pipe. EPIPE just means it died; the reader sees that.
            let fd = input.fileDescriptor
            data.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var left = buffer.count
                while left > 0 {
                    let written = Darwin.write(fd, pointer, left)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    pointer += written
                    left -= written
                }
            }
        }
    }

    // MARK: - Reading

    /// stdout on a GCD thread of its own for the life of the process: a
    /// blocking read loop, frames decoded as they come.
    private func readStdout(_ pipe: Pipe, generation: Int) {
        DispatchQueue(label: "LanguageServer.read.\(name)").async { [self] in
            // The pipe is captured so its descriptor stays open while read.
            let fd = pipe.fileHandleForReading.fileDescriptor
            var decoder = JSONRPC.FrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                for message in decoder.feed(Data(buffer[0..<count])) {
                    handle(message, generation: generation)
                }
            }
            // stdout closed: whatever the process does now, it can't answer.
            let process = lock.withLock { self.generation == generation ? self.process : nil }
            if process?.isRunning == true, state != .stopped { process?.terminate() }
            died(generation, status: process?.isRunning == false ? process?.terminationStatus ?? -1 : -1)
        }
    }

    private func readStderr(_ pipe: Pipe, generation: Int) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(String(decoding: chunk, as: UTF8.self))
        }
    }

    private func appendStderr(_ text: String) {
        lock.withLock {
            var lines = (partialStderr + text).components(separatedBy: "\n")
            partialStderr = lines.removeLast()
            stderrTail.append(contentsOf: lines)
            if stderrTail.count > Self.stderrLineLimit { stderrTail.removeFirst(stderrTail.count - Self.stderrLineLimit) }
        }
    }

    private func handle(_ body: Data, generation: Int) {
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
        let method = message["method"] as? String
        let id = message["id"]
        switch (method, id) {
        case (nil, let id?):
            // A response to one of ours.
            guard let id = (id as? NSNumber)?.intValue, let handler = take(id) else { return }
            if let error = message["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue ?? 0
                handler(.failure(LanguageServerError.response(code: code, message: error["message"] as? String ?? "")))
            } else {
                let result = message["result"] ?? NSNull()
                let data = (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])) ?? Data("null".utf8)
                handler(.success(data))
            }
        case (let method?, let id?):
            answer(method, id: JSONValue(foundation: id), params: message["params"])
        case (let method?, nil):
            notification(method, params: message["params"])
        default:
            break
        }
    }

    /// What the server asks of the client. Nothing here edits or
    /// configures: settings are left to the server's defaults.
    private func answer(_ method: String, id: JSONValue, params: Any?) {
        var reply: [String: JSONValue] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "workspace/configuration":
            let items = (params as? [String: Any])?["items"] as? [Any] ?? []
            reply["result"] = .array(Array(repeating: .null, count: items.count))
        case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability",
            "window/showMessageRequest", "window/showDocument":
            reply["result"] = .null
        case "workspace/applyEdit":
            reply["result"] = ["applied": false]
        case "workspace/workspaceFolders":
            reply["result"] = [["uri": .string(LSP.uri(for: root)), "name": .string(root.lastPathComponent)]]
        default:
            reply["error"] = ["code": -32601, "message": .string("\(method) not supported")]
        }
        send(.object(reply))
    }

    private func notification(_ method: String, params: Any?) {
        guard method == "textDocument/publishDiagnostics", let params,
            let data = try? JSONSerialization.data(withJSONObject: params),
            let published = try? JSONDecoder().decode(LSP.PublishDiagnostics.self, from: data)
        else { return }
        // window/logMessage, $/progress, telemetry: nothing to do.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.onDiagnostics?(published.url, published.diagnostics)
            }
        }
    }
}

extension LSP {
    typealias Capabilities = LanguageServer.Capabilities
}
