import Foundation

/// What agents called on Overterm's MCP server, a pane at a time (P09,
/// MCP-U3): when, which tool, its arguments with secrets taken out, how big
/// the answer was, and whether it was asked, allowed, declined or left
/// unanswered. In memory only — never written to disk — and gone when the
/// app quits; Tab Info shows a tab's panes' calls.
@MainActor
package final class MCPCallLog: ObservableObject {
    package static let shared = MCPCallLog()

    /// Calls kept a pane, newest first.
    package static let perPane = 50
    /// An argument's text at most, once masked.
    package nonisolated static let argumentLength = 160

    package enum Outcome: Equatable {
        case running
        /// Done; `error` when the tool answered with one.
        case done(error: Bool)
        /// Asked of the person, and waiting.
        case asking
        case declined
        /// Nobody answered in time (MCPApprovals.timeout).
        case timedOut

        package var words: String {
            switch self {
            case .running: "running"
            case .done(let error): error ? "failed" : "done"
            case .asking: "asked, waiting"
            case .declined: "declined"
            case .timedOut: "unanswered"
            }
        }
    }

    package struct Call: Identifiable, Equatable {
        package let id: UUID
        package let at: Date
        package let tool: String
        /// `key: value`, every value masked and cut (`masked`).
        package let arguments: String
        package var outcome: Outcome = .running
        /// The person was asked (MCPApprovals) and allowed it.
        package var allowed = false
        /// The answer's size in bytes, once it came.
        package var bytes: Int?
    }

    /// Each pane's calls, newest first, by its tag.
    @Published package private(set) var calls: [String: [Call]] = [:]

    /// The call running in this task: what an approval it asks marks.
    @TaskLocal package static var current: (pane: String, id: UUID)?

    package func begin(pane: String, tool: String, arguments: [String: Any]) -> UUID {
        let call = Call(id: UUID(), at: Date(), tool: tool, arguments: Self.masked(arguments))
        var list = calls[pane] ?? []
        list.insert(call, at: 0)
        if list.count > Self.perPane { list.removeLast(list.count - Self.perPane) }
        calls[pane] = list
        return call.id
    }

    /// Its answer: its size, and whether it was an error.
    package func end(pane: String, id: UUID, reply: [String: Any]?) {
        update(pane, id) { call in
            let result = reply?["result"] as? [String: Any]
            let failed = reply?["error"] != nil || result?["isError"] as? Bool == true
            call.bytes = reply.flatMap { try? JSONSerialization.data(withJSONObject: $0) }?.count
            // A decline or a timeout said already stays said.
            if call.outcome == .running || call.outcome == .asking { call.outcome = .done(error: failed) }
        }
    }

    /// The call running now asked the person (MCPApprovals).
    package func asked() {
        guard let (pane, id) = Self.current else { return }
        update(pane, id) { $0.outcome = .asking }
    }

    /// …and was answered.
    package func answered(_ outcome: MCPApprovals.Outcome) {
        guard let (pane, id) = Self.current else { return }
        update(pane, id) { call in
            switch outcome {
            case .allowed:
                call.allowed = true
                call.outcome = .running
            case .declined: call.outcome = .declined
            case .timedOut: call.outcome = .timedOut
            }
        }
    }

    /// The calls of `panes`, newest first.
    package func calls(of panes: [String]) -> [Call] {
        panes.flatMap { calls[$0] ?? [] }.sorted { $0.at > $1.at }
    }

    /// A closed pane's calls go with it.
    package func forget(pane: String) { calls[pane] = nil }

    private func update(_ pane: String, _ id: UUID, _ change: (inout Call) -> Void) {
        guard var list = calls[pane], let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        calls[pane] = list
    }

    /// The arguments as one line, by key: a secret-named key's value masked,
    /// every value through `Secrets`' credential and URL scrubbing, each cut
    /// to `argumentLength`. Pure.
    package nonisolated static func masked(_ arguments: [String: Any]) -> String {
        arguments.keys.sorted().map { key -> String in
            let value = arguments[key]
            var text: String
            switch value {
            case let string as String: text = string
            case let number as NSNumber: text = number.stringValue
            case let other? where JSONSerialization.isValidJSONObject(other):
                text = (try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "…"
            case .some: text = "…"
            case nil: text = ""
            }
            text = Secrets.isSecret(key) ? Secrets.mask(text) : Secrets.maskURLs(in: Secrets.scrubCredentials(text))
            text = text.replacingOccurrences(of: "\n", with: " ")
            if text.count > argumentLength { text = String(text.prefix(argumentLength)) + "…" }
            return "\(key): \(text)"
        }.joined(separator: ", ")
    }
}
