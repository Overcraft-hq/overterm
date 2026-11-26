import Foundation

/// A branch's CI gone red while a tab has its checkout (GIT-G5, FLOW-N2):
/// the tab's mark, the Inbox's "CI failed: <check>" card, and what Ask
/// Agent to Fix reads. Pure.
package struct CIFailure: Equatable, Sendable {
    package var number: Int
    package var title: String
    package var branch: String
    /// The commit the failed run was of.
    package var head: String?
    package var failing: [Check]
    /// A push since: the new run's checks are still going.
    package var rerunning = false

    package init(number: Int, title: String, branch: String, head: String?, failing: [Check], rerunning: Bool = false) {
        self.number = number
        self.title = title
        self.branch = branch
        self.head = head
        self.failing = failing
        self.rerunning = rerunning
    }

    /// "CI failed: Lint", "CI failed: Lint and 2 more".
    package var note: String {
        let names = failing.map(\.name)
        let said = names.count <= 1 ? (names.first ?? "a check") : "\(names[0]) and \(names.count - 1) more"
        return "CI failed: \(said)" + (rerunning ? " — running again" : "")
    }

    package enum Change: Equatable, Sendable {
        /// Nothing to say.
        case none
        /// Newly red, or red for other checks: mark and say.
        case failed(CIFailure)
        /// Still red after a push, the new run going: the card says so.
        case rerunning(CIFailure)
        /// Green again, or the pull request is gone: the mark and card go.
        case recovered
    }

    /// What one poll says against the last, for `branch`'s pull request:
    /// a failure only on the way into red, when the failing set grows or
    /// a new run fails again — never the same red every poll; recovered
    /// only once nothing fails and nothing runs (a new run pending keeps
    /// the card, said as running again).
    package static func change(previous: PullRequestSummary?, now: PullRequestSummary?, standing: CIFailure?) -> Change {
        guard let now, now.state == .open || now.state == .draft else { return standing == nil ? .none : .recovered }
        let failing = now.checks.failing
        if !failing.isEmpty {
            let failure = CIFailure(number: now.number, title: now.title, branch: now.branch, head: now.headOid, failing: failing)
            // News: a pull request first seen red, a check gone red, or a
            // push whose new run failed too — never the same red again.
            guard let previous else { return .failed(failure) }
            let grew = !Set(failing.map(\.name)).isSubset(of: Set(previous.checks.failing.map(\.name)))
            let pushed = previous.headOid != now.headOid
            return grew || pushed || standing?.rerunning == true ? .failed(failure) : .none
        }
        guard var standing else { return .none }
        if now.checks.pending > 0 {
            if standing.rerunning { return .none }
            standing.rerunning = true
            return .rerunning(standing)
        }
        return .recovered
    }
}

/// A failed job's log, as the pane and Ask Agent to Fix show it: `gh run
/// view --log-failed`'s lines, the job's and step's columns folded into a
/// heading a step, the timestamps and escapes gone, every credential
/// masked, the tail only — bounded in lines and bytes. Pure.
package enum CILog {
    package static let maxLines = 200
    package static let maxBytes = 24_000

    package static func arguments(run: Int, job: Int?) -> [String] {
        ["run", "view", "\(run)"] + (job.map { ["--job", "\($0)"] } ?? []) + ["--log-failed"]
    }

    /// The workflow file a run is of: `.github/workflows/ci.yml`.
    package static func workflowPathArguments(run: Int) -> [String] {
        ["api", "repos/{owner}/{repo}/actions/runs/\(run)", "--jq", ".path"]
    }

    package static func tail(_ raw: String, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> String {
        var out: [String] = []
        var step: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            var text = String(columns.count == 3 ? columns[2] : line)
            if columns.count == 3 {
                let name = String(columns[1])
                if name != step {
                    step = name
                    out.append("── \(name) ──")
                }
            }
            text = withoutTimestamp(withoutEscapes(text))
            out.append(text)
        }
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        var lines = Array(out.suffix(maxLines))
        if out.count > maxLines { lines.insert("… \(out.count - maxLines) earlier lines", at: 0) }
        var text = Secrets.maskURLs(in: Secrets.scrubCredentials(lines.joined(separator: "\n")))
        if text.utf8.count > maxBytes {
            text = "…" + String(decoding: text.utf8.suffix(maxBytes), as: UTF8.self)
        }
        return text
    }

    /// `2026-11-27T10:00:00.1234567Z ` at a line's start, Actions' own.
    static func withoutTimestamp(_ text: String) -> String {
        guard text.count > 20, text.dropFirst(4).first == "-", text.dropFirst(10).first == "T", let space = text.firstIndex(of: " ") else { return text }
        let stamp = text[..<space]
        guard stamp.hasSuffix("Z"), stamp.count <= 34 else { return text }
        return String(text[text.index(after: space)...])
    }

    /// ANSI colour and cursor escapes: the log is shown as text.
    static func withoutEscapes(_ text: String) -> String {
        guard text.contains("\u{1b}") else { return text }
        var out = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1b}" else {
                out.append(character)
                continue
            }
            guard let next = iterator.next(), next == "[" else { continue }
            while let c = iterator.next(), !(c.isLetter) {}
        }
        return out
    }
}
