import Foundation

/// One request run from start to end, as Bruno runs it: pre-request
/// scripts, the request as they left it, then what the response sets
/// (`vars:post-response`), the post-response scripts, the assert block
/// and the tests.
///
/// Scripts follow bruno.json's `scripts.flow`: "sandwich" (Bruno's
/// default) runs pre-request scripts collection → folders → request, and
/// post-response scripts and tests the other way round; "sequential" runs
/// both from the outside in.
enum APIExecution {
    struct Setup: Sendable {
        var file: BruFile
        var requestName = ""
        var collectionName = ""
        var collectionRoot: URL?
        var collectionFile: BruFile?
        var folderFiles: [BruFile] = []
        var scriptFlow = "sandwich"
        var environmentName: String?
        /// The environment's variables, secrets filled in.
        var environment: [String: String] = [:]
        var runtime: [String: String] = [:]
        /// The same, as JSON-encoded JavaScript values (APIScriptOutcome).
        var runtimeJSON: [String: String] = [:]
        var processEnv: [String: String] = [:]
        var options = APIClient.Options()
    }

    struct Result: Equatable, Sendable {
        var plan: APIRequestPlan?
        var response: APIResponse?
        /// Why nothing came back: a bad URL, a refused connection, a
        /// script that threw before the request left.
        var error: String?
        var tests: [APITestResult] = []
        var logs: [APILogLine] = []
        /// The runtime variables after the run, for the next one.
        var runtime: [String: String] = [:]
        var runtimeJSON: [String: String] = [:]
        /// What `bru.setEnvVar` changed, for the session.
        var environment: [String: String] = [:]
        var nextRequest: String?
        var stop = false
        var skipped = false

        var passed: Int { tests.filter(\.passed).count }
        var failed: Int { tests.count - passed }
        /// Sent, answered below 400, and every test passed.
        var succeeded: Bool { error == nil && (response?.status ?? 0) < 400 && response != nil && failed == 0 }
    }

    static func run(_ setup: Setup, client: APIClient, scripts: APIScriptRuntime = .shared) async -> Result {
        var result = Result(runtime: setup.runtime, runtimeJSON: setup.runtimeJSON)
        var file = setup.file
        var environment = setup.environment
        var options = setup.options
        let outerFirst = [setup.collectionFile].compactMap { $0 } + setup.folderFiles
        let sandwich = setup.scriptFlow != "sequential"

        func layers() -> APIVariables {
            var vars = APIVariables()
            vars.collection = APIVariables.map(setup.collectionFile?.preRequestVars ?? [])
            vars.environment = environment
            vars.folders = setup.folderFiles.map { APIVariables.map($0.preRequestVars) }
            vars.request = APIVariables.map(file.preRequestVars)
            vars.runtime = result.runtime
            vars.processEnv = setup.processEnv
            return vars
        }

        func input(request: APIScriptRequest, response: APIResponse?) -> APIScriptInput {
            let vars = layers()
            var folderVars: [String: String] = [:]
            vars.folders.forEach { folderVars.merge($0) { $1 } }
            return APIScriptInput(
                requestName: setup.requestName, collectionName: setup.collectionName, environmentName: setup.environmentName,
                variables: vars.merged, runtime: result.runtime, runtimeJSON: result.runtimeJSON, environment: environment,
                requestVars: vars.request,
                folderVars: folderVars, collectionVars: vars.collection, processEnv: setup.processEnv, request: request,
                response: response)
        }

        /// Takes in what a phase did; false when it failed or stopped the run.
        func absorb(_ outcome: APIScriptOutcome, phase: String) -> Bool {
            result.runtime.merge(outcome.runtime) { $1 }
            result.runtimeJSON.merge(outcome.runtimeJSON) { $1 }
            for name in outcome.deleted {
                result.runtime[name] = nil
                result.runtimeJSON[name] = nil
            }
            environment.merge(outcome.environment) { $1 }
            result.environment.merge(outcome.environment) { $1 }
            result.tests += outcome.tests
            result.logs += outcome.logs
            if let next = outcome.nextRequest { result.nextRequest = next }
            result.stop = result.stop || outcome.stop
            result.skipped = result.skipped || outcome.skip
            if let failure = outcome.failure {
                result.logs.append(APILogLine(level: .error, text: "\(phase): \(failure)"))
                // A script that threw after the response — whatever tests it
                // recorded first — is a failure, as in Bruno: what it didn't
                // run can't count as passed.
                if result.response != nil { result.tests.append(APITestResult(name: phase, passed: false, error: failure)) }
                return false
            }
            return true
        }

        // Pre-request: the request as written (its variables not yet
        // filled in — Bruno fills them in after these scripts run).
        var removedHeaders: Set<String> = []
        let preScripts = (outerFirst + [file]).compactMap { $0.preRequestScript }.filter { !$0.isEmpty }
        if !preScripts.isEmpty {
            var request = rawRequest(file, outer: outerFirst)
            let original = request
            for script in preScripts {
                let outcome = await scripts.run(.preRequest(script), input: input(request: request, response: nil))
                if let changed = outcome.request { request = changed }
                guard absorb(outcome, phase: "Pre-request script") else {
                    result.error = outcome.failure
                    return result
                }
                if result.skipped { return result }
            }
            removedHeaders = apply(request, over: original, to: &file, options: &options)
        }

        // The request.
        var context = APIRequestPlan.Context()
        context.collectionRoot = setup.collectionRoot
        context.collectionFile = setup.collectionFile
        context.folderFiles = setup.folderFiles
        context.variables = layers()
        context.removedHeaders = removedHeaders
        let plan: APIRequestPlan
        do {
            plan = try APIRequestPlan.make(file, context: context)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        result.plan = plan
        var response: APIResponse
        do {
            response = try await client.send(plan, options: options)
        } catch is CancellationError {
            result.error = "Cancelled."
            return result
        } catch let error as URLError where error.code == .cancelled {
            result.error = "Cancelled."
            return result
        } catch {
            result.error = error.localizedDescription
            return result
        }
        result.response = response
        let sent = APIScriptRequest(
            url: plan.url.absoluteString, method: plan.method,
            headers: Dictionary(plan.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 }),
            body: plan.body.map { String(decoding: $0, as: UTF8.self) }, timeout: options.timeout * 1000)

        // After: captures, then scripts, the assert block, the tests.
        let captures = file.postResponseVars.filter(\.enabled)
        if !captures.isEmpty {
            _ = absorb(await scripts.run(.capture(captures), input: input(request: sent, response: response)), phase: "vars:post-response")
        }
        let postScripts = (sandwich ? [file] + outerFirst.reversed() : outerFirst + [file]).compactMap { $0.postResponseScript }.filter {
            !$0.isEmpty
        }
        for script in postScripts {
            let outcome = await scripts.run(.postResponse(script), input: input(request: sent, response: response))
            if let body = outcome.responseBody { response.body = Data(body.utf8) }
            _ = absorb(outcome, phase: "Post-response script")
        }
        result.response = response
        let assertions = file.assertions.filter(\.enabled)
        if !assertions.isEmpty {
            _ = absorb(await scripts.run(.assertions(assertions), input: input(request: sent, response: response)), phase: "Assertions")
        }
        let testScripts = (sandwich ? [file] + outerFirst.reversed() : outerFirst + [file]).compactMap { $0.tests }.filter { !$0.isEmpty }
        for script in testScripts {
            let outcome = await scripts.run(.tests(script), input: input(request: sent, response: response))
            _ = absorb(outcome, phase: "Tests")
        }
        return result
    }

