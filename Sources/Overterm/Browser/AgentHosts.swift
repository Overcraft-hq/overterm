import Foundation

/// Where an agent's browser may go without asking (P11, D-4 (b)). The
/// browser column shares one store of cookies with the person using it, so
/// an agent that could open anything could act wherever they are signed in
/// — an admin panel, told to by a line it read on a page. Agents keep to
/// `browser.agentHosts` (the machine's own, by default: what is being
/// built); any other host is asked once a run, naming the tab and agent
/// (`AgentHostGate`). Pages on no host — a file, about:, data: — are never
/// asked. The person's own use of the column is never checked.
package enum AgentHosts {
    /// `browser.agentHosts`' default: this Mac's own addresses.
    package static let defaults = ["localhost", "127.0.0.1", "[::1]", "0.0.0.0", "*.localhost"]

    /// How long the guard stays on the page after an agent's call (a
    /// handler that awaits before it navigates). Past that, a page sending
    /// itself elsewhere isn't stopped — the next read asks.
    package static let guardTail: TimeInterval = 2

    /// The host a page at `url` is on, lowercased, as patterns match it;
    /// nil for a page on no host (file:, about:, data:, blob:,
    /// javascript:) — never asked.
    package static func host(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return normalized(url.host ?? "")
    }

    /// Whether `host` is on `list`: a name or address as written, `*.name`
    /// any name under it (not the name itself), `*` every host. A pattern
    /// pasted as a URL or with a port is read for its host alone.
    package static func allows(_ host: String, in list: [String]) -> Bool {
        list.contains { matches(host, $0) }
    }

    package static func matches(_ host: String, _ pattern: String) -> Bool {
        let pattern = normalized(pattern)
        guard !pattern.isEmpty, !host.isEmpty else { return false }
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst())
            return host.hasSuffix(suffix) && host.count > suffix.count
        }
        return host == pattern
    }

    /// A host or a pattern as compared: lowercased, its scheme, path,
    /// port, IPv6 brackets and trailing dot left out.
    package static func normalized(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if text.hasPrefix("[") {
            // [::1]:3000 — the address inside the brackets.
            if let close = text.firstIndex(of: "]") { text = String(text[text.index(after: text.startIndex)..<close]) }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            // A name or an IPv4 address with a port; a bare IPv6 address keeps its colons.
            text = String(text[..<colon])
        }
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// What the question shows of a URL: scheme, host, port and path —
    /// never its query, fragment or credentials, where tokens travel.
    package static func shown(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? url.host ?? ""
    }

    /// The question for `host` (pure): what the agent wants there, the page,
    /// and what allowing means — the person's cookies go with it.
    @MainActor package static func question(host: String, url: URL, doing: String) -> WriteConfirmation {
        WriteConfirmation(
            title: "Let the agent's browser use \(host)?",
            detail:
                "It wants to \(doing): \(shown(url))\n\n\(host) isn't one of the hosts agents' browsers use without asking (Settings ▸ Browser ▸ Agents). The browser shares your cookies: where you are signed in on \(host), the agent is too. Allowed, no agent's browser is asked about it again until Overterm quits.",
            button: "Allow \(host)", cancel: "Don't Allow")
    }

    /// What the agent reads when the person said no.
    package static func declined(_ host: String) -> String {
        "The person didn't allow \(host) for the agent's browser this session: it isn't one of the hosts in Settings ▸ Browser ▸ Agents (browser.agentHosts). Nothing was opened, read or done there."
    }

    /// What the agent reads when a page it acted on tried to send something
    /// to a host that was then allowed: nothing was sent, so it does it again.
    package static func repeatAfterAllowing(_ host: String, method: String) -> String {
        "The page tried to \(method) to \(host), which wasn't allowed yet: it was stopped before anything was sent. The person has allowed \(host) now — do the same again."
    }
}

/// A main-frame navigation an agent's call set off that its hosts didn't
/// allow, stopped before it was sent (`BrowserSession`'s policy).
package struct BlockedNavigation: Equatable, Sendable {
    package var url: URL
    /// GET is loaded again once allowed; anything else (a form's POST)
    /// only the agent can send again.
    package var method: String
    /// The page it was stopped in (`BrowserSession`), where it is followed.
    package var page: ObjectIdentifier?

    package init(url: URL, method: String, page: ObjectIdentifier? = nil) {
        self.url = url
        self.method = method
        self.page = page
    }
}

/// An agent's browser call refused for its host: a tool result the agent
/// reads, not a protocol error (MCP-U6).
package struct AgentHostRefused: LocalizedError {
    package var message: String
    package var errorDescription: String? { message }
}

/// This run's answers about hosts off `browser.agentHosts`, and the one
/// way they are asked: through `MCPApprovals`, the sheet on the asking
/// pane's window or the Inbox's card, with its tab and agent. An answer
/// holds until Overterm quits — allowed, not asked again; declined, refused
/// without asking (the agent would otherwise ask at every step).
@MainActor
package final class AgentHostGate {
    package static let shared = AgentHostGate()

    /// Each host's answer this run, for every agent.
    package private(set) var answers: [String: Bool] = [:]
    /// Calls waiting on a question already open for their host: one question, one answer.
    private var waiting: [String: [CheckedContinuation<Bool, Error>]] = [:]
    /// How a question is asked: `MCPApprovals` (nil: declined), a test's stand-in.
    package var ask: @MainActor (WriteConfirmation) async throws -> String? = { try await MCPApprovals.shared.ask($0) }

    package init() {}

    /// Forgets this run's answers (a scenario's start).
    package func reset() { answers = [:] }

    /// Whether a host may be used now without asking: on `list`, or allowed this run.
    package func allows(_ url: URL, list: [String]) -> Bool {
        guard let host = AgentHosts.host(of: url) else { return true }
        return AgentHosts.allows(host, in: list) || answers[host] == true
    }

    /// Asks about `url`'s host when it must be; throws `AgentHostRefused`
    /// when the person says no (or said so earlier this run), and
    /// `BrowserMCP.ToolError` when nobody answered in time.
    package func check(_ url: URL, list: [String], doing: String) async throws {
        guard let host = AgentHosts.host(of: url), !AgentHosts.allows(host, in: list) else { return }
        if let answer = answers[host] {
            if answer { return }
            throw AgentHostRefused(message: AgentHosts.declined(host))
        }
        if waiting[host] != nil {
            let allowed = try await withCheckedThrowingContinuation { waiting[host, default: []].append($0) }
            if !allowed { throw AgentHostRefused(message: AgentHosts.declined(host)) }
            return
        }
        waiting[host] = []
        let allowed: Bool
        do {
            allowed = try await ask(AgentHosts.question(host: host, url: url, doing: doing)) != nil
        } catch {
            for other in waiting.removeValue(forKey: host) ?? [] { other.resume(throwing: error) }
            throw error
        }
        answers[host] = allowed
        for other in waiting.removeValue(forKey: host) ?? [] { other.resume(returning: allowed) }
        if !allowed { throw AgentHostRefused(message: AgentHosts.declined(host)) }
    }
}
