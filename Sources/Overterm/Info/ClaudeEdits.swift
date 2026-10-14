import Foundation

/// A file edit Claude Code made, read from a session transcript, and why it
/// made it (see `ClaudeEdits.Parser`).
struct ClaudeEdit: Equatable, Sendable {
    struct Reason: Equatable, Hashable, Sendable {
        enum Source: Equatable, Hashable, Sendable {
            /// What Claude said last before the edit, in the same turn.
            case said
            /// It said nothing: the prompt that started the turn.
            case asked
            /// Neither: the session's title.
            case title
        }

        let text: String
        let source: Source
    }

    /// One hunk of the edit's patch.
    struct Hunk: Equatable, Sendable {
        let oldStart: Int
        let oldLines: Int
        let newStart: Int
        let newLines: Int
    }

    /// Absolute, as the tool was given it.
    let path: String
    /// Edit, Write, MultiEdit or NotebookEdit.
    let tool: String
    /// When its result came back: the file changed then.
    let time: Date?
    /// The session it was made in; a subagent's edits belong to its session.
    let session: String
    /// The patch, when the transcript keeps it: a session's does, a
    /// subagent's doesn't.
    let hunks: [Hunk]
    /// A Write that created the file.
    let created: Bool
    var reason: Reason?
}

/// Claude Code's edits and their reasons, from its session transcripts
/// (~/.claude/projects/<cwd>/<session>.jsonl, and a session's subagents in
/// <session>/subagents/agent-*.jsonl). Not a public format; measured on
/// 2.1.1xx–2.1.28x transcripts.
///
/// An edit is an assistant `tool_use` of one of `tools`, paired with its
/// `tool_result` on a later user line; an errored or unanswered one changed
/// nothing. Its reason is the nearest assistant text before it since the
/// last prompt typed — Claude writes a message's parts on lines of their
/// own, and one text often covers several edits — else that prompt, else
/// the session's title. Thinking is never a reason.
enum ClaudeEdits {
    /// The tools that change a file, and the input naming it.
    static let tools = ["Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path"]

    /// A reason is kept up to this many characters: a pasted prompt can run
    /// to pages.
    static let maxReason = 2_000

    /// Reads a transcript a line at a time, oldest first, as Claude Code
    /// appends them — so a reader can feed it just what was appended since.
    struct Parser: Sendable {
        let session: String
        /// Edits whose result came back without an error, in order.
        private var edits: [ClaudeEdit] = []
        /// Edits waiting for their result, by tool_use id.
        private var pending: [String: ClaudeEdit] = [:]
        /// The turn so far, per conversation in the file: the session's own
        /// (""), or a subagent's (its agentId).
        private var turns: [String: Turn] = [:]
        private var customTitle: String?
        private var aiTitle: String?
        private var summary: String?

        private struct Turn {
            var said: String?
            var asked: String?
        }

        init(session: String) {
            self.session = session
        }

        /// The session's title: the one you gave it, else Claude's, else an
        /// old-style summary.
        var title: String? { customTitle ?? aiTitle ?? summary }

        mutating func consume(_ line: Data) {
            line.withUnsafeBytes { consume($0) }
        }

        /// Most lines — tool output, attachments, thinking — are skipped by a
        /// byte search, without parsing any JSON.
        mutating func consume(_ line: UnsafeRawBufferPointer) {
            guard wanted(line), let base = line.baseAddress else { return }
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String
            else { return }
            let conversation = (object["agentId"] as? String) ?? (object["isSidechain"] as? Bool == true ? "sidechain" : "")
            switch type {
            case "assistant": assistant(object, in: conversation)
            case "user": user(object, in: conversation)
            case "attachment": queued(object, in: conversation)
            case "custom-title": customTitle = ClaudeEdits.clean(object["customTitle"] as? String) ?? customTitle
            case "ai-title": aiTitle = ClaudeEdits.clean(object["aiTitle"] as? String) ?? aiTitle
            case "summary": summary = ClaudeEdits.clean(object["summary"] as? String) ?? summary
            default: break
            }
        }

