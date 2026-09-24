import Foundation

/// What a Claude Code session is doing, from the end of its transcript:
/// the session's title, the last prompt, and the agent's last words or
/// the tool it is running.
struct ClaudeActivity: Equatable {
    /// Claude Code's own title for the session (`ai-title` lines).
    var title: String?
    /// What you last asked.
    var lastPrompt: String?
    /// The last thing it said.
    var lastReply: String?
    /// The tool call it made last, when that came after its last words:
    /// what it is doing now ("Bash: make test").
    var currentTool: String?
    var branch: String?
    var updated: Date?

    /// How much of the end of the transcript is read — transcripts reach
    /// gigabytes; the latest state is always at the end.
    static let tailSize = 512 * 1024

    static func read(_ file: URL) -> ClaudeActivity? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailSize) ? size - UInt64(tailSize) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A)
        // Mid-line when the tail starts inside the file.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        var activity = parse(lines: lines.map { Data($0) })
        activity.updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return activity
    }

    /// Lines oldest first; the newest of each kind wins.
    static func parse(lines: [Data]) -> ClaudeActivity {
        var activity = ClaudeActivity()
        var sawReplyOrTool = false
        for data in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String
            else { continue }
            if activity.branch == nil, let branch = object["gitBranch"] as? String, !branch.isEmpty { activity.branch = branch }
            switch type {
            case "ai-title":
                if activity.title == nil { activity.title = object["aiTitle"] as? String }
            case "last-prompt":
                if activity.lastPrompt == nil { activity.lastPrompt = object["lastPrompt"] as? String }
            case "user":
                // A typed prompt (a string), not a tool result coming back.
                if activity.lastPrompt == nil, let message = object["message"] as? [String: Any], let text = message["content"] as? String {
                    activity.lastPrompt = text
                }
            case "assistant":
                guard activity.lastReply == nil, let message = object["message"] as? [String: Any],
                    let content = message["content"] as? [[String: Any]]
                else { continue }
                for part in content.reversed() {
                    switch part["type"] as? String {
                    case "text":
                        if let text = part["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            activity.lastReply = text
                        }
                    case "tool_use" where !sawReplyOrTool:
                        activity.currentTool = describe(tool: part)
                    default:
                        break
                    }
                    if activity.lastReply != nil { break }
                    if activity.currentTool != nil { sawReplyOrTool = true }
                }
                if activity.lastReply != nil { sawReplyOrTool = true }
            default:
                break
            }
            if activity.title != nil, activity.lastPrompt != nil, activity.lastReply != nil, activity.branch != nil { break }
        }
        return activity
    }

    /// "Bash: make test", "Edit: Sources/App.swift", or just the name.
    static func describe(tool part: [String: Any]) -> String {
        let name = part["name"] as? String ?? "tool"
        let input = part["input"] as? [String: Any] ?? [:]
        let detail =
            (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["pattern"] as? String)
            ?? (input["description"] as? String) ?? (input["url"] as? String)
        guard let detail else { return name }
        let oneLine = detail.split(separator: "\n").first.map(String.init) ?? detail
        return "\(name): \(oneLine)"
    }
}