    /// The request as pre-request scripts see it: the URL and headers as
    /// written — the collection's and folders' headers merged in — and
    /// the body's text.
    static func rawRequest(_ file: BruFile, outer: [BruFile]) -> APIScriptRequest {
        var headers: [String: String] = [:]
        for pairs in outer.map(\.headers) + [file.headers] {
            for pair in pairs where pair.enabled {
                if let existing = headers.keys.first(where: { $0.caseInsensitiveCompare(pair.key) == .orderedSame }) {
                    headers[existing] = nil
                }
                headers[pair.key] = pair.value
            }
        }
        // A form's fields as an object, as Bruno hands them to scripts.
        var body = file.body(file.bodyMode)
        let fields: [BruPair]? =
            file.bodyMode == .formUrlEncoded ? file.formFields : file.bodyMode == .multipartForm ? file.multipartFields : nil
        if let fields {
            var object: [String: String] = [:]
            for pair in fields where pair.enabled { object[pair.key] = pair.value }
            body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        }
        return APIScriptRequest(url: file.url, method: file.method, headers: headers, body: body, timeout: nil)
    }

    /// What a pre-request script changed, written into this run's copy of
    /// the request (never the file on disk). Returns the headers it deleted
    /// that the collection or a folder set, which the plan then leaves out.
    @discardableResult
    static func apply(
        _ request: APIScriptRequest, over original: APIScriptRequest, to file: inout BruFile, options: inout APIClient.Options
    ) -> Set<String> {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        if request.url != original.url { file.url = request.url }
        if request.method != original.method { file.method = request.method }
        var removed: Set<String> = []
        if request.headers != original.headers {
            var pairs = file.headers
            for name in original.headers.keys where !request.headers.keys.contains(where: { same($0, name) }) {
                removed.insert(name.lowercased())
                for index in pairs.indices where same(pairs[index].key, name) { pairs[index].enabled = false }
            }
            for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
                let before = original.headers.first { same($0.key, name) }?.value
                guard before != value else { continue }
                if let index = pairs.firstIndex(where: { same($0.key, name) }) {
                    pairs[index] = BruPair(key: name, value: value)
                } else {
                    pairs.append(BruPair(key: name, value: value))
                }
            }
            file.headers = pairs
        }
        if request.bodyCleared {
            file.bodyMode = .none
        } else if let body = request.body, !sameBody(body, original.body) {
            switch file.bodyMode {
            case .formUrlEncoded: file.formFields = formPairs(body)
            case .multipartForm: file.multipartFields = formPairs(body)
            case .none:
                file.bodyMode = .json
                file.setBody(.json, body)
            default: file.setBody(file.bodyMode, body)
            }
        }
        if let timeout = request.timeout, timeout > 0 { options.timeout = timeout / 1000 }
        return removed
    }

    /// The same body, JSON compared as values: read back from the script,
    /// an unchanged object comes re-indented.
    private static func sameBody(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        if a == b { return true }
        guard let x = try? JSONSerialization.jsonObject(with: Data(a.utf8), options: [.fragmentsAllowed]),
            let y = try? JSONSerialization.jsonObject(with: Data(b.utf8), options: [.fragmentsAllowed])
        else { return false }
        return (x as AnyObject).isEqual(y)
    }

    /// A form body a script set: an object's keys, or `a=1&b=2`.
    private static func formPairs(_ body: String) -> [BruPair] {
        if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            return object.keys.sorted().map { key in
                let value = object[key]
                let text =
                    (value as? String) ?? (value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) })
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                return BruPair(key: key, value: text)
            }
        }
        return CurlParser.formPairs(body)
    }
}