        /// The edits so far, each with its reason — the title (or `fallback`,
        /// a subagent's session's) where it said and was asked nothing.
        /// Those with no reason at all are left out: nothing to show.
        func result(title fallback: String? = nil) -> [ClaudeEdit] {
            let title = (self.title ?? fallback).map { ClaudeEdit.Reason(text: $0, source: .title) }
            return edits.compactMap { edit in
                var edit = edit
                if edit.reason == nil { edit.reason = title }
                return edit.reason == nil ? nil : edit
            }
        }

        private func wanted(_ line: UnsafeRawBufferPointer) -> Bool {
            // A tool's result: only an edit's is wanted (the line may be megabytes of output).
            if let first = Needle.find(Needle.toolUseID, in: line) {
                guard !pending.isEmpty else { return false }
                var at: Int? = first
                while let found = at {
                    let from = found + Needle.toolUseID.count
                    if let id = Needle.string(at: from, in: line), pending[id] != nil { return true }
                    at = Needle.find(Needle.toolUseID, in: line, from: from)
                }
                return false
            }
            if Needle.find(Needle.toolUse, in: line) != nil, Needle.editNames.contains(where: { Needle.find($0, in: line) != nil }) {
                return true
            }
            return [Needle.text, Needle.user, Needle.queued, Needle.aiTitle, Needle.customTitle, Needle.summary].contains {
                Needle.find($0, in: line) != nil
            }
        }

        private mutating func assistant(_ object: [String: Any], in conversation: String) {
            guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
            // Claude Code's own stand-ins ("API Error: …") are not Claude's words.
            if object["isApiErrorMessage"] as? Bool == true || (message["model"] as? String)?.hasPrefix("<") == true { return }
            for part in content {
                switch part["type"] as? String {
                case "text":
                    if let text = ClaudeEdits.clean(part["text"] as? String) { turns[conversation, default: Turn()].said = text }
                case "tool_use":
                    guard let name = part["name"] as? String, let key = ClaudeEdits.tools[name], let id = part["id"] as? String,
                        let path = (part["input"] as? [String: Any])?[key] as? String, !path.isEmpty
                    else { continue }
                    let turn = turns[conversation] ?? Turn()
                    let reason =
                        turn.said.map { ClaudeEdit.Reason(text: $0, source: .said) } ?? turn.asked.map { ClaudeEdit.Reason(text: $0, source: .asked) }
                    pending[id] = ClaudeEdit(
                        path: path, tool: name, time: ClaudeEdits.date(object["timestamp"]), session: session, hunks: [], created: false,
                        reason: reason)
                default:
                    // Thinking (often empty) is never a reason.
                    continue
                }
            }
        }

        private mutating func user(_ object: [String: Any], in conversation: String) {
            guard let message = object["message"] as? [String: Any] else { return }
            if let parts = message["content"] as? [[String: Any]], parts.contains(where: { $0["type"] as? String == "tool_result" }) {
                for part in parts where part["type"] as? String == "tool_result" {
                    guard let id = part["tool_use_id"] as? String, let edit = pending.removeValue(forKey: id) else { continue }
                    let failed =
                        part["is_error"] as? Bool == true || (part["content"] as? String)?.hasPrefix("<tool_use_error>") == true
                        || object["toolUseResult"] is String
                    if failed { continue }
                    let result = object["toolUseResult"] as? [String: Any]
                    edits.append(
                        ClaudeEdit(
                            path: edit.path, tool: edit.tool, time: ClaudeEdits.date(object["timestamp"]) ?? edit.time, session: session,
                            hunks: ClaudeEdits.hunks(result?["structuredPatch"]), created: result?["type"] as? String == "create",
                            reason: edit.reason))
                }
                return
            }
            switch ClaudeEdits.prompt(object) {
            case .typed(let text): turns[conversation] = Turn(said: nil, asked: text)
            case .turn: turns[conversation] = Turn()
            case .none: break
            }
        }

