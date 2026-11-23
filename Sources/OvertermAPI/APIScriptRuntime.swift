import Foundation
import JavaScriptCore

/// One test's result: a `test()` in a tests block or script, or a line of
/// the `assert` block.
package struct APITestResult: Equatable, Hashable, Sendable, Identifiable {
    package var name: String
    package var passed: Bool
    package var error: String?
    package var milliseconds: Double = 0
    /// From the assert block rather than a `test()`.
    package var isAssertion = false
    package var id: String { name + (isAssertion ? "#assert" : "#test") }
}

/// A line a script logged.
package struct APILogLine: Equatable, Hashable, Sendable {
    package enum Level: String, Sendable { case log, warn, error }
    package var level: Level
    package var text: String
}

/// What one script phase did: variables it set, the request as it left
/// it, tests, logs, and the runner's instructions.
package struct APIScriptOutcome: Equatable, Sendable {
    /// Runtime variables set, as `{{name}}` reads them (text) …
    package var runtime: [String: String] = [:]
    /// … and as JavaScript values, JSON-encoded: the next script's
    /// `bru.getVar` gets the object or number back, as in Bruno.
    package var runtimeJSON: [String: String] = [:]
    package var deleted: [String] = []
    package var environment: [String: String] = [:]
    package var tests: [APITestResult] = []
    package var logs: [APILogLine] = []
    /// `bru.setNextRequest(name)`: the runner goes there next;
    /// `setNextRequest(null)` and `runner.stopExecution()` set `stop`.
    package var nextRequest: String?
    package var skip = false
    package var stop = false
    /// What `req` holds after a pre-request script that changed it.
    package var request: APIScriptRequest?
    /// `res.setBody(…)`, as JSON text.
    package var responseBody: String?
    /// The script threw, or ran past its time.
    package var failure: String?
}

/// The request as a script sees and changes it.
package struct APIScriptRequest: Equatable, Sendable, Codable {
    package var url: String
    package var method: String
    package var headers: [String: String]
    /// JSON text for a JSON body, the text for any other.
    package var body: String?
    package var timeout: Double?
    /// The script set the body to null: nothing is sent, rather than the
    /// body it replaced.
    package var bodyCleared = false
}

/// What the runtime hands a script about the world around it.
package struct APIScriptInput: Sendable {
    package var requestName = ""
    package var collectionName = ""
    package var environmentName: String?
    /// Every variable, merged: what `bru.getVar` falls back to.
    package var variables: [String: String] = [:]
    package var runtime: [String: String] = [:]
    /// The runtime variables as JSON-encoded values, where they are known.
    package var runtimeJSON: [String: String] = [:]
    package var environment: [String: String] = [:]
    package var requestVars: [String: String] = [:]
    package var folderVars: [String: String] = [:]
    package var collectionVars: [String: String] = [:]
    package var processEnv: [String: String] = [:]
    package var request = APIScriptRequest(url: "", method: "GET", headers: [:], body: nil)
    package var response: APIResponse?
}