        /// A prompt typed while Claude was working, handed to it with the
        /// next tool result.
        private mutating func queued(_ object: [String: Any], in conversation: String) {
            guard let attachment = object["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
                attachment["commandMode"] as? String == "prompt", attachment["isMeta"] as? Bool != true,
                let text = ClaudeEdits.clean(attachment["prompt"] as? String)
            else { return }
            turns[conversation] = Turn(said: nil, asked: text)
        }
    }

    /// Edits from `lines` of one transcript, oldest first.
    static func parse(lines: [Data], session: String = "") -> [ClaudeEdit] {
        var parser = Parser(session: session)
        for line in lines { parser.consume(line) }
        return parser.result()
    }

    // MARK: Prompts

    enum Prompt: Equatable {
        /// Typed: a new turn, with what was asked.
        case typed(String)
        /// A new turn nobody typed: a slash command, a background task's notice.
        case turn
        /// Not a turn of its own: a reminder, a caveat, a command's output, an
        /// interruption, a compaction's summary.
        case none
    }

    /// Slash commands and a background task's notice start a turn.
    private static let turnStarters = ["<command-name>", "<command-message>", "<task-notification>"]
    /// What Claude Code writes as the user without anyone typing it to Claude.
    private static let wrappers = [
        "<local-command-", "<bash-", "<system-reminder>", "<user-prompt-submit-hook>", "<user-memory-input>", "[Request interrupted", "Caveat:",
    ]

    /// What a user line (not a tool result) is.
    static func prompt(_ object: [String: Any]) -> Prompt {
        if object["isCompactSummary"] as? Bool == true || object["isVisibleInTranscriptOnly"] as? Bool == true { return .none }
        guard let message = object["message"] as? [String: Any] else { return .none }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return .none
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (object["origin"] as? [String: Any])?["kind"] as? String {
        case "task-notification":
            return .turn
        case "coordinator", "peer":
            // Another agent's message to this one (a subagent's coordinator):
            // its prompt, though written as meta.
            return clean(trimmed).map(Prompt.typed) ?? .turn
        default:
            break
        }
        if turnStarters.contains(where: trimmed.hasPrefix) { return .turn }
        if object["isMeta"] as? Bool == true || wrappers.contains(where: trimmed.hasPrefix) { return .none }
        return clean(trimmed).map(Prompt.typed) ?? .none
    }

    // MARK: By file

    /// The edits of files under `root`, by path relative to it, newest
    /// first: one per reason (its newest), at most `limit` per file. Edits
    /// from before `since` are about older work; those with no reason have
    /// nothing to show. Symlinks are resolved on both sides: /var is
    /// /private/var, whichever spelling the checkout and the transcript use.
    static func byFile(_ edits: [ClaudeEdit], root: URL, since: Date? = nil, limit: Int = 3) -> [String: [ClaudeEdit]] {
        let base = canonical(root.path)
        let prefix = base == "/" ? "/" : base + "/"
        var directories: [String: String] = [:]
        var byPath: [String: [(order: Int, edit: ClaudeEdit)]] = [:]
        for (order, edit) in edits.enumerated() {
            guard edit.reason != nil else { continue }
            if let since, let time = edit.time, time < since { continue }
            // The file itself may be a symlink (git lists the link): only its folder is resolved.
            let folder = (edit.path as NSString).deletingLastPathComponent
            let resolved = directories[folder] ?? canonical(folder)
            directories[folder] = resolved
            let path = (resolved as NSString).appendingPathComponent((edit.path as NSString).lastPathComponent)
            guard path.hasPrefix(prefix) else { continue }
            byPath[String(path.dropFirst(prefix.count)), default: []].append((order, edit))
        }
        return byPath.mapValues { list in
            var seen: Set<String> = []
            return Array(
                list.sorted { ($0.edit.time ?? .distantPast, $0.order) > ($1.edit.time ?? .distantPast, $1.order) }
                    .map(\.edit)
                    .filter { seen.insert($0.reason?.text ?? "").inserted }
                    .prefix(limit))
        }
    }