/// Runs Bruno's scripts, tests and assertions in JavaScriptCore — off the
/// main thread, on a queue of its own, each run in a fresh context, with
/// a time limit so a loop that never ends doesn't hold the request.
package final class APIScriptRuntime: @unchecked Sendable {
    package static let shared = APIScriptRuntime()

    private let queue = DispatchQueue(label: "overterm.api-scripts", qos: .userInitiated)
    private let machine: JSVirtualMachine
    package var timeLimit: Double = 10

    package init() {
        // Made on the queue's first use would do as well; JSVirtualMachine
        // is fine to create anywhere, used only on `queue`.
        machine = JSVirtualMachine()
    }

    package enum Phase: Sendable {
        case preRequest(String)
        case postResponse(String)
        case tests(String)
        /// The assert block's lines.
        case assertions([BruPair])
        /// vars:post-response: name → expression.
        case capture([BruPair])
    }

    package func run(_ phase: Phase, input: APIScriptInput) async -> APIScriptOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: runNow(phase, input: input)) }
        }
    }

    private func runNow(_ phase: Phase, input: APIScriptInput) -> APIScriptOutcome {
        guard let context = JSContext(virtualMachine: machine) else { return APIScriptOutcome(failure: "JavaScript isn't available.") }
        Self.limit(context, seconds: timeLimit)
        var thrown: String?
        context.exceptionHandler = { _, exception in
            let message = exception?.objectForKeyedSubscript("message")?.toString()
            thrown = (message == nil || message == "undefined") ? exception?.toString() : message
        }
        context.setObject(Self.inputJSON(input), forKeyedSubscript: "__input" as NSString)
        let base64: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let fromBase64: @convention(block) (String) -> String = { Data(base64Encoded: $0).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        context.setObject(base64, forKeyedSubscript: "btoa" as NSString)
        context.setObject(fromBase64, forKeyedSubscript: "atob" as NSString)
        context.evaluateScript(APIScriptPrelude.source)
        if let thrown { return APIScriptOutcome(failure: "Overterm's script runtime failed to start: \(thrown)") }

        switch phase {
        case .preRequest(let script), .postResponse(let script), .tests(let script):
            // Wrapped in a function, so `return` and top-level `await`-free
            // code behave as in Bruno, which wraps scripts the same way.
            context.evaluateScript("(function(){\n\(script)\n})();")
        case .assertions(let pairs):
            for pair in pairs where pair.enabled {
                context.objectForKeyedSubscript("__assertion").call(withArguments: [pair.key, pair.value])
            }
        case .capture(let pairs):
            for pair in pairs where pair.enabled {
                context.objectForKeyedSubscript("__capture").call(withArguments: [pair.key, pair.value])
            }
        }
        let failure = thrown.map { Self.describe($0) }
        thrown = nil
        let json = context.objectForKeyedSubscript("__finish").call(withArguments: [])?.toString() ?? "{}"
        var outcome = Self.outcome(json)
        outcome.failure = failure ?? thrown
        return outcome
    }

    private static func describe(_ message: String) -> String {
        message.contains("JavaScript execution terminated") || message.contains("execution terminated")
            ? "The script ran longer than its time limit and was stopped." : message
    }

    // MARK: In and out

    private static func inputJSON(_ input: APIScriptInput) -> String {
        var object: [String: Any] = [
            "requestName": input.requestName, "collectionName": input.collectionName, "vars": input.variables,
            "runtime": input.runtime, "env": input.environment, "requestVars": input.requestVars, "folderVars": input.folderVars,
            "collectionVars": input.collectionVars, "processEnv": input.processEnv,
        ]
        if let name = input.environmentName { object["envName"] = name }
        var typed: [String: Any] = [:]
        for (name, json) in input.runtimeJSON {
            typed[name] = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? input.runtime[name]
        }
        for (name, text) in input.runtime where typed[name] == nil { typed[name] = text }
        object["runtimeTyped"] = typed
        var request: [String: Any] = ["url": input.request.url, "method": input.request.method, "headers": input.request.headers]
        if let body = input.request.body { request["body"] = jsonValue(body) ?? body }
        if let timeout = input.request.timeout { request["timeout"] = timeout }
        object["req"] = request
        if let response = input.response {
            var headers: [String: String] = [:]
            for header in response.headers { headers[header.name.lowercased()] = header.value }
            object["res"] = [
                "status": response.status, "statusText": response.statusText, "headers": headers,
                "body": response.json ?? response.text, "responseTime": Int(response.duration.rounded()),
                "url": response.url?.absoluteString ?? "",
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonValue(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
    }

    private static func outcome(_ json: String) -> APIScriptOutcome {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return APIScriptOutcome() }
        var outcome = APIScriptOutcome()
        outcome.runtime = stringMap(object["runtime"])
        for (name, value) in object["runtime"] as? [String: Any] ?? [:] {
            if let json = jsonText(value) { outcome.runtimeJSON[name] = json }
        }
        outcome.deleted = object["deleted"] as? [String] ?? []
        outcome.environment = stringMap(object["env"])
        outcome.tests = (object["tests"] as? [[String: Any]] ?? []).map {
            APITestResult(
                name: $0["name"] as? String ?? "", passed: $0["passed"] as? Bool ?? false, error: $0["error"] as? String,
                milliseconds: ($0["ms"] as? NSNumber)?.doubleValue ?? 0, isAssertion: $0["assertion"] as? Bool ?? false)
        }
        outcome.logs = (object["logs"] as? [[String: Any]] ?? []).map {
            APILogLine(level: APILogLine.Level(rawValue: $0["level"] as? String ?? "log") ?? .log, text: $0["text"] as? String ?? "")
        }
        outcome.nextRequest = object["next"] as? String
        outcome.skip = object["skip"] as? Bool ?? false
        outcome.stop = object["stop"] as? Bool ?? false
        if let request = object["req"] as? [String: Any] {
            var body: String?
            if let value = request["body"], !(value is NSNull) {
                if let text = value as? String {
                    body = text
                } else {
                    body = jsonText(value, pretty: true)
                }
            }
            outcome.request = APIScriptRequest(
                url: request["url"] as? String ?? "", method: (request["method"] as? String ?? "GET").uppercased(),
                headers: stringMap(request["headers"]), body: body, timeout: (request["timeout"] as? NSNumber)?.doubleValue,
                bodyCleared: object["bodyCleared"] as? Bool ?? false)
        }
        if let body = object["resBody"], !(body is NSNull) {
            outcome.responseBody =
                (body as? String)
                ?? jsonText(body)
        }
        return outcome
    }

    /// A value a script handed back, as JSON text — or nil. Checked before it
    /// is written: JSONSerialization raises an Objective-C exception, which
    /// `try?` doesn't catch, for anything it can't write — a bare number
    /// without .fragmentsAllowed took the app down (req.setBody(42)).
    package static func jsonText(_ value: Any, pretty: Bool = false) -> String? {
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: value, options: options)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Values as text, the way Bruno interpolates them: strings as they
    /// are, anything else as JSON.
    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let map = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in map {
            switch value {
            case let text as String: out[key] = text
            case is NSNull: out[key] = "null"
            case let number as NSNumber:
                out[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            default:
                out[key] = jsonText(value) ?? "\(value)"
            }
        }
        return out
    }

    // MARK: Time limit

    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    /// JSContextGroupSetExecutionTimeLimit: in JavaScriptCore since
    /// macOS 10.9, declared only in its private headers — looked up, and
    /// skipped if a future system drops it.
    private static let setLimit: SetLimit? = {
        guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
            let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit")
        else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    private static func limit(_ context: JSContext, seconds: Double) {
        guard let setLimit, let global = context.jsGlobalContextRef else { return }
        setLimit(JSContextGetGroup(global), seconds, nil, nil)
    }
}