    /// `path` with its symlinks resolved (/var/… → /private/var/…), also
    /// when it no longer exists: its deepest existing folder is resolved and
    /// the rest kept as it is.
    static func canonical(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var rest: [String] = []
        while existing.count > 1 {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + rest.reversed()).joined(separator: "/")
            }
            rest.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return path
    }

    /// Both spellings of a directory when a symlink leads to it (/var and
    /// /private/var): Claude Code names its folder after the resolved one,
    /// a shell may report the other.
    static func spellings(_ directory: String) -> [String] {
        let resolved = canonical(directory)
        var all = [directory, resolved]
        if resolved.hasPrefix("/private/") {
            let short = String(resolved.dropFirst("/private".count))
            if canonical(short) == resolved { all.append(short) }
        }
        var seen: Set<String> = []
        return all.filter { seen.insert($0).inserted }
    }

    // MARK: Showing

    /// "5 min ago": compact, and the same in every locale — the pane is in English.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86400)) d ago"
        }
    }

    // MARK: Pieces

    /// Trimmed and capped; nil when empty.
    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > maxReason ? String(trimmed.prefix(maxReason)) + "…" : trimmed
    }

    private static func hunks(_ patch: Any?) -> [ClaudeEdit.Hunk] {
        (patch as? [[String: Any]] ?? []).compactMap { hunk in
            guard let oldStart = hunk["oldStart"] as? Int, let oldLines = hunk["oldLines"] as? Int, let newStart = hunk["newStart"] as? Int,
                let newLines = hunk["newLines"] as? Int
            else { return nil }
            return ClaudeEdit.Hunk(oldStart: oldStart, oldLines: oldLines, newStart: newStart, newLines: newLines)
        }
    }

    private static func date(_ stamp: Any?) -> Date? {
        guard let stamp = stamp as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)) ?? (try? Date.ISO8601FormatStyle().parse(stamp))
    }

    /// Byte patterns: Claude Code writes compact JSON, and a quote inside a
    /// string is escaped, so `"type":"text"` only ever matches structure.
    private enum Needle {
        static let toolUseID = Array(#""tool_use_id":""#.utf8)
        static let toolUse = Array(#""type":"tool_use""#.utf8)
        static let editNames = ClaudeEdits.tools.keys.map { Array(#""name":"\#($0)""#.utf8) }
        static let text = Array(#""type":"text""#.utf8)
        static let user = Array(#""type":"user""#.utf8)
        static let queued = Array(#""queued_command""#.utf8)
        static let aiTitle = Array(#""type":"ai-title""#.utf8)
        static let customTitle = Array(#""type":"custom-title""#.utf8)
        static let summary = Array(#""type":"summary""#.utf8)

        static func find(_ needle: [UInt8], in line: UnsafeRawBufferPointer, from: Int = 0) -> Int? {
            guard let base = line.baseAddress, from <= line.count, line.count - from >= needle.count else { return nil }
            return needle.withUnsafeBytes { n in
                memmem(base + from, line.count - from, n.baseAddress, needle.count).map { UnsafeRawPointer($0) - base }
            }
        }

        /// The characters from `from` up to the next quote.
        static func string(at from: Int, in line: UnsafeRawBufferPointer) -> String? {
            var to = from
            while to < line.count, line[to] != UInt8(ascii: "\"") { to += 1 }
            guard to < line.count else { return nil }
            return String(decoding: UnsafeRawBufferPointer(rebasing: line[from..<to]), as: UTF8.self)
        }
    }
}

/// Reads Claude Code's transcripts for edits, incrementally: a transcript
/// only grows, so after the first read only what was appended is parsed.
/// Blocking — call it off the main thread.
final class ClaudeEditsReader: @unchecked Sendable {
    private struct Progress {
        var offset: UInt64 = 0
        var parser: ClaudeEdits.Parser
    }

    private let lock = NSLock()
    /// The transcripts read lately: a week of sessions would otherwise all
    /// stay here, each with everything parsed from it.
    private var progress = RecentlyUsed<URL, Progress>(capacity: 120)
    var trackedTranscripts: Int { lock.withLock { progress.count } }
    /// Where the transcripts are; asked at every read (a scenario points it
    /// at scratch after launch).
    private let projects: @Sendable () -> URL

    init(projects: @escaping @Sendable () -> URL = { ClaudeUsageReader.projectsDirectory }) {
        self.projects = projects
    }

    /// Bytes read per step: memory stays flat however big the transcript.
    static let chunkSize = 8 << 20

    /// Edits in the transcripts of sessions started in `directories` or
    /// below them — `exactly`: in those alone — and their subagents',
    /// written since `since`; the newest `limit` sessions.
    func edits(in directories: [String], exactly: [String] = [], since: Date, limit: Int = 60) -> [ClaudeEdit] {
        lock.lock()
        defer { lock.unlock() }
        let projects = projects()
        let spelled = { (directories: [String]) in directories.flatMap(ClaudeEdits.spellings).map(ClaudeUsageReader.projectFolder(for:)) }
        var seen: Set<URL> = []
        let transcripts =
            (ClaudeSessions.transcripts(in: spelled(directories), projects: projects).prefix { $0.updated >= since }.prefix(limit)
            + ClaudeSessions.transcripts(in: spelled(exactly), below: false, projects: projects).prefix { $0.updated >= since }.prefix(limit))
            .filter { seen.insert($0.file).inserted }
        var edits: [ClaudeEdit] = []
        for transcript in transcripts {
            let session = transcript.file.deletingPathExtension().lastPathComponent
            let own = read(transcript.file, session: session)
            edits += own.edits
            for agent in Self.subagents(of: transcript.file, since: since) {
                edits += read(agent, session: session, title: own.title).edits
            }
        }
        return edits
    }

    /// A session's subagents: <session>/subagents/agent-*.jsonl.
    private static func subagents(of transcript: URL, since: Date) -> [URL] {
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-")
                && ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= since
        }
    }

    private func read(_ file: URL, session: String, title: String? = nil) -> (edits: [ClaudeEdit], title: String?) {
        var state = progress[file] ?? Progress(parser: .init(session: session))
        if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < state.offset { state = Progress(parser: .init(session: session)) }  // rewritten: start over
            if size > state.offset {
                try? handle.seek(toOffset: state.offset)
                var carry = Data()
                while true {
                    // In its own pool: readData's buffer is autoreleased, and without
                    // one every chunk of the file stayed until the whole read ended
                    // (+161 MB for a 160 MB transcript).
                    let chunk = autoreleasepool { handle.readData(ofLength: Self.chunkSize) }
                    if chunk.isEmpty { break }
                    var data = carry
                    data.append(chunk)
                    // Only whole lines: the last one may still be being written.
                    guard let lastNewline = data.lastIndex(of: 0x0A) else {
                        carry = data
                        continue
                    }
                    let complete = data[data.startIndex...lastNewline]
                    Self.consume(complete, into: &state.parser)
                    state.offset += UInt64(complete.count)
                    carry = Data(data[data.index(after: lastNewline)...])
                }
            }
        }
        progress[file] = state
        return (state.parser.result(title: title), state.parser.title)
    }

    private static func consume(_ data: Data, into parser: inout ClaudeEdits.Parser) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count {
                let rest = base + start
                let length = memchr(rest, 0x0A, raw.count - start).map { UnsafeRawPointer($0) - rest } ?? (raw.count - start)
                if length > 0 { parser.consume(UnsafeRawBufferPointer(start: rest, count: length)) }
                start += length + 1
            }
        }
    }
}
